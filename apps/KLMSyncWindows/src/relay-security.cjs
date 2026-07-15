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

function normalizeExternalURL(value) {
  const text = String(value || "").trim();
  if (!text || /[\u0000-\u001f\u007f]/.test(text)) {
    throw new Error("열 수 없는 외부 주소입니다.");
  }
  const url = new URL(text);
  if (url.username || url.password) {
    throw new Error("로그인 정보가 포함된 외부 주소는 열 수 없습니다.");
  }
  if (url.protocol === "http:" && isLoopbackHost(url.hostname)) {
    return url.toString();
  }
  if (url.protocol !== "https:") {
    throw new Error("외부 주소는 HTTPS여야 하며 로컬 loopback만 HTTP를 허용합니다.");
  }
  return url.toString();
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

module.exports = {
  isLoopbackHost,
  isPrivateHost,
  normalizeExternalURL,
  normalizeEndpoint,
  normalizeRelayURL,
  validateRelayURL
};
