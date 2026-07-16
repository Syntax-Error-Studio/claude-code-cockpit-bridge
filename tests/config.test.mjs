import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import { normalizeConfig, rewriteAnthropicBody } from "../src/adapter.mjs";

const example = JSON.parse(fs.readFileSync(new URL("../config/bridge.example.json", import.meta.url), "utf8"));

test("example configuration is valid", () => {
  const config = normalizeConfig(example);
  assert.equal(config.listenPort, 7551);
  assert.equal(config.upstreamPort, 7550);
  assert.equal(config.modelAliases["cockpit-gpt55-xhigh"].model, "gpt-5.5");
});

test("aliases are case-insensitive", () => {
  const config = normalizeConfig(example);
  const { body } = rewriteAnthropicBody(
    { model: "COCKPIT-GPT54-HIGH", messages: [] },
    "/v1/messages",
    config.modelAliases,
  );
  assert.equal(body.model, "gpt-5.4");
  assert.equal(body.output_config.effort, "high");
});

test("invalid effort is rejected", () => {
  assert.throws(
    () => normalizeConfig({ models: { aliases: { x: { model: "gpt-x", effort: "ultra" } } } }),
    /effort must be one of/,
  );
});

test("invalid ports are rejected", () => {
  assert.throws(
    () => normalizeConfig({ adapter: { listenPort: 70000 }, models: { aliases: {} } }),
    /listenPort/,
  );
});
