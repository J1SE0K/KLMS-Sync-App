#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=security-tool-versions.env
source "$script_dir/security-tool-versions.env"

install_root="${1:-${TMPDIR:-/tmp}/klms-security-scanners}"
python_bin="${PYTHON_BIN:-python3}"
bin_dir="$install_root/bin"
venv_dir="$install_root/python"
download_dir="$install_root/downloads"

umask 077
mkdir -p "$bin_dir" "$download_dir"

if ! "$python_bin" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)'; then
  printf 'security scanners require Python 3.10 or newer; set PYTHON_BIN explicitly\n' >&2
  exit 2
fi

platform="$(uname -s)-$(uname -m)"
case "$platform" in
  Darwin-arm64)
    shellcheck_url="$SHELLCHECK_DARWIN_ARM64_URL"
    shellcheck_sha256="$SHELLCHECK_DARWIN_ARM64_SHA256"
    gitleaks_url="$GITLEAKS_DARWIN_ARM64_URL"
    gitleaks_sha256="$GITLEAKS_DARWIN_ARM64_SHA256"
    trivy_url="$TRIVY_DARWIN_ARM64_URL"
    trivy_sha256="$TRIVY_DARWIN_ARM64_SHA256"
    syft_url="$SYFT_DARWIN_ARM64_URL"
    syft_sha256="$SYFT_DARWIN_ARM64_SHA256"
    grype_url="$GRYPE_DARWIN_ARM64_URL"
    grype_sha256="$GRYPE_DARWIN_ARM64_SHA256"
    osv_scanner_url="$OSV_SCANNER_DARWIN_ARM64_URL"
    osv_scanner_sha256="$OSV_SCANNER_DARWIN_ARM64_SHA256"
    ;;
  Linux-x86_64)
    shellcheck_url="$SHELLCHECK_LINUX_X64_URL"
    shellcheck_sha256="$SHELLCHECK_LINUX_X64_SHA256"
    gitleaks_url="$GITLEAKS_LINUX_X64_URL"
    gitleaks_sha256="$GITLEAKS_LINUX_X64_SHA256"
    trivy_url="$TRIVY_LINUX_X64_URL"
    trivy_sha256="$TRIVY_LINUX_X64_SHA256"
    syft_url="$SYFT_LINUX_X64_URL"
    syft_sha256="$SYFT_LINUX_X64_SHA256"
    grype_url="$GRYPE_LINUX_X64_URL"
    grype_sha256="$GRYPE_LINUX_X64_SHA256"
    osv_scanner_url="$OSV_SCANNER_LINUX_X64_URL"
    osv_scanner_sha256="$OSV_SCANNER_LINUX_X64_SHA256"
    ;;
  *)
    printf 'unsupported security-scanner platform: %s\n' "$platform" >&2
    exit 2
    ;;
esac

download_verified() {
  local url="$1"
  local expected_sha256="$2"
  local output_path="$3"
  local actual_sha256

  curl --proto '=https' --tlsv1.2 --location --fail --silent --show-error \
    --connect-timeout 15 --max-time 180 --retry 3 --retry-delay 2 \
    --output "$output_path" "$url"
  if command -v sha256sum >/dev/null 2>&1; then
    actual_sha256="$(sha256sum "$output_path" | awk '{print $1}')"
  else
    actual_sha256="$(shasum -a 256 "$output_path" | awk '{print $1}')"
  fi
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    printf 'checksum mismatch for %s\n' "$url" >&2
    return 1
  fi
}

install_tar_binary() {
  local name="$1"
  local url="$2"
  local sha256="$3"
  local archive="$download_dir/$name.tar.gz"
  local extract_dir
  local source_path

  download_verified "$url" "$sha256" "$archive"
  extract_dir="$(mktemp -d "$install_root/$name.XXXXXX")"
  tar -xzf "$archive" -C "$extract_dir"
  source_path="$(find "$extract_dir" -type f -name "$name" -perm -u+x -print -quit)"
  if [[ -z "$source_path" ]]; then
    printf 'missing %s executable in verified archive\n' "$name" >&2
    return 1
  fi
  install -m 0755 "$source_path" "$bin_dir/$name"
}

