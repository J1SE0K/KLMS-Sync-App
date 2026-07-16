import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";

const setupScriptPath = path.resolve(import.meta.dirname, "..", "setup_cloudflare_relay.sh");

test("every embedded Node setup program parses as JavaScript", () => {
  const setupScript = fs.readFileSync(setupScriptPath, "utf8");
  const programs = Array.from(
    setupScript.matchAll(/node -e '\n([\s\S]*?)\n'/g),
    (match) => match[1]
  );

  assert.equal(programs.length, 3);
  for (const [index, program] of programs.entries()) {
    const result = spawnSync(process.execPath, ["--check", "-"], {
      encoding: "utf8",
      input: program
    });
    assert.equal(result.status, 0, `embedded Node program ${index + 1}: ${result.stderr}`);
  }
});
