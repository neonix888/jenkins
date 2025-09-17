#!/usr/bin/env bash
#===============================================================================
# jenkins-plugins-cli.sh
#
# Lists Jenkins plugins as a table with:
#   Name (longName) | Version | Health | Enabled | InstalledAt
#
# Strategy:
#   - CLI list-plugins => robust list of plugin IDs + disabled/update hints
#   - REST /pluginManager/api/json?depth=1 => version, longName, enabled flags
#   - Optional filesystem probe (--plugins-dir) => InstalledAt (best-effort mtime)
#
# Health:
#   100 = enabled and no update
#    50 = enabled and update available
#     0 = disabled
#
# Requirements: bash, java, awk, curl, jq, column (optional for pretty table)
# Maintainer: Hieu Nguyen (Hugh) hugh@pobox.com
#===============================================================================

set -euo pipefail

#---------------------------- Defaults -----------------------------------------
JENKINS_URL="${JENKINS_URL:-http://localhost:8080}"
JENKINS_USER="${JENKINS_USER:-}"
JENKINS_TOKEN="${JENKINS_TOKEN:-${JENKINS_PASSWORD:-}}"

CLI_JAR="${CLI_JAR:-jenkins-cli.jar}"
CLI_CACHE_DIR="${CLI_CACHE_DIR:-.}"
USE_WEBSOCKET=0
NO_CERT_CHECK=0

FORMAT="table"          # table|csv|json
INCLUDE_HEADER=1
PLUGINS_DIR="${JENKINS_PLUGINS_DIR:-}"   # e.g. /var/lib/jenkins/plugins