install_tar_binary shellcheck "$shellcheck_url" "$shellcheck_sha256"
install_tar_binary gitleaks "$gitleaks_url" "$gitleaks_sha256"
install_tar_binary trivy "$trivy_url" "$trivy_sha256"
install_tar_binary syft "$syft_url" "$syft_sha256"
install_tar_binary grype "$grype_url" "$grype_sha256"

download_verified "$osv_scanner_url" "$osv_scanner_sha256" "$download_dir/osv-scanner"
install -m 0755 "$download_dir/osv-scanner" "$bin_dir/osv-scanner"

rules_archive="$download_dir/semgrep-rules.tar.gz"
rules_root="$install_root/semgrep-rules-$SEMGREP_RULES_COMMIT"
download_verified "$SEMGREP_RULES_URL" "$SEMGREP_RULES_SHA256" "$rules_archive"
if [[ ! -d "$rules_root" ]]; then
  staged_rules="$(mktemp -d "$install_root/semgrep-rules.XXXXXX")"
  tar -xzf "$rules_archive" -C "$staged_rules" --strip-components=1
  mv "$staged_rules" "$rules_root"
fi

"$python_bin" -m venv --clear "$venv_dir"
"$venv_dir/bin/python" -m pip install --disable-pip-version-check --no-input --quiet \
  --upgrade "pip==$PIP_VERSION"
"$venv_dir/bin/python" -m pip install --disable-pip-version-check --no-input --quiet \
  "semgrep==$SEMGREP_VERSION" \
  "bandit==$BANDIT_VERSION" \
  "detect-secrets==$DETECT_SECRETS_VERSION" \
  "pip-audit==$PIP_AUDIT_VERSION"

# Semgrep has not yet widened its Click constraint beyond the vulnerable 8.1.x
# line. Its scan command does not use click.edit(), and the fixed Click release
# is API-compatible with the exact non-interactive command used below. Refuse
# every dependency mismatch except this deliberate, version-locked override.
"$venv_dir/bin/python" -m pip install --disable-pip-version-check --no-input --quiet \
  --upgrade --no-deps "click==$CLICK_VERSION"

pip_check_output="$("$venv_dir/bin/python" -m pip check 2>&1 || true)"
expected_click_mismatch="semgrep $SEMGREP_VERSION has requirement click~=8.1.8, but you have click $CLICK_VERSION."
if [[ "$pip_check_output" != "$expected_click_mismatch" ]]; then
  printf 'unexpected Python scanner dependency state:\n%s\n' "$pip_check_output" >&2
  exit 1
fi

scanner_site_packages="$("$venv_dir/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
"$venv_dir/bin/pip-audit" --path "$scanner_site_packages" --format=json \
  --output "$install_root/scanner-python-audit.json" >/dev/null

smoke_dir="$(mktemp -d "$install_root/semgrep-smoke.XXXXXX")"
cleanup_smoke() {
  rm -rf -- "$smoke_dir"
}
trap cleanup_smoke EXIT
printf 'rules:\n  - id: klms-security-smoke\n    languages: [python]\n    message: smoke\n    severity: ERROR\n    pattern: eval(...)\n' > "$smoke_dir/rule.yml"
printf 'eval("1 + 1")\n' > "$smoke_dir/sample.py"
set +e
"$venv_dir/bin/semgrep" scan --metrics=off --disable-version-check --error --json \
  --config "$smoke_dir/rule.yml" "$smoke_dir/sample.py" > "$smoke_dir/result.json" 2>/dev/null
semgrep_smoke_exit=$?
set -e
if [[ "$semgrep_smoke_exit" -ne 1 ]] || ! grep -q 'klms-security-smoke' "$smoke_dir/result.json"; then
  printf 'Semgrep compatibility smoke test failed after fixed Click override\n' >&2
  exit 1
fi

printf 'security-scanners-ready root=%s rules=%s\n' "$install_root" "$rules_root"
