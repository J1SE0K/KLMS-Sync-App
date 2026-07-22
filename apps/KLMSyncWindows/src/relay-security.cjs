const net = require("node:net");

function normalizeEndpoint(endpoint) {
  const value = String(endpoint || "").trim();
  if (value === "/healthz") {
    return value;
  }
  if (!value.startsWith("/v1/")) {
    throw new Error("허용되지 않은 서버 경로입니다.");
  }
  const parsed = new URL(value, "https://relay.invalid");
  if (!parsed.pathname.startsWith("/v1/")) {
    throw new Error("허용되지 않은 서버 경로입니다.");
  }
  return `${parsed.pathname}${parsed.search}`;
}

function normalizeRelayURL(value) {
  const trimmed = String(value || "").trim().replace(/\/+$/, "");
  if (!trimmed) {
    throw new Error("서버 URL을 입력해야 합니다.");
  }
  if (/[\u0000-\u001f\u007f]/.test(trimmed)) {
    throw new Error("서버 URL에 제어 문자를 넣을 수 없습니다.");
  }
  const url = new URL(trimmed);
  validateRelayURL(url);
  return url.toString().replace(/\/+$/, "");
}

function validateRelayURL(value) {
  if (!(value instanceof URL) && /[\u0000-\u001f\u007f]/.test(String(value || ""))) {
    throw new Error("서버 URL에 제어 문자를 넣을 수 없습니다.");
  }
  const url = value instanceof URL ? value : new URL(value);
  if (url.username || url.password || url.search || url.hash) {
    throw new Error("서버 URL에는 로그인 정보, 쿼리, 프래그먼트를 넣을 수 없습니다.");
  }
  if (url.protocol === "http:" && isLoopbackHost(url.hostname)) {
    return;
  }
  if (url.protocol !== "https:") {
    throw new Error("HTTP는 이 PC의 localhost, 127.0.0.1, ::1에만 허용됩니다. 다른 서버는 HTTPS를 사용해 주세요.");
  }
}

function normalizeRelayDownloadURL(value, relayURL, requestID) {
  const text = String(value || "").trim();
  if (!text || /[\u0000-\u001f\u007f]/.test(text)) {
    throw new Error("열 수 없는 파일 주소입니다.");
  }
  const id = String(requestID || "").trim().toLowerCase();
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id)) {
    throw new Error("파일 요청 식별자가 올바르지 않습니다.");
  }
  const base = new URL(normalizeRelayURL(relayURL));
  const url = new URL(text);
  const basePath = base.pathname.replace(/\/+$/, "");
  const expectedPath = `${basePath}/v1/file-access/${id}/download`;
  if (url.username || url.password || url.search || url.hash
      || url.protocol !== base.protocol
      || normalizedHostname(url.hostname) !== normalizedHostname(base.hostname)
      || effectivePort(url) !== effectivePort(base)
      || url.pathname.toLowerCase() !== expectedPath.toLowerCase()) {
    throw new Error("파일 주소가 현재 릴레이의 허용된 다운로드 경로와 다릅니다.");
  }
  return url.toString();
}

function validateDownloadCapability(value) {
  const capability = String(value || "").trim();
  if (!/^(?:[A-Za-z0-9_-]{32}|[0-9a-fA-F]{64})$/.test(capability)) {
    throw new Error("파일 다운로드 권한이 올바르지 않습니다.");
  }
  return capability;
}

function effectivePort(url) {
  if (url.port) return url.port;
  return url.protocol === "https:" ? "443" : url.protocol === "http:" ? "80" : "";
}

function isLoopbackHost(hostname) {
  const host = normalizedHostname(hostname);
  return host === "localhost" || host === "127.0.0.1" || host === "::1";
}

function isPrivateHost(hostname) {
  const host = normalizedHostname(hostname);
  if (host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local")) {
    return true;
  }
  if (net.isIPv4(host)) {
    const octets = host.split(".").map(Number);
    return octets[0] === 0
      || octets[0] === 10
      || octets[0] === 127
      || (octets[0] === 169 && octets[1] === 254)
      || (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31)
      || (octets[0] === 192 && octets[1] === 168)
      || (octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127);
  }
  if (net.isIPv6(host)) {
    return host === "::" || host === "::1" || /^f[cd]/.test(host) || /^fe[89ab]/.test(host);
  }
  return false;
}

function normalizedHostname(hostname) {
  return String(hostname || "").toLowerCase().replace(/^\[|\]$/g, "").replace(/\.$/, "");
}

function configWithoutLegacyPlaintextToken(config) {
  const sanitized = config && typeof config === "object" ? { ...config } : {};
  const hasLegacyPlaintext = typeof sanitized.token === "string"
    && sanitized.token.length > 0
    && sanitized.tokenEncrypted !== true;
  if (hasLegacyPlaintext) {
    delete sanitized.token;
    delete sanitized.tokenEncrypted;
  }
  return { config: sanitized, changed: hasLegacyPlaintext };
}

module.exports = {
  configWithoutLegacyPlaintextToken,
  isLoopbackHost,
  isPrivateHost,
  normalizeEndpoint,
  normalizeRelayDownloadURL,
  normalizeRelayURL,
  validateDownloadCapability,
  validateRelayURL
};
