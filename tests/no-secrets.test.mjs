import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const excluded = new Set([".git", "node_modules", "logs"]);
const excludedFiles = new Set(["tests/no-secrets.test.mjs", "scripts/check-secrets.ps1"]);
const personalMarkers = [
  ["C:", "\\Users", "\\zheng"].join(""),
  ["/home", "/zheng"].join(""),
  ["2631993609", "@proton.me"].join(""),
  ["RosendoWagenhals5823", "@hotmail.com"].join(""),
  ["agt", "_codex_"].join(""),
];
const secretPatterns = [
  /sk-[A-Za-z0-9_-]{16,}/,
  /ghp_[A-Za-z0-9]{20,}/,
  /github_pat_[A-Za-z0-9_]{20,}/,
];

function files(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    if (excluded.has(entry.name)) return [];
    const full = path.join(dir, entry.name);
    return entry.isDirectory() ? files(full) : [full];
  });
}

test("repository contains no known personal paths or obvious tokens", () => {
  const violations = [];
  for (const file of files(root)) {
    const relative = path.relative(root, file).replaceAll(path.sep, "/");
    if (excludedFiles.has(relative)) continue;
    const buffer = fs.readFileSync(file);
    if (buffer.includes(0)) continue;
    const text = buffer.toString("utf8");
    for (const marker of personalMarkers) {
      if (text.includes(marker)) violations.push(`${relative} contains a blocked personal marker`);
    }
    for (const pattern of secretPatterns) {
      if (pattern.test(text)) violations.push(`${relative} matches a token pattern`);
    }
  }
  assert.deepEqual(violations, []);
});
