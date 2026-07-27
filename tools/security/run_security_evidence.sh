#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd -- "$script_dir/../.." && pwd)"
# shellcheck source=security-tool-versions.env
source "$script_dir/security-tool-versions.env"

evidence_dir="${1:-${TMPDIR:-/tmp}/klms-security-evidence}"
scanner_root="${2:-${KLMS_SECURITY_SCANNER_ROOT:-${TMPDIR:-/tmp}/klms-security-scanners}}"
rules_root="$scanner_root/semgrep-rules-$SEMGREP_RULES_COMMIT"
javascript_security_rules_root="$rules_root/javascript/lang/security"
javascript_audit_rules_root="$javascript_security_rules_root/audit"
scan_tree="$(mktemp -d "${TMPDIR:-/tmp}/klms-security-source.XXXXXX")"
policy_path="$script_dir/scanner-adjudications.json"
semgrep_rule_prefix="${rules_root#/}"
semgrep_rule_prefix="${semgrep_rule_prefix//\//.}"

umask 077
mkdir -p "$evidence_dir" "$scanner_root/cache"
chmod 700 "$evidence_dir" "$scanner_root/cache" "$scan_tree"
export PATH="$scanner_root/python/bin:$scanner_root/bin:$PATH"
export XDG_CACHE_HOME="$scanner_root/cache"
export GRYPE_DB_CACHE_DIR="$scanner_root/cache/grype/db"

cleanup() {
  chmod -R go-rwx "$evidence_dir" 2>/dev/null || true
  rm -rf -- "$scan_tree"
}
trap cleanup EXIT

fail() {
  printf 'security-evidence-summary status=fail gate=%s\n' "$1" >&2
  exit 1
}

require_version() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$actual" != *"$expected"* ]]; then
    fail "version-$name"
  fi
  printf '%s=%s\n' "$name" "$actual" >> "$evidence_dir/tool-versions.txt"
}

cd "$project_root"
if [[ "${KLMS_SECURITY_REQUIRE_CLEAN:-1}" == "1" ]]; then
  git diff --quiet || fail dirty-worktree
  git diff --cached --quiet || fail dirty-index
  [[ -z "$(git ls-files --others --exclude-standard)" ]] || fail untracked-source
fi

[[ -d "$rules_root" ]] || fail semgrep-rules
require_version semgrep "$SEMGREP_VERSION" "$(semgrep --version)"
require_version bandit "$BANDIT_VERSION" "$(bandit --version | sed -n '1p')"
require_version detect-secrets "$DETECT_SECRETS_VERSION" "$(detect-secrets --version)"
require_version pip-audit "$PIP_AUDIT_VERSION" "$(pip-audit --version)"
require_version pip "$PIP_VERSION" "$(python -m pip --version)"
require_version click "$CLICK_VERSION" "$(python -c 'import importlib.metadata; print(importlib.metadata.version("click"))')"
require_version mcp "$MCP_VERSION" "$(python -c 'import importlib.metadata; print(importlib.metadata.version("mcp"))')"
require_version shellcheck "$SHELLCHECK_VERSION" "$(shellcheck --version | awk '/^version:/ {print $2}')"
require_version gitleaks "$GITLEAKS_VERSION" "$(gitleaks version)"
require_version trivy "$TRIVY_VERSION" "$(trivy --version | sed -n '1p')"
require_version syft "$SYFT_VERSION" "$(syft version | awk '/^Version:/ {print $2}')"
require_version grype "$GRYPE_VERSION" "$(grype version | awk '/^Version:/ {print $2}')"
require_version osv-scanner "$OSV_SCANNER_VERSION" "$(osv-scanner --version | sed -n '1p')"

git archive HEAD | tar -x -C "$scan_tree"

run_clean_semgrep_report() {
  local label="$1"
  local report_name="$2"
  shift 2
  set +e
  (
    cd "$scan_tree"
    semgrep scan --metrics=off --disable-version-check --error --jobs 1 \
      --timeout 60 --timeout-threshold 0 --json "$@"
  ) > "$evidence_dir/$report_name" 2> "$evidence_dir/$report_name.stderr"
  local report_exit=$?
  set -e
  [[ "$report_exit" -eq 0 ]] || fail "$label"
}

runtime_python_expected="$(
  awk -F '==' '
    /^[[:space:]]*(#|$)/ { next }
    { name = $1; gsub(/[-.]+/, "_", name); print name "-" $2 }
  ' "$scan_tree/tools/security/python-runtime-requirements.txt" | sort
)"
runtime_python_actual="$(
  find "$scan_tree/vendor/python-packages" -mindepth 1 -maxdepth 1 \
    -type d -name '*.dist-info' -exec basename {} .dist-info \; | sort
)"
[[ "$runtime_python_actual" == "$runtime_python_expected" ]] || fail runtime-python-manifest

