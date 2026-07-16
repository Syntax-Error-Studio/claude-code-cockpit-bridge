import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseArgs } from "node:util";

const DEFAULT_MAX_BODY_BYTES = 64 * 1024 * 1024;
const DEFAULT_UPSTREAM_TIMEOUT_MS = 120_000;
const VALID_EFFORTS = new Set(["none", "minimal", "low", "medium", "high", "xhigh"]);
const HOP_BY_HOP_HEADERS = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);

export function normalizeConfig(raw) {
  const adapter = raw?.adapter ?? {};
  const aliases = raw?.models?.aliases ?? {};

  const config = {
    listenHost: stringOr(adapter.listenHost, "127.0.0.1"),
    listenPort: portOr(adapter.listenPort, 7551, "adapter.listenPort"),
    upstreamHost: stringOr(adapter.upstreamHost, "127.0.0.1"),
    upstreamPort: portOr(adapter.upstreamPort, 7550, "adapter.upstreamPort"),
    maxBodyBytes: positiveIntegerOr(
      adapter.maxBodyBytes,
      DEFAULT_MAX_BODY_BYTES,
      "adapter.maxBodyBytes",
    ),
    upstreamTimeoutMs: positiveIntegerOr(
      adapter.upstreamTimeoutMs,
      DEFAULT_UPSTREAM_TIMEOUT_MS,
      "adapter.upstreamTimeoutMs",
    ),
    modelAliases: normalizeAliases(aliases),
  };

  return config;
}

export function loadConfig(configPath) {
  const absolutePath = path.resolve(configPath);
  const raw = JSON.parse(fs.readFileSync(absolutePath, "utf8"));
  return normalizeConfig(raw);
}

export function rewriteAnthropicBody(body, pathname, modelAliases) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return { body, rewrite: null };
  }

  const originalModel = typeof body.model === "string" ? body.model : "";
  const alias = modelAliases[originalModel.toLowerCase()];
  if (!alias) return { body, rewrite: null };

  const rewritten = { ...body, model: alias.model };

  if (pathname === "/v1/messages") {
    rewritten.thinking = { type: "adaptive" };
    rewritten.output_config = {
      ...(isPlainObject(body.output_config) ? body.output_config : {}),
      effort: alias.effort,
    };
  }

  return {
    body: rewritten,
    rewrite: {
      originalModel,
      model: alias.model,
      effort: alias.effort,
    },
  };
}

export function createAdapterServer(rawConfig, options = {}) {
  const config = normalizeConfig(rawConfig);
  const logger = options.logger ?? console;

  return http.createServer((req, res) => {
    const requestUrl = new URL(req.url ?? "/", "http://localhost");
    const pathname = requestUrl.pathname;

    if ((req.method === "HEAD" || req.method === "GET") && pathname === "/") {
      res.writeHead(200, { "content-type": "text/plain", "content-length": "0" });
      res.end();
      return;
    }

    if (req.method === "GET" && pathname === "/healthz") {
      sendJson(res, 200, {
        ok: true,
        listen: `${config.listenHost}:${config.listenPort}`,
        upstream: `${config.upstreamHost}:${config.upstreamPort}`,
        aliases: Object.keys(config.modelAliases).length,
      });
      return;
    }

    const isAnthropicJsonRequest =
      req.method === "POST" &&
      (pathname === "/v1/messages" || pathname === "/v1/messages/count_tokens");

    if (isAnthropicJsonRequest) {
      proxyJson(req, res, pathname, config, logger);
    } else {
      proxyRaw(req, res, config, logger);
    }
  });
}

function proxyRaw(clientReq, clientRes, config, logger) {
  const headers = sanitizeRequestHeaders(clientReq.headers);
  const upstreamReq = createUpstreamRequest(clientReq, clientRes, headers, config, logger);
  clientReq.on("aborted", () => upstreamReq.destroy());
  clientReq.pipe(upstreamReq);
}

function proxyJson(clientReq, clientRes, pathname, config, logger) {
  const chunks = [];
  let size = 0;
  let rejected = false;

  clientReq.on("data", (chunk) => {
    if (rejected) return;
    size += chunk.length;
    if (size > config.maxBodyBytes) {
      rejected = true;
      sendJson(clientRes, 413, { error: "Request body too large" });
      return;
    }
    chunks.push(chunk);
  });

  clientReq.on("end", () => {
    if (rejected) return;

    let parsed;
    try {
      parsed = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    } catch (error) {
      sendJson(clientRes, 400, {
        error: "Invalid JSON request",
        detail: error.message,
      });
      return;
    }

    const { body, rewrite } = rewriteAnthropicBody(
      parsed,
      pathname,
      config.modelAliases,
    );

    if (rewrite) {
      logger.log(
        `[rewrite] ${rewrite.originalModel} -> ${rewrite.model}, effort=${rewrite.effort}`,
      );
    }

    const payload = Buffer.from(JSON.stringify(body));
    const headers = sanitizeRequestHeaders(clientReq.headers);
    headers["content-type"] = "application/json";
    headers["content-length"] = String(payload.length);

    const upstreamReq = createUpstreamRequest(
      clientReq,
      clientRes,
      headers,
      config,
      logger,
    );
    clientReq.on("aborted", () => upstreamReq.destroy());
    upstreamReq.end(payload);
  });
}

