import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const common = fs.readFileSync(new URL("../scripts/common.ps1", import.meta.url), "utf8");
const install = fs.readFileSync(new URL("../scripts/install.ps1", import.meta.url), "utf8");
const start = fs.readFileSync(new URL("../scripts/start.ps1", import.meta.url), "utf8");

test("PowerShell scripts use the installation directory as bridge root", () => {
  assert.match(common, /return \(Split-Path -Parent \$PSScriptRoot\)/);
  assert.doesNotMatch(common, /Split-Path -Parent \(Split-Path -Parent \$PSScriptRoot\)/);
});

test("WSL launcher template preserves shell NO_PROXY expansion", () => {
  assert.match(install, /\$launcherTemplate = @'/);
  assert.match(install, /\$\{NO_PROXY:\+,\$NO_PROXY\}/);
  assert.match(install, /__PROJECT_DIR__/);
  assert.match(install, /__CLAUDE_BIN__/);
});

test("startup handles Cockpit authentication exhaustion explicitly", () => {
  assert.match(start, /auth_unavailable\|no auth available/);
  assert.match(start, /refresh or wake the API-service accounts/);
});
