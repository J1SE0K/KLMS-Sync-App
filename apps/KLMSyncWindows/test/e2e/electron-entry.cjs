const { app } = require("electron");

const userDataDirectory = String(process.env.KLMS_E2E_USER_DATA_DIR || "").trim();
if (!userDataDirectory) {
  throw new Error("KLMS_E2E_USER_DATA_DIR is required for the isolated Electron test profile");
}

app.setPath("userData", userDataDirectory);
require("../../src/main.cjs");
