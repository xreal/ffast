#!/usr/bin/env bash
set -euo pipefail

REPO="${FFAST_REPO:-xreal/ffast}"
INSTALL_DIR="${FFAST_DIR:-$HOME/.local/bin}"
SERVER_NAME="ffast"

R='\033[0;31m' G='\033[0;32m' Y='\033[0;33m' C='\033[0;36m' D='\033[0;90m' W='\033[1;37m' N='\033[0m'

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf "${R}error:${N} missing required command: %s\n" "$1" >&2
    exit 1
  fi
}

detect_platform() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os" in
    Darwin) os="darwin" ;;
    Linux) os="linux" ;;
    *)
      printf "${R}error:${N} unsupported OS: %s\n" "$os" >&2
      exit 1
      ;;
  esac

  case "$arch" in
    arm64|aarch64) arch="arm64" ;;
    x86_64|amd64) arch="x86_64" ;;
    *)
      printf "${R}error:${N} unsupported architecture: %s\n" "$arch" >&2
      exit 1
      ;;
  esac

  printf "%s-%s" "$os" "$arch"
}

checksum_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
    return
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
    return
  fi
  printf "${R}error:${N} neither shasum nor sha256sum found\n" >&2
  exit 1
}

latest_version() {
  curl -fsSL -A "ffast-installer" "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep -oE '"tag_name"\s*:\s*"[^"]+"' \
    | head -n1 \
    | cut -d'"' -f4
}

register_claude() {
  local ffast_bin="$1"
  local config="$HOME/.claude.json"
  if ! command -v python3 >/dev/null 2>&1; then
    printf "  ${D}claude: skip (python3 missing)${N}\n"
    return
  fi
  python3 - "$config" "$ffast_bin" <<'PYEOF'
import json, sys
path, binary = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}
servers = data.setdefault("mcpServers", {})
servers["ffast"] = {"command": binary, "args": ["mcp"]}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
  printf "  ${G}✓${N} claude code  ${D}→ %s${N}\n" "$config"
}

register_codex() {
  local ffast_bin="$1"
  local config_dir="$HOME/.codex"
  local config="$config_dir/config.toml"
  mkdir -p "$config_dir"

  if [ -f "$config" ] && grep -q '\[mcp_servers\.ffast\]' "$config" 2>/dev/null; then
    printf "  ${G}✓${N} codex        ${D}→ %s (already registered)${N}\n" "$config"
    return
  fi

  {
    [ -f "$config" ] && [ -s "$config" ] && echo ""
    echo "[mcp_servers.ffast]"
    echo "command = \"$ffast_bin\""
    echo 'args = ["mcp"]'
    echo 'startup_timeout_sec = 30'
  } >> "$config"

  printf "  ${G}✓${N} codex        ${D}→ %s${N}\n" "$config"
}

register_gemini() {
  local ffast_bin="$1"
  local config_dir="$HOME/.gemini"
  local config="$config_dir/settings.json"
  if [ ! -d "$config_dir" ]; then
    printf "  ${D}gemini cli: skip (no ~/.gemini)${N}\n"
    return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    printf "  ${D}gemini cli: skip (python3 missing)${N}\n"
    return
  fi
  python3 - "$config" "$ffast_bin" <<'PYEOF'
import json, sys
path, binary = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}
servers = data.setdefault("mcpServers", {})
servers["ffast"] = {"command": binary, "args": ["mcp"]}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
  printf "  ${G}✓${N} gemini cli   ${D}→ %s${N}\n" "$config"
}

register_cursor() {
  local ffast_bin="$1"
  local config_dir="$HOME/.cursor"
  local config="$config_dir/mcp.json"
  if [ ! -d "$config_dir" ]; then
    printf "  ${D}cursor: skip (no ~/.cursor)${N}\n"
    return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    printf "  ${D}cursor: skip (python3 missing)${N}\n"
    return
  fi
  python3 - "$config" "$ffast_bin" <<'PYEOF'
import json, sys
path, binary = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}
servers = data.setdefault("mcpServers", {})
servers["ffast"] = {"command": binary, "args": ["mcp"]}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
  printf "  ${G}✓${N} cursor       ${D}→ %s${N}\n" "$config"
}