pip_check_output="$(python -m pip check 2>&1 | LC_ALL=C sort || true)"
expected_click_mismatch="semgrep $SEMGREP_VERSION has requirement click~=8.1.8, but you have click $CLICK_VERSION."
expected_mcp_mismatch="semgrep $SEMGREP_VERSION has requirement mcp==1.23.3, but you have mcp $MCP_VERSION."
expected_dependency_mismatches="$(printf '%s\n' "$expected_click_mismatch" "$expected_mcp_mismatch" | LC_ALL=C sort)"
[[ "$pip_check_output" == "$expected_dependency_mismatches" ]] || fail scanner-dependency-state
scanner_site_packages="$(python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
pip-audit --path "$scanner_site_packages" --format=json \
  --output="$evidence_dir/scanner-pip-audit.json" \
  > "$evidence_dir/scanner-pip-audit.stdout" 2>&1 || fail scanner-pip-audit

set +e
(
  cd "$scan_tree"
  semgrep scan --metrics=off --disable-version-check --error --jobs 1 --timeout 60 --timeout-threshold 0 --json \
    --exclude-rule "$semgrep_rule_prefix.javascript.lang.security.audit.detect-non-literal-require" \
    --exclude-rule "$semgrep_rule_prefix.javascript.lang.security.audit.detect-non-literal-fs-filename" \
    --exclude-rule "$semgrep_rule_prefix.javascript.lang.security.audit.path-traversal.path-join-resolve-traversal" \
    --exclude-rule "$semgrep_rule_prefix.javascript.lang.security.audit.unsafe-formatstring" \
    --exclude-rule "$semgrep_rule_prefix.javascript.lang.security.insecure-object-assign" \
    --config "$rules_root/python/lang/security" \
    --config "$rules_root/javascript/lang/security" \
    --config "$rules_root/bash/lang/security" \
    --config "$rules_root/generic/ci/security" \
    --config "$rules_root/dockerfile/security" \
    --exclude '**/node_modules/**' --exclude '**/.build/**' --exclude '**/dist/**' \
    src tools deploy apps
) > "$evidence_dir/semgrep.json" 2> "$evidence_dir/semgrep.stderr"
semgrep_exit=$?
set -e
[[ "$semgrep_exit" -eq 0 || "$semgrep_exit" -eq 1 ]] || fail semgrep

# Four broad taint rules hit Semgrep's internal fixpoint limit on two unusually
# large scripts. Semgrep still analyzes explicitly excluded files when directory
# targets are supplied, so enumerate the safe JavaScript targets instead. Scan
# each exceptional file with the applicable rules below. The JXA downloader
# cannot use the Node sinks those rules model; a non-taint boundary rule makes
# any future introduction fail closed.
all_javascript_semgrep_targets=()
expensive_semgrep_targets=()
while IFS= read -r -d '' filename; do
  relative_filename="${filename#"$scan_tree/"}"
  all_javascript_semgrep_targets+=("$relative_filename")
  case "$relative_filename" in
    src/js/download_klms_files.js|deploy/relay/test_relay.mjs) ;;
    *) expensive_semgrep_targets+=("$relative_filename") ;;
  esac
done < <(
  find "$scan_tree/src" "$scan_tree/tools" "$scan_tree/deploy" "$scan_tree/apps" \
    -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.cjs' -o -name '*.jsx' \) \
    -print0 | sort -z
)
[[ "${#all_javascript_semgrep_targets[@]}" -gt 0 ]] || fail semgrep-javascript-targets
[[ "${#expensive_semgrep_targets[@]}" -gt 0 ]] || fail semgrep-expensive-targets
run_clean_semgrep_report \
  semgrep-insecure-object-assign \
  semgrep-insecure-object-assign.json \
  --config "$javascript_security_rules_root/insecure-object-assign.yaml" \
  "${all_javascript_semgrep_targets[@]}"
run_clean_semgrep_report \
  semgrep-expensive-production \
  semgrep-expensive-production.json \
  --config "$javascript_audit_rules_root/detect-non-literal-require.yaml" \
  --config "$javascript_audit_rules_root/detect-non-literal-fs-filename.yaml" \
  --config "$javascript_audit_rules_root/path-traversal/path-join-resolve-traversal.yaml" \
  --config "$javascript_audit_rules_root/unsafe-formatstring.yaml" \
  "${expensive_semgrep_targets[@]}"
