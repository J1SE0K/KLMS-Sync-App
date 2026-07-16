const CREDENTIAL_MARKER = "[credential]";
const ENCODED_DATA_MARKER = "[encoded-data]";
const REDACTED_LINE_MARKER = "[redacted-log-line]";
const DEFAULT_MAXIMUM_LINES = 40;
const DEFAULT_MAXIMUM_UTF8_BYTES = 6_000;
const SENSITIVE_KEY_FRAGMENTS = [
  "authorization",
  "credential",
  "bearer",
  "token",
  "secret",
  "password",
  "passwd",
  "passphrase",
  "cookie",
  "session",
  "apikey",
  "accesskey",
  "privatekey",
  "ticket",
];
const textEncoder = new TextEncoder();

export function redactPublicLogText(
  value,
  {
    maximumLines = DEFAULT_MAXIMUM_LINES,
    maximumUTF8Bytes = DEFAULT_MAXIMUM_UTF8_BYTES,
  } = {},
) {
  let text = normalizedPublicLogText(value).trim();
  if (!text) return "";

  text = redactPEMBlocks(text);
  text = redactSensitiveJSONMembers(text);
  text = redactAuthorizationCredentials(text);
  text = redactSensitiveAssignments(text);
  text = redactURLsAndPaths(text);
  text = text
    .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, "[email]")
    .replace(/KAIST 인증 번호:\s*\d{1,3}/g, "KAIST 인증 번호: --")
    .replace(/digits=\d{1,3}/g, "digits=--");

  const boundedLineCount = Math.max(0, Math.trunc(Number(maximumLines) || 0));
  const lines = text.split("\n").map((line) => {
    const trimmed = line.trimEnd();
    if (looksLikeEncodedData(trimmed)) return ENCODED_DATA_MARKER;
    if (containsResidualPrivateMaterial(trimmed)) return REDACTED_LINE_MARKER;
    return trimmed;
  });
  const joined = lines.slice(-boundedLineCount).join("\n");
  return utf8Suffix(joined, Math.max(0, Math.trunc(Number(maximumUTF8Bytes) || 0)));
}