register_opencode() {
  local ffast_bin="$1"
  local config_dir="$HOME/.config/opencode"
  local config="$config_dir/opencode.json"

  if [ ! -d "$config_dir" ]; then
    printf "  ${D}opencode: skip (no ~/.config/opencode)${N}\n"
    return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    printf "  ${D}opencode: skip (python3 missing)${N}\n"
    return
  fi

  if python3 - "$config" "$ffast_bin" <<'PYEOF'
import json, os, sys

path, binary = sys.argv[1], sys.argv[2]

if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError:
        print("opencode: invalid JSON; refusing to overwrite", file=sys.stderr)
        sys.exit(1)
else:
    data = {"$schema": "https://opencode.ai/config.json", "mcp": {}}

if not isinstance(data, dict):
    print("opencode: root must be JSON object; refusing to overwrite", file=sys.stderr)
    sys.exit(1)

if "$schema" not in data:
    data["$schema"] = "https://opencode.ai/config.json"

mcp = data.get("mcp")
if mcp is None:
    mcp = {}
    data["mcp"] = mcp
elif not isinstance(mcp, dict):
    print("opencode: existing 'mcp' is not an object; refusing to overwrite", file=sys.stderr)
    sys.exit(1)

mcp["ffast"] = {
    "type": "local",
    "command": [binary, "mcp"],
    "enabled": True,
}

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
  then
    printf "  ${G}✓${N} opencode     ${D}→ %s${N}\n" "$config"
  else
    printf "  ${Y}~${N} opencode     ${D}→ skipped (preserved existing config)${N}\n"
  fi
}

main() {
  need_cmd curl
  local platform version release_path tmp binary_name checksum_name
  platform="$(detect_platform)"
  binary_name="ffast-${platform}"
  checksum_name="checksums.txt"

  version="${FFAST_VERSION:-}"
  if [ -z "$version" ]; then
    version="$(latest_version)"
  fi
  if [ -z "$version" ]; then
    printf "${R}error:${N} could not resolve latest release version\n" >&2
    exit 1
  fi

  if [ "$version" = "latest" ]; then
    release_path="latest/download"
  else
    release_path="download/${version}"
  fi

  tmp="$(mktemp -d)"
  trap '[ -n "${tmp:-}" ] && rm -rf "$tmp"' EXIT

  printf "\n${W}ffast installer${N}\n\n"
  printf "  ${D}repo${N}      %s\n" "$REPO"
  printf "  ${D}version${N}   %s\n" "$version"
  printf "  ${D}platform${N}  %s\n" "$platform"

  local binary_url checksum_url
  binary_url="https://github.com/${REPO}/releases/${release_path}/${binary_name}"
  checksum_url="https://github.com/${REPO}/releases/${release_path}/${checksum_name}"

  printf "  ${D}download${N}  %s\n" "$binary_name"
  curl -fsSL -A "ffast-installer" "$binary_url" -o "$tmp/$binary_name"
  curl -fsSL -A "ffast-installer" "$checksum_url" -o "$tmp/$checksum_name"

  local expected actual
  expected="$(grep "  $binary_name$" "$tmp/$checksum_name" | awk '{print $1}')"
  if [ -z "$expected" ]; then
    printf "${R}error:${N} checksum entry not found for %s\n" "$binary_name" >&2
    exit 1
  fi

  actual="$(checksum_file "$tmp/$binary_name")"
  if [ "$actual" != "$expected" ]; then
    printf "${R}error:${N} checksum mismatch for %s\n" "$binary_name" >&2
    printf "  expected: %s\n" "$expected" >&2
    printf "  actual:   %s\n" "$actual" >&2
    exit 1
  fi

  mkdir -p "$INSTALL_DIR"
  local dest="$INSTALL_DIR/$SERVER_NAME"
  mv "$tmp/$binary_name" "$dest"
  chmod +x "$dest"

  printf "\n  ${G}installed${N} %s\n" "$dest"
  printf "\n${W}registering MCP integrations${N}\n\n"
  register_claude "$dest"
  register_codex "$dest"
  register_gemini "$dest"
  register_cursor "$dest"
  register_opencode "$dest"

  case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *)
      printf "\n${Y}add this to your shell profile:${N}\n"
      printf "  ${C}export PATH=\"%s:\$PATH\"${N}\n" "$INSTALL_DIR"
      ;;
  esac

  printf "\n${W}done${N} - run ${C}ffast --help${N}\n\n"
}

main "$@"
