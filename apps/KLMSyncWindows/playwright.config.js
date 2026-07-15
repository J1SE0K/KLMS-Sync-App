const os = require("node:os");
const path = require("node:path");
const { defineConfig } = require("@playwright/test");

module.exports = defineConfig({
  testDir: "./test/e2e",
  fullyParallel: false,
  workers: 1,
  timeout: 30_000,
  expect: {
    timeout: 5_000
  },
  forbidOnly: Boolean(process.env.CI),
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? "line" : "list",
  preserveOutput: "always",
  outputDir: path.join(
    process.env.RUNNER_TEMP || os.tmpdir(),
    `klms-windows-playwright-${process.pid}`
  ),
  use: {
    screenshot: "only-on-failure",
    trace: "retain-on-failure"
  }
});
