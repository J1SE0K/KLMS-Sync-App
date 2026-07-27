import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const evidenceDirectory = path.resolve(process.argv[2] || "");
const policyPath = path.resolve(process.argv[3] || "");

if (!process.argv[2] || !process.argv[3]) {
  throw new Error("usage: verify_security_reports.mjs <evidence-directory> <policy-json>");
}

const policy = readJSON(policyPath);
const semgrep = readJSON(path.join(evidenceDirectory, "semgrep.json"));
const detectSecrets = readJSON(path.join(evidenceDirectory, "detect-secrets.json"));

verifySemgrepCompleteness(semgrep, "Semgrep");
const semgrepFindings = (semgrep.results || []).map((finding) => ({
  group: `${normalizeSemgrepRule(finding.check_id)}|${finding.path}`,
  coordinate: [
    normalizeSemgrepRule(finding.check_id),
    finding.path,
    finding.start?.line,
    finding.start?.col,
    finding.end?.line,
    finding.end?.col,
  ].join("|"),
}));
verifyAdjudicatedFindings(semgrepFindings, policy.semgrep, "Semgrep");
for (const reportName of [
  "semgrep-insecure-object-assign.json",
  "semgrep-expensive-production.json",
  "semgrep-download-jxa.json",
  "semgrep-relay-test.json",
  "semgrep-download-jxa-boundary.json",
]) {
  const supplementalSemgrep = readJSON(path.join(evidenceDirectory, reportName));
  verifySemgrepCompleteness(supplementalSemgrep, reportName);
  assertEqual((supplementalSemgrep.results || []).length, 0, `${reportName} findings`);
}

const detectSecretFindings = Object.entries(detectSecrets.results || {}).flatMap(([filename, findings]) => (
  findings.map((finding) => ({
    group: `${finding.type}|${filename}`,
    coordinate: [finding.type, filename, finding.line_number, finding.hashed_secret].join("|"),
  }))
));
verifyAdjudicatedFindings(detectSecretFindings, policy.detectSecrets, "detect-secrets");

assertEqual((readJSON(path.join(evidenceDirectory, "bandit.json")).results || []).length, 0, "Bandit findings");
assertEqual(readJSON(path.join(evidenceDirectory, "gitleaks.json")).length, 0, "Gitleaks findings");

const trivy = readJSON(path.join(evidenceDirectory, "trivy.json"));
const trivyFindings = (trivy.Results || []).reduce((count, result) => (
  count
  + (result.Vulnerabilities || []).length
  + (result.Misconfigurations || []).length
  + (result.Secrets || []).length
), 0);
assertEqual(trivyFindings, 0, "Trivy findings");

assertEqual((readJSON(path.join(evidenceDirectory, "grype.json")).matches || []).length, 0, "Grype findings");
assertEqual((readJSON(path.join(evidenceDirectory, "osv.json")).results || []).length, 0, "OSV findings");

for (const [reportName, label] of [
  ["pip-audit.json", "product pip-audit findings"],
  ["scanner-pip-audit.json", "scanner-environment pip-audit findings"],
]) {
  const pipAudit = readJSON(path.join(evidenceDirectory, reportName));
  const pipVulnerabilities = (pipAudit.dependencies || []).reduce(
    (count, dependency) => count + (dependency.vulns || []).length,
    0
  );
  assertEqual(pipVulnerabilities, 0, label);
}

for (const reportName of ["npm-audit-cloudflare.json", "npm-audit-windows.json"]) {
  const report = readJSON(path.join(evidenceDirectory, reportName));
  assertEqual(Number(report.metadata?.vulnerabilities?.total || 0), 0, `${reportName} findings`);
}

const sbom = readJSON(path.join(evidenceDirectory, "sbom.cdx.json"));
if (sbom.bomFormat !== "CycloneDX" || !Array.isArray(sbom.components) || sbom.components.length === 0) {
  throw new Error("Syft did not produce a populated CycloneDX SBOM");
}

console.log("security-report-verification ok");

function verifySemgrepCompleteness(report, label) {
  assertEqual((report.errors || []).length, 0, `${label} scan errors`);
  const fixpointTimeouts = report.time?.fixpoint_timeouts;
  if (!Array.isArray(fixpointTimeouts)) {
    throw new Error(`${label} fixpoint timeout report is missing`);
  }
  assertEqual(fixpointTimeouts.length, 0, `${label} fixpoint timeouts`);
}

function verifyAdjudicatedFindings(findings, scannerPolicy, scannerName) {
  assertEqual(findings.length, scannerPolicy.expectedFindings, `${scannerName} finding count`);
  const digest = crypto.createHash("sha256")
    .update(findings.map((finding) => finding.coordinate).sort().join("\n"))
    .digest("hex");
  assertEqual(digest, scannerPolicy.coordinatesSha256, `${scannerName} coordinate digest`);

  const actualGroups = new Map();
  for (const finding of findings) {
    actualGroups.set(finding.group, (actualGroups.get(finding.group) || 0) + 1);
  }
  const expectedGroups = new Map(scannerPolicy.adjudications.map((entry) => [
    `${entry.rule || entry.type}|${entry.path}`,
    entry.expectedCount,
  ]));
  assertEqual(actualGroups.size, expectedGroups.size, `${scannerName} adjudication group count`);
  for (const [group, expectedCount] of expectedGroups) {
    assertEqual(actualGroups.get(group) || 0, expectedCount, `${scannerName} group ${group}`);
  }
}

function normalizeSemgrepRule(checkID) {
  const value = String(checkID || "");
  for (const marker of [".javascript.", ".python.", ".bash.", ".generic.", ".dockerfile."]) {
    const index = value.indexOf(marker);
    if (index >= 0) return value.slice(index + 1);
  }
  return value;
}

function readJSON(filename) {
  return JSON.parse(fs.readFileSync(filename, "utf8"));
}

function assertEqual(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(`${label}: expected ${expected}, received ${actual}`);
  }
}
