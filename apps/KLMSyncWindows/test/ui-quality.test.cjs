const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const appRoot = path.resolve(__dirname, "..");
const read = (relativePath) => fs.readFileSync(path.join(appRoot, relativePath), "utf8");

test("renderer uses a strict CSP, safe DOM sinks and guarded main-process navigation", () => {
  const html = read("src/index.html");
  const renderer = read("src/renderer.js");
  const main = read("src/main.cjs");

  assert.match(html, /default-src 'none'/);
  assert.match(html, /script-src 'self'/);
  assert.match(html, /require-trusted-types-for 'script'/);
  assert.doesNotMatch(renderer, /\.innerHTML\s*=|\.outerHTML\s*=|insertAdjacentHTML|document\.write/);
  assert.match(main, /setWindowOpenHandler\(\(\) => \(\{ action: "deny" \}\)\)/);
  assert.match(main, /webContents\.on\("will-navigate"/);
  assert.match(main, /normalizeExternalURL\(target\)/);
  assert.match(main, /function assertTrustedIPCEvent\(event\)/);
  assert.match(main, /event\.sender !== mainWindow\.webContents/);
  assert.match(main, /event\.senderFrame\?\.url !== APP_ENTRY_URL/);
  assert.doesNotMatch(main, /ipcMain\.handle\("/);
});

test("connection configuration is durably staged before atomic replacement", () => {
  const main = read("src/main.cjs");

  assert.match(main, /await temporaryHandle\.sync\(\)/);
  assert.match(main, /await fs\.rename\(temporaryPath, targetPath\)/);
  assert.match(main, /await fs\.rm\(temporaryPath, \{ force: true \}\)/);
  assert.doesNotMatch(main, /fs\.writeFile\(configPath\(\)/);
});

test("dynamic status, alerts, toast and text inputs have explicit accessible names", () => {
  const html = read("src/index.html");
  assert.match(html, /id="connectionState"[^>]*role="status"[^>]*aria-live="polite"/);
  assert.match(html, /id="attentionBanner"[^>]*role="alert"[^>]*aria-live="assertive"/);
  assert.match(html, /id="toast"[^>]*role="status"[^>]*aria-live="polite"/);
  assert.match(html, /id="statusMessageDisclosure"[^>]*class="status-message-disclosure hidden"/);
  assert.match(html, /id="statusFullMessage"/);
  assert.match(html, /<label[^>]*for="connectionPaste"/);
  assert.match(html, /<label[^>]*for="searchInput"/);
});

test("renderer receives only a boolean token state and clears pasted credentials after save", () => {
  const main = read("src/main.cjs");
  const renderer = read("src/renderer.js");

  assert.doesNotMatch(main, /tokenPreview/);
  assert.match(main, /hasToken:\s*token\.length > 0/);
  assert.match(renderer, /relayToken"\)\.placeholder = config\.hasToken \? "저장됨"/);
  assert.match(renderer, /connectionPaste"\)\.value = ""/);
});

test("responsive data surfaces wrap and forced-color selections use system highlight colors", () => {
  const styles = read("src/styles.css");

  assert.match(styles, /\.item-row \.title[\s\S]*word-break: keep-all/);
  assert.match(styles, /\.history-row strong,[\s\S]*word-break: keep-all/);
  assert.match(styles, /\.detail-header h2[\s\S]*overflow-wrap: anywhere/);
  assert.match(styles, /\.detail-header h2[\s\S]*-webkit-line-clamp: 5/);
  assert.match(styles, /\.detail-overflow-copy[\s\S]*max-height: min\(50vh, 420px\)/);
  assert.match(styles, /\.field-value[\s\S]*-webkit-line-clamp: 4/);
  assert.match(styles, /#syncStatusRegion,[\s\S]*max-inline-size: 100%/);
  assert.match(styles, /\.status-message-disclosure[\s\S]*max-inline-size: 100%/);
  assert.match(styles, /button:not\(\.sidebar-backdrop\)[\s\S]*border: 1px solid ButtonText/);
  assert.match(styles, /button \.icon[\s\S]*forced-color-adjust: none/);
  assert.match(styles, /\.metric-card\.active,[\s\S]*forced-color-adjust: none;[\s\S]*background: Highlight;[\s\S]*color: HighlightText;/);
});

test("copied state includes the complete rendered status message", () => {
  const renderer = read("src/renderer.js");
  assert.match(renderer, /message:\s*statusSubtitle\(\)/);
});

test("visible action icons are vendored Lucide assets rather than text symbols", () => {
  const html = read("src/index.html");
  const renderer = read("src/renderer.js");
  const styles = read("src/styles.css");
  const iconNames = [
    "plug",
    "refresh-cw",
    "folder-sync",
    "list-checks",
    "notebook-tabs",
    "chart-no-axes-combined",
    "stethoscope",
    "square",
    "menu"
  ];

  assert.doesNotMatch(html, /[⌁↻☰]/u);
  assert.doesNotMatch(renderer, /icon:\s*"[↻□✓⌑↺!]"/u);
  for (const name of iconNames) {
    const icon = read(`assets/icons/${name}.svg`);
    assert.match(icon, /@license lucide-static v0\.468\.0 - ISC/);
    assert.match(styles, new RegExp(`assets/icons/${name}\\.svg`));
  }
});

test("light and dark semantic status colors exceed WCAG AA normal-text contrast", () => {
  const pairs = [
    ["#075e43", "#e3f4ed"],
    ["#7a3700", "#fff0dc"],
    ["#9e252d", "#fde8e9"],
    ["#8be2bd", "#173b2f"],
    ["#ffc27c", "#4b3217"],
    ["#ffaaaa", "#4a2226"]
  ];
  for (const [foreground, background] of pairs) {
    assert.ok(contrastRatio(foreground, background) >= 4.5, `${foreground} on ${background}`);
  }
});

test("light and dark interactive boundaries exceed WCAG non-text contrast", () => {
  const styles = read("src/styles.css");
  const lightVariables = cssVariables(styles.match(/^:root\s*\{([\s\S]*?)\}/)?.[1]);
  const darkVariables = cssVariables(
    styles.match(/@media \(prefers-color-scheme: dark\)\s*\{\s*:root\s*\{([\s\S]*?)\}/)?.[1]
  );

  for (const [theme, variables] of [["light", lightVariables], ["dark", darkVariables]]) {
    const pairs = [
      ["control-border", "input-bg"],
      ["active-border", "active-bg"],
      ["status-ok-border", "status-ok-bg"],
      ["status-warn-border", "status-warn-bg"],
      ["status-fail-border", "status-fail-bg"]
    ];
    for (const [foregroundName, backgroundName] of pairs) {
      const foreground = variables.get(foregroundName);
      const background = variables.get(backgroundName);
      assert.ok(foreground, `${theme} ${foregroundName} is declared`);
      assert.ok(background, `${theme} ${backgroundName} is declared`);
      assert.ok(
        contrastRatio(foreground, background) >= 3,
        `${theme} ${foregroundName} ${foreground} on ${backgroundName} ${background}`
      );
    }
  }

  assert.match(styles, /button\.secondary\s*\{[^}]*border: 1px solid var\(--control-border\)/);
  assert.match(styles, /button\.ghost\s*\{[^}]*border: 1px solid var\(--control-border\)/);
  assert.match(styles, /input,\s*select,\s*textarea\s*\{[^}]*border: 1px solid var\(--control-border\)/);
  assert.match(styles, /\.metric-card\s*\{[^}]*border: 1px solid var\(--control-border\)/);
  assert.match(styles, /\.item-row\s*\{[^}]*border: 1px solid var\(--control-border\)/);
  assert.match(styles, /\.toggle-action\s*\{[^}]*border: 1px solid var\(--control-border\)/);
});

function cssVariables(block) {
  assert.ok(block, "CSS variable block exists");
  return new Map(
    [...block.matchAll(/--([a-z0-9-]+):\s*(#[0-9a-f]{6})\s*;/gi)]
      .map((match) => [match[1], match[2]])
  );
}

function contrastRatio(foreground, background) {
  const [lighter, darker] = [relativeLuminance(foreground), relativeLuminance(background)]
    .sort((lhs, rhs) => rhs - lhs);
  return (lighter + 0.05) / (darker + 0.05);
}

function relativeLuminance(hex) {
  const channels = hex.slice(1).match(/../g).map((value) => Number.parseInt(value, 16) / 255);
  const linear = channels.map((value) => (
    value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4
  ));
  return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}