function normalizedPublicLogText(value) {
  const normalizedNewlines = String(value ?? "").replace(/\r\n?/g, "\n");
  const withoutANSI = normalizedNewlines
    .replace(/\u001B\[[0-?]*[ -/]*[@-~]/g, "")
    .replace(/\u001B[@-_]/g, "");
  let result = "";
  for (const character of withoutANSI) {
    const scalar = character.codePointAt(0);
    if (character === "\n") {
      result += character;
    } else if (character === "\t") {
      result += " ";
    } else if (!isForbiddenScalar(scalar)) {
      result += character;
    }
  }
  return result;
}

function isForbiddenScalar(scalar) {
  return scalar <= 0x1f
    || (scalar >= 0x7f && scalar <= 0x9f)
    || (scalar >= 0x200b && scalar <= 0x200f)
    || (scalar >= 0x202a && scalar <= 0x202e)
    || (scalar >= 0x2060 && scalar <= 0x206f)
    || scalar === 0xfeff;
}

function redactPEMBlocks(text) {
  let output = "";
  let cursor = 0;
  const lower = text.toLowerCase();
  while (cursor < text.length) {
    const begin = lower.indexOf("-----begin ", cursor);
    const end = lower.indexOf("-----end ", cursor);
    if (end >= 0 && (begin < 0 || end < begin)) {
      const endClose = lower.indexOf("-----", end + "-----end ".length);
      const tailStart = endClose < 0 ? text.length : endClose + 5;
      return CREDENTIAL_MARKER + redactPEMBlocks(text.slice(tailStart));
    }
    if (begin < 0) {
      output += text.slice(cursor);
      break;
    }
    output += text.slice(cursor, begin) + CREDENTIAL_MARKER;
    const beginClose = lower.indexOf("-----", begin + "-----begin ".length);
    if (beginClose < 0) return output;
    const label = text.slice(begin + "-----begin ".length, beginClose).trim();
    if (!label) return output;
    const matchingEnd = lower.indexOf(`-----end ${label.toLowerCase()}-----`, beginClose + 5);
    if (matchingEnd < 0) return output;
    cursor = matchingEnd + `-----end ${label}-----`.length;
  }
  return output;
}

function redactSensitiveJSONMembers(text) {
  let output = "";
  let copiedThrough = 0;
  let index = 0;
  while (index < text.length) {
    if (text[index] !== "\"") {
      index += 1;
      continue;
    }
    const keyEnd = quotedValueEnd(text, index, "\"");
    if (keyEnd <= index + 1) {
      index += 1;
      continue;
    }
    let separator = keyEnd;
    while (separator < text.length && isInlineWhitespace(text[separator])) separator += 1;
    if (text[separator] !== ":") {
      index = keyEnd;
      continue;
    }
    const decodedKey = decodedJSONString(text.slice(index, keyEnd));
    if (!isSensitiveKey(decodedKey)) {
      index = keyEnd;
      continue;
    }
    let valueStart = separator + 1;
    while (valueStart < text.length && isInlineWhitespace(text[valueStart])) valueStart += 1;
    const valueEnd = structuredValueEnd(text, valueStart);
    output += text.slice(copiedThrough, valueStart) + `"${CREDENTIAL_MARKER}"`;
    copiedThrough = valueEnd;
    index = valueEnd;
  }
  return output + text.slice(copiedThrough);
}

function decodedJSONString(value) {
  try {
    const decoded = JSON.parse(value);
    return typeof decoded === "string" ? decoded : "";
  } catch {
    return "";
  }
}

function quotedValueEnd(text, start, quote) {
  let index = start + 1;
  while (index < text.length) {
    if (text[index] === "\\") {
      index = Math.min(text.length, index + 2);
    } else if (text[index] === quote) {
      return index + 1;
    } else {
      index += 1;
    }
  }
  return text.length;
}

function structuredValueEnd(text, start) {
  if (start >= text.length) return start;
  const first = text[start];
  if (first === "\"" || first === "'") return quotedValueEnd(text, start, first);
  if (first === "{" || first === "[") {
    const stack = [first];
    let index = start + 1;
    while (index < text.length && stack.length > 0) {
      const character = text[index];
      if (character === "\"" || character === "'") {
        index = quotedValueEnd(text, index, character);
      } else {
        if (character === "{" || character === "[") stack.push(character);
        if ((character === "}" && stack.at(-1) === "{")
            || (character === "]" && stack.at(-1) === "[")) stack.pop();
        index += 1;
      }
    }
    return index;
  }
  let index = start;
  while (index < text.length && !/[\s,;&}\]"'<>]/.test(text[index])) index += 1;
  return index;
}

function redactAuthorizationCredentials(text) {
  return text
    .replace(/\bauthorization\s*:\s*[^\n]*/gi, CREDENTIAL_MARKER)
    .replace(
      /\b(?:bearer|basic|digest)\s+(?:\\?"(?:\\.|[^"\\])*\\?"|\\?'(?:\\.|[^'\\])*\\?'|[^\s,;&"'<>]+)/gi,
      CREDENTIAL_MARKER,
    );
}

function redactSensitiveAssignments(text) {
  let output = "";
  let copiedThrough = 0;
  let index = 0;
  while (index < text.length) {
    const previous = index > 0 ? text[index - 1] : "";
    if (isAssignmentKeyCharacter(previous)) {
      index += 1;
      continue;
    }
    const start = index;
    let key = "";
    let keyEnd = index;
    if (text[index] === "'") {
      keyEnd = quotedValueEnd(text, index, "'");
      if (keyEnd <= index + 1 || text[keyEnd - 1] !== "'") {
        index += 1;
        continue;
      }
      key = text.slice(index + 1, keyEnd - 1);
    } else if (isAssignmentKeyCharacter(text[index])) {
      while (keyEnd < text.length && isAssignmentKeyCharacter(text[keyEnd])) keyEnd += 1;
      key = text.slice(index, keyEnd);
    } else {
      index += 1;
      continue;
    }
    let separator = keyEnd;
    while (separator < text.length && isInlineWhitespace(text[separator])) separator += 1;
    if (!isSensitiveKey(key) || ![":", "="].includes(text[separator])) {
      index = Math.max(index + 1, keyEnd);
      continue;
    }
    let valueStart = separator + 1;
    while (valueStart < text.length && isInlineWhitespace(text[valueStart])) valueStart += 1;
    const valueEnd = assignmentValueEnd(text, valueStart);
    if (text.slice(start, valueEnd) === CREDENTIAL_MARKER) {
      index = valueEnd;
      continue;
    }
    output += text.slice(copiedThrough, start) + CREDENTIAL_MARKER;
    copiedThrough = valueEnd;
    index = Math.max(valueEnd, start + 1);
  }
  return output + text.slice(copiedThrough);
}