#---------------------------- Help ---------------------------------------------
usage() {
  cat <<'USAGE'
Usage:
  jenkins-plugins-cli.sh [options]

Auth / URL:
  -u <url>              Jenkins base URL (default: http://localhost:8080)
  -a <user>             Username (or set JENKINS_USER)
  -t <token>            API token (or set JENKINS_TOKEN / JENKINS_PASSWORD)

CLI / TLS:
  --jar <path>          Path to jenkins-cli.jar (default: ./jenkins-cli.jar)
  --cache-dir <dir>     Where to place/download jenkins-cli.jar (default: .)
  --websocket           Use CLI WebSocket transport
  --no-cert-check       Skip TLS checks (CLI -noCertificateCheck; curl -k)

Filesystem (for InstalledAt):
  --plugins-dir <dir>   Jenkins plugins dir (to infer InstalledAt timestamps)

Output:
  --format <fmt>        table | csv | json  (default: table)
  --no-header           Omit header row in table/csv
  -h, --help            Show help

Examples:
  ./jenkins-plugins-cli.sh -u http://localhost:8080 -a admin -t TOKEN \
    --plugins-dir /var/lib/jenkins/plugins --format=table

  ./jenkins-plugins-cli.sh -u https://jenkins.local --no-cert-check --websocket \
    -a admin -t TOKEN --format=csv > plugins.csv
USAGE
}

need_bin(){ command -v "$1" >/dev/null || { echo "[ERROR] '$1' is required." >&2; exit 2; }; }

#---------------------------- CLI Jar Handling ---------------------------------
cli_target_path(){ [[ "$CLI_JAR" = */* ]] && printf "%s" "$CLI_JAR" || printf "%s/%s" "$CLI_CACHE_DIR" "$CLI_JAR"; }

download_cli_jar(){
  local jar; jar="$(cli_target_path)"
  local url="${JENKINS_URL%/}/jnlpJars/jenkins-cli.jar"
  echo "[INFO] Downloading CLI from: $url"
  mkdir -p "$(dirname "$jar")"
  local curl_opts=(-fL -sS --connect-timeout 5 --max-time 60 -o "$jar")
  ((NO_CERT_CHECK)) && curl_opts+=(-k)
  curl "${curl_opts[@]}" "$url" || { echo "[ERROR] Failed to download CLI." >&2; exit 3; }
}

ensure_cli(){ local p; p="$(cli_target_path)"; [[ -s "$p" ]] || download_cli_jar; echo "$p"; }

#---------------------------- CLI & REST Runners -------------------------------
run_cli_list_plugins() {
  # java -jar jenkins-cli.jar -s <url> [-webSocket] [-noCertificateCheck] -auth user:token list-plugins
  local jar="$1"
  local -a args=(-jar "$jar" -s "$JENKINS_URL")
  ((USE_WEBSOCKET)) && args+=(-webSocket)
  ((NO_CERT_CHECK)) && args+=(-noCertificateCheck)
  if [[ -n "$JENKINS_USER" && -n "$JENKINS_TOKEN" ]]; then
    args+=(-auth "${JENKINS_USER}:${JENKINS_TOKEN}")
  fi
  java "${args[@]}" list-plugins
}

fetch_plugins_rest_json() {
  # One-shot REST fetch for version/longName/enabled
  local url="${JENKINS_URL%/}/pluginManager/api/json?depth=1"
  local -a curl_opts=(-sS -g --connect-timeout 5 --max-time 20)
  ((NO_CERT_CHECK)) && curl_opts+=(-k)
  if [[ -n "$JENKINS_USER" && -n "$JENKINS_TOKEN" ]]; then
    curl_opts+=( -u "${JENKINS_USER}:${JENKINS_TOKEN}" )
  fi
  curl "${curl_opts[@]}" "$url"
}


#---------------------------- Cross-platform stat/date -------------------------
file_mtime_epoch(){
  local f="$1"
  [[ -e "$f" ]] || { echo ""; return; }
  if stat --version >/dev/null 2>&1; then stat -c %Y -- "$f"; else stat -f %m -- "$f"; fi
}
epoch_to_human(){
  local e="$1"; [[ -n "$e" ]] || { echo ""; return; }
  if date -d @0 >/dev/null 2>&1; then date -d "@$e" "+%Y-%m-%d %H:%M:%S %Z"; else date -r "$e" "+%Y-%m-%d %H:%M:%S %Z"; fi
}
plugin_path_candidates(){
  local name="$1"
  [[ -n "$PLUGINS_DIR" ]] || return 0
  printf "%s\n" \
    "$PLUGINS_DIR/$name.jpi" \
    "$PLUGINS_DIR/$name.hpi" \
    "$PLUGINS_DIR/$name"    # exploded dir
}
installed_at_for(){
  local name="$1" best=""
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    e="$(file_mtime_epoch "$p" || true)"
    [[ -n "$e" ]] || continue
    [[ -z "$best" || "$e" -gt "$best" ]] && best="$e"
  done < <(plugin_path_candidates "$name")
  epoch_to_human "$best"
}

#---------------------------- Parsing / Join -----------------------------------
# Parse CLI output -> ID \t hasUpdate \t enabled
cli_to_status_rows(){
  awk -v OFS="\t" '
    {
      id=$1; # plugin shortName
      enabled="true"; hasUpdate="false";
      # tokens after $2 may include "(disabled)" or "-> NEWVER"
      for (i=2; i<=NF; i++) {
        tok=$i; low=tolower(tok);
        if (low ~ /\(disabled\)/) enabled="false";
        if (tok == "->") hasUpdate="true";
      }
      print id, hasUpdate, enabled
    }
  '
}

# Build a REST map: id \t version \t longName \t enabled (API)
rest_to_map(){
  jq -r '
    .plugins[]
    | "\(.shortName)\t\(.version // "unknown")\t\(.longName // .shortName)\t\(.enabled)"
  '
}

# Join CLI status with REST metadata, compute health, and append InstalledAt
# Join CLI status with REST metadata, compute health.
# Output columns: id \t name \t version \t health \t enabled
join_and_render(){
  local cli_rows="$1" rest_map="$2"
  awk -v OFS="\t" '
    BEGIN {
      FS = OFS = "\t";
      # Load REST map (id -> version,longName,enabled)
      while ((getline line < ARGV[1]) > 0) {
        split(line, a, "\t");
        id=a[1]; ver=a[2]; lname=a[3]; en_api=a[4];
        verMap[id]=ver; nameMap[id]=lname; enApiMap[id]=en_api;
      }
      ARGV[1]=""   # consume
    }
    {
      id=$1; hasUpd=$2; en_cli=$3;

      ver  = (id in verMap ? verMap[id] : "unknown");
      name = (id in nameMap ? nameMap[id] : id);
      en   = (id in enApiMap ? enApiMap[id] : en_cli);

      health = (en ~ /true/i ? (hasUpd ~ /true/i ? 50 : 100) : 0);

      print id, name, ver, health, en
    }
  ' <(printf "%s\n" "$rest_map") <<< "$cli_rows"
}

#---------------------------- Output helpers -----------------------------------
print_table(){
  local rows="$1"
  (( INCLUDE_HEADER )) && printf "Name\tVersion\tHealth\tEnabled\tInstalledAt\n"
  if command -v column >/dev/null 2>&1; then
    printf "%s\n" "$rows" | column -t -s $'\t'
  else
    printf "%s\n" "$rows"
  fi
}
print_csv(){
  local rows="$1"
  (( INCLUDE_HEADER )) && echo "Name,Version,Health,Enabled,InstalledAt"
  printf "%s\n" "$rows" | awk -F'\t' -v OFS=',' '{
    gsub(/"/, "\"\"", $1); gsub(/"/, "\"\"", $2); gsub(/"/, "\"\"", $5);
    print "\"" $1 "\"", "\"" $2 "\"", $3, $4, "\"" $5 "\""
  }'
}
print_json(){
  local rows="$1"
  need_bin jq
  printf "%s\n" "$rows" | jq -R -s '
    split("\n")[:-1]
    | map(split("\t"))
    | map({Name: .[0], Version: .[1], Health: (.[2]|tonumber), Enabled: (.[3]|test("^(?i:true)$")), InstalledAt: .[4]})
  '
}

#---------------------------- Arg parsing --------------------------------------
if [[ $# -eq 0 ]]; then usage; exit 1; fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u) JENKINS_URL="$2"; shift 2 ;;
    -a) JENKINS_USER="$2"; shift 2 ;;
    -t) JENKINS_TOKEN="$2"; shift 2 ;;
    --jar) CLI_JAR="$2"; shift 2 ;;
    --cache-dir) CLI_CACHE_DIR="$2"; shift 2 ;;
    --websocket) USE_WEBSOCKET=1; shift ;;
    --no-cert-check) NO_CERT_CHECK=1; shift ;;
    --plugins-dir) PLUGINS_DIR="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    --no-header) INCLUDE_HEADER=0; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) echo "[ERROR] Unknown option: $1"; usage; exit 1 ;;
  esac
done

#---------------------------- Preflight ----------------------------------------
need_bin java; need_bin awk; need_bin curl; need_bin jq
if [[ -n "$JENKINS_USER" && -z "$JENKINS_TOKEN" ]]; then
  echo "[ERROR] -a provided without -t (token)."; exit 1
fi
if [[ -n "$PLUGINS_DIR" && ! -d "$PLUGINS_DIR" ]]; then
  echo "[WARN] --plugins-dir not found: $PLUGINS_DIR (InstalledAt will be blank)" >&2
fi

#---------------------------- Main ---------------------------------------------
JAR_PATH="$(ensure_cli)"
CLI_OUT="$(run_cli_list_plugins "$JAR_PATH")"

# 1) Parse CLI to status rows
CLI_ROWS="$(printf "%s\n" "$CLI_OUT" | cli_to_status_rows)"

# 2) Fetch REST metadata and map
REST_JSON="$(fetch_plugins_rest_json)"
REST_MAP="$(printf "%s\n" "$REST_JSON" | rest_to_map)"

# 3) Join and render
ROWS="$(join_and_render "$CLI_ROWS" "$REST_MAP")"

# 4) Output
case "$FORMAT" in
  table) print_table "$ROWS" ;;
  csv)   print_csv  "$ROWS" ;;
  json)  print_json "$ROWS" ;;
  *) echo "[ERROR] Unknown format: $FORMAT"; exit 9 ;;
esac