function createUpstreamRequest(clientReq, clientRes, headers, config, logger) {
  const upstreamReq = http.request(
    {
      host: config.upstreamHost,
      port: config.upstreamPort,
      method: clientReq.method,
      path: clientReq.url,
      headers,
    },
    (upstreamRes) => {
      clientRes.writeHead(
        upstreamRes.statusCode ?? 502,
        sanitizeResponseHeaders(upstreamRes.headers),
      );
      upstreamRes.pipe(clientRes);
    },
  );

  upstreamReq.setTimeout(config.upstreamTimeoutMs, () => {
    upstreamReq.destroy(new Error(`Upstream timeout after ${config.upstreamTimeoutMs} ms`));
  });

  upstreamReq.on("error", (error) => {
    logger.error(`[upstream error] ${error.stack ?? error.message}`);
    if (!clientRes.headersSent) {
      sendJson(clientRes, 502, {
        error: {
          code: "cockpit_upstream_unavailable",
          message: error.message,
          type: "upstream_error",
        },
      });
    } else if (!clientRes.writableEnded) {
      clientRes.end();
    }
  });

  return upstreamReq;
}

function sanitizeRequestHeaders(input) {
  const headers = {};
  for (const [name, value] of Object.entries(input)) {
    const lower = name.toLowerCase();
    if (lower === "host" || lower === "content-length" || HOP_BY_HOP_HEADERS.has(lower)) {
      continue;
    }
    if (value !== undefined) headers[lower] = value;
  }
  return headers;
}

function sanitizeResponseHeaders(input) {
  const headers = {};
  for (const [name, value] of Object.entries(input)) {
    const lower = name.toLowerCase();
    if (lower === "content-length" || HOP_BY_HOP_HEADERS.has(lower)) continue;
    if (value !== undefined) headers[lower] = value;
  }
  return headers;
}

function sendJson(res, statusCode, value) {
  if (res.writableEnded) return;
  const payload = Buffer.from(JSON.stringify(value));
  res.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "content-length": String(payload.length),
  });
  res.end(payload);
}

function normalizeAliases(input) {
  if (!isPlainObject(input)) {
    throw new TypeError("models.aliases must be an object");
  }

  const aliases = {};
  for (const [aliasName, raw] of Object.entries(input)) {
    if (!isPlainObject(raw)) {
      throw new TypeError(`models.aliases.${aliasName} must be an object`);
    }
    const model = stringOr(raw.model, "").trim();
    const effort = stringOr(raw.effort, "").trim().toLowerCase();
    if (!model) throw new TypeError(`models.aliases.${aliasName}.model is required`);
    if (!VALID_EFFORTS.has(effort)) {
      throw new TypeError(
        `models.aliases.${aliasName}.effort must be one of ${[...VALID_EFFORTS].join(", ")}`,
      );
    }
    aliases[aliasName.toLowerCase()] = { model, effort };
  }
  return aliases;
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function stringOr(value, fallback) {
  return typeof value === "string" && value.length > 0 ? value : fallback;
}

function portOr(value, fallback, name) {
  const result = value ?? fallback;
  if (!Number.isInteger(result) || result < 1 || result > 65535) {
    throw new TypeError(`${name} must be an integer between 1 and 65535`);
  }
  return result;
}

function positiveIntegerOr(value, fallback, name) {
  const result = value ?? fallback;
  if (!Number.isInteger(result) || result < 1) {
    throw new TypeError(`${name} must be a positive integer`);
  }
  return result;
}

async function main() {
  const { values } = parseArgs({
    options: {
      config: { type: "string", short: "c" },
    },
  });

  const moduleDir = path.dirname(fileURLToPath(import.meta.url));
  const defaultConfig = path.resolve(moduleDir, "../config/bridge.local.json");
  const configPath = values.config ?? process.env.COCKPIT_BRIDGE_CONFIG ?? defaultConfig;
  const config = loadConfig(configPath);
  const server = createAdapterServer(
    {
      adapter: {
        listenHost: config.listenHost,
        listenPort: config.listenPort,
        upstreamHost: config.upstreamHost,
        upstreamPort: config.upstreamPort,
        maxBodyBytes: config.maxBodyBytes,
        upstreamTimeoutMs: config.upstreamTimeoutMs,
      },
      models: { aliases: config.modelAliases },
    },
  );

  server.on("error", (error) => {
    console.error(`[server error] ${error.stack ?? error.message}`);
    process.exitCode = 1;
  });

  server.listen(config.listenPort, config.listenHost, () => {
    console.log(
      `Claude compatibility adapter ready: http://${config.listenHost}:${config.listenPort}`,
    );
    console.log(
      `Forwarding requests to: http://${config.upstreamHost}:${config.upstreamPort}`,
    );
    console.log(`Model aliases enabled: ${Object.keys(config.modelAliases).length}`);
  });
}

const entry = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : "";
if (entry === import.meta.url) {
  main().catch((error) => {
    console.error(error.stack ?? error.message);
    process.exitCode = 1;
  });
}