function assignmentValueEnd(text, start) {
  if (start >= text.length) return start;
  if (text.startsWith(CREDENTIAL_MARKER, start)) return start + CREDENTIAL_MARKER.length;
  const first = text[start];
  if (first === "\"" || first === "'") return quotedValueEnd(text, start, first);
  let index = start;
  while (index < text.length && !/[\s,;&}\]"'<>]/.test(text[index])) index += 1;
  return index;
}

function isAssignmentKeyCharacter(character) {
  return Boolean(character) && /[A-Za-z0-9_%.-]/.test(character);
}

function isInlineWhitespace(character) {
  return character === " " || character === "\t";
}

function isSensitiveKey(value) {
  let decoded = String(value || "").replace(/\+/g, " ");
  for (let pass = 0; pass < 2; pass += 1) {
    try {
      const next = decodeURIComponent(decoded);
      if (next === decoded) break;
      decoded = next;
    } catch {
      break;
    }
  }
  const normalized = decoded.normalize("NFKC").toLowerCase().replace(/[^a-z0-9]+/g, "");
  return SENSITIVE_KEY_FRAGMENTS.some((fragment) => normalized.includes(fragment));
}

function redactURLsAndPaths(text) {
  return text
    .replace(/file:\/{2,3}(?:[A-Za-z]:)?[^\s"'<>}\]]+/gi, "[local-path]")
    .replace(/https?:\/\/[^\s"'<>]+/gi, "[URL]")
    .replace(/[A-Za-z]:[\\/]+[^\r\n"'<>}\]]*/g, "[local-path]")
    .replace(/\\{2,}[^\r\n"'<>}\]]+/g, "[local-path]")
    .replace(/(^|[^A-Za-z0-9])(?:~\/|\/)[^\r\n"'<>}\]]*/gm, "$1[local-path]");
}

function looksLikeEncodedData(line) {
  const candidate = line.trim();
  return candidate.length >= 48
    && /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(candidate);
}

function containsResidualPrivateMaterial(line) {
  return /-----\s*(?:BEGIN|END)\b/i.test(line)
    || /\b(?:bearer|basic|digest)\s+/i.test(line)
    || /\bauthorization\s*:/i.test(line)
    || /(?:^|[^A-Za-z0-9])(?:~\/|\/|[A-Za-z]:[\\/]|\\{2,})/.test(line)
    || /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/.test(line)
    || /(주소|address)/i.test(line)
    || /[가-힣A-Za-z0-9_.-]+(로|길)\s*\d{1,4}(\s*-\s*\d{1,4})?/.test(line);
}

function utf8Suffix(value, maximumBytes) {
  if (maximumBytes <= 0) return "";
  if (textEncoder.encode(value).length <= maximumBytes) return value;
  const prefix = "...\n";
  const prefixBytes = textEncoder.encode(prefix).length;
  if (maximumBytes <= prefixBytes) return ".".repeat(maximumBytes);
  let suffix = "";
  let used = 0;
  for (const scalar of Array.from(value).reverse()) {
    const bytes = textEncoder.encode(scalar).length;
    if (used + bytes > maximumBytes - prefixBytes) break;
    suffix = scalar + suffix;
    used += bytes;
  }
  return prefix + suffix;
}
