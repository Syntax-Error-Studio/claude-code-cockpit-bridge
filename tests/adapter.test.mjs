import assert from "node:assert/strict";
import http from "node:http";
import test from "node:test";
import { createAdapterServer } from "../src/adapter.mjs";

const aliases = {
  "cockpit-gpt55-xhigh": { model: "gpt-5.5", effort: "xhigh" },
  "cockpit-gpt54-high": { model: "gpt-5.4", effort: "high" },
};

async function listen(server) {
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  return server.address().port;
}

async function close(server) {
  if (!server.listening) return;
  await new Promise((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
}

async function withServers(upstreamHandler, run, overrides = {}) {
  const upstream = http.createServer(upstreamHandler);
  const upstreamPort = await listen(upstream);
  const adapter = createAdapterServer({
    adapter: {
      listenHost: "127.0.0.1",
      listenPort: 7551,
      upstreamHost: "127.0.0.1",
      upstreamPort,
      maxBodyBytes: overrides.maxBodyBytes ?? 1024 * 1024,
      upstreamTimeoutMs: 5000,
    },
    models: { aliases },
  }, { logger: { log() {}, error() {} } });
  const adapterPort = await listen(adapter);
  try {
    await run({ adapterPort, upstreamPort });
  } finally {
    await close(adapter);
    await close(upstream);
  }
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

test("health endpoint reports adapter state", async () => {
  await withServers((req, res) => res.end("unused"), async ({ adapterPort }) => {
    const response = await fetch(`http://127.0.0.1:${adapterPort}/healthz`);
    assert.equal(response.status, 200);
    const value = await response.json();
    assert.equal(value.ok, true);
    assert.equal(value.aliases, 2);
  });
});

test("messages request rewrites model and injects adaptive effort", async () => {
  let received;
  await withServers(async (req, res) => {
    received = JSON.parse(await readBody(req));
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true }));
  }, async ({ adapterPort }) => {
    const response = await fetch(`http://127.0.0.1:${adapterPort}/v1/messages?beta=true`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-api-key": "test-key" },
      body: JSON.stringify({
        model: "cockpit-gpt55-xhigh",
        max_tokens: 8,
        thinking: { type: "enabled", budget_tokens: 2048 },
        output_config: { custom: true },
        messages: [{ role: "user", content: "hello" }],
      }),
    });
    assert.equal(response.status, 200);
  });
  assert.equal(received.model, "gpt-5.5");
  assert.deepEqual(received.thinking, { type: "adaptive" });
  assert.deepEqual(received.output_config, { custom: true, effort: "xhigh" });
});

test("count_tokens rewrites only the model", async () => {
  let received;
  await withServers(async (req, res) => {
    received = JSON.parse(await readBody(req));
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ input_tokens: 3 }));
  }, async ({ adapterPort }) => {
    const response = await fetch(`http://127.0.0.1:${adapterPort}/v1/messages/count_tokens`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ model: "cockpit-gpt54-high", messages: [] }),
    });
    assert.equal(response.status, 200);
  });
  assert.equal(received.model, "gpt-5.4");
  assert.equal(received.thinking, undefined);
  assert.equal(received.output_config, undefined);
});

test("unknown models pass through unchanged", async () => {
  let received;
  await withServers(async (req, res) => {
    received = JSON.parse(await readBody(req));
    res.writeHead(200, { "content-type": "application/json" });
    res.end("{}");
  }, async ({ adapterPort }) => {
    await fetch(`http://127.0.0.1:${adapterPort}/v1/messages`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ model: "custom-model", messages: [] }),
    });
  });
  assert.equal(received.model, "custom-model");
});

test("query strings and SSE events are passed through", async () => {
  let upstreamUrl;
  await withServers((req, res) => {
    upstreamUrl = req.url;
    res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
    res.write('event: message_start\n');
    res.write('data: {"type":"message_start"}\n\n');
    res.end('event: message_stop\ndata: {"type":"message_stop"}\n\n');
  }, async ({ adapterPort }) => {
    const response = await fetch(`http://127.0.0.1:${adapterPort}/v1/messages?beta=true`, {
      method: "POST",
      headers: { "content-type": "application/json", accept: "text/event-stream" },
      body: JSON.stringify({ model: "cockpit-gpt55-xhigh", stream: true, messages: [] }),
    });
    assert.equal(response.status, 200);
    assert.match(response.headers.get("content-type"), /text\/event-stream/);
    const text = await response.text();
    assert.match(text, /event: message_start/);
    assert.match(text, /event: message_stop/);
  });
  assert.equal(upstreamUrl, "/v1/messages?beta=true");
});

test("invalid JSON returns 400 without reaching upstream", async () => {
  let calls = 0;
  await withServers((req, res) => {
    calls += 1;
    res.end();
  }, async ({ adapterPort }) => {
    const response = await fetch(`http://127.0.0.1:${adapterPort}/v1/messages`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{bad",
    });
    assert.equal(response.status, 400);
    const value = await response.json();
    assert.equal(value.error, "Invalid JSON request");
  });
  assert.equal(calls, 0);
});

test("oversized request returns 413", async () => {
  await withServers((req, res) => res.end(), async ({ adapterPort }) => {
    const response = await fetch(`http://127.0.0.1:${adapterPort}/v1/messages`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ model: "cockpit-gpt55-xhigh", value: "x".repeat(200) }),
    });
    assert.equal(response.status, 413);
  }, { maxBodyBytes: 64 });
});

test("unavailable upstream returns a structured 502", async () => {
  const adapter = createAdapterServer({
    adapter: {
      listenHost: "127.0.0.1",
      listenPort: 7551,
      upstreamHost: "127.0.0.1",
      upstreamPort: 1,
      upstreamTimeoutMs: 1000,
    },
    models: { aliases },
  }, { logger: { log() {}, error() {} } });
  const adapterPort = await listen(adapter);
  try {
    const response = await fetch(`http://127.0.0.1:${adapterPort}/v1/messages`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ model: "cockpit-gpt55-xhigh", messages: [] }),
    });
    assert.equal(response.status, 502);
    const value = await response.json();
    assert.equal(value.error.code, "cockpit_upstream_unavailable");
  } finally {
    await close(adapter);
  }
});