run_clean_semgrep_report \
  semgrep-download-jxa \
  semgrep-download-jxa.json \
  --config "$javascript_audit_rules_root/unsafe-formatstring.yaml" \
  src/js/download_klms_files.js
run_clean_semgrep_report \
  semgrep-relay-test \
  semgrep-relay-test.json \
  --config "$javascript_audit_rules_root/detect-non-literal-require.yaml" \
  --config "$javascript_audit_rules_root/detect-non-literal-fs-filename.yaml" \
  --config "$javascript_audit_rules_root/path-traversal/path-join-resolve-traversal.yaml" \
  deploy/relay/test_relay.mjs
run_clean_semgrep_report \
  semgrep-download-jxa-boundary \
  semgrep-download-jxa-boundary.json \
  --config "$scan_tree/tools/security/semgrep-jxa-node-sinks.yml" \
  src/js/download_klms_files.js

bandit -r "$scan_tree/src/python" -lll -q -f json -o "$evidence_dir/bandit.json" \
  > "$evidence_dir/bandit.stdout" 2>&1 || fail bandit

: > "$evidence_dir/gitleaks.json"
gitleaks git --redact --no-banner \
  --gitleaks-ignore-path "$project_root/.gitleaksignore" \
  --report-format json --report-path "$evidence_dir/gitleaks.json" "$project_root" \
  > "$evidence_dir/gitleaks.stdout" 2>&1 || fail gitleaks

detect_files=()
while IFS= read -r -d '' filename; do
  relative="${filename#./}"
  case "$relative" in
    tools/security/security-tool-versions.env|tools/security/scanner-adjudications.json) continue ;;
  esac
  detect_files+=("$relative")
done < <(cd "$scan_tree" && find . -type f -print0 | sort -z)
set +e
(
  cd "$scan_tree"
  detect-secrets-hook --json --no-verify "${detect_files[@]}"
) > "$evidence_dir/detect-secrets.json" 2> "$evidence_dir/detect-secrets.stderr"
detect_exit=$?
set -e
[[ "$detect_exit" -eq 0 || "$detect_exit" -eq 1 ]] || fail detect-secrets

shell_files=()
while IFS= read -r -d '' filename; do
  case "$(sed -n '1p' "$filename")" in
    *bash*|*'/sh') shell_files+=("$filename") ;;
  esac
done < <(find "$scan_tree/bin" "$scan_tree/src" "$scan_tree/tools" "$scan_tree/deploy" -type f -name '*.sh' -print0)
shellcheck -S warning "${shell_files[@]}" > "$evidence_dir/shellcheck.txt" 2>&1 || fail shellcheck

pip-audit --disable-pip --no-deps -r "$scan_tree/tools/security/python-runtime-requirements.txt" \
  --format=json --output="$evidence_dir/pip-audit.json" > "$evidence_dir/pip-audit.stdout" 2>&1 || fail pip-audit

trivy fs --cache-dir "$scanner_root/cache/trivy" --scanners vuln,misconfig,secret \
  --severity HIGH,CRITICAL --exit-code 1 --format json --output "$evidence_dir/trivy.json" "$scan_tree" \
  > "$evidence_dir/trivy.stdout" 2>&1 || fail trivy

osv-scanner scan source -r "$scan_tree" --format json --output "$evidence_dir/osv.json" \
  > "$evidence_dir/osv.stdout" 2>&1 || fail osv-scanner

syft scan "dir:$scan_tree" -o "cyclonedx-json=$evidence_dir/sbom.cdx.json" \
  > "$evidence_dir/syft.stdout" 2>&1 || fail syft
grype "sbom:$evidence_dir/sbom.cdx.json" --fail-on high --only-fixed --output json \
  --file "$evidence_dir/grype.json" > "$evidence_dir/grype.stdout" 2>&1 || fail grype

(cd "$scan_tree/deploy/cloudflare-worker" && npm audit --audit-level=high --json) \
  > "$evidence_dir/npm-audit-cloudflare.json" 2> "$evidence_dir/npm-audit-cloudflare.stderr" || fail npm-cloudflare
(cd "$scan_tree/apps/KLMSyncWindows" && npm audit --audit-level=high --json) \
  > "$evidence_dir/npm-audit-windows.json" 2> "$evidence_dir/npm-audit-windows.stderr" || fail npm-windows

node "$script_dir/verify_security_reports.mjs" "$evidence_dir" "$policy_path" \
  > "$evidence_dir/verification.txt" 2>&1 || fail adjudication

candidate="$(git rev-parse HEAD)"
printf 'security-evidence-summary status=pass candidate=%s scanners=10 reports=%s\n' \
  "$candidate" "$evidence_dir"
