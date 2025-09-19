#!/usr/bin/env bash
###############################################################################
# Jenkins Backup (WAR-mode, non-Docker)
#
# WHAT: Creates a versioned, integrity-checked backup bundle that can fully
#       restore Jenkins (jobs, configs, users, secrets, plugins, WAR, unit).
#
# OUTPUT: /var/backups/jenkins/jenkins-backup-YYYYmmddTHHMMSSZ.tar.gz + .sha256
#
# SAFE: Read-only against live Jenkins (optional quiesce available).
#
# USAGE (common):
#   sudo ./jenkins-backup.sh                           # auto-detect everything
#   sudo WAR_PATH=/usr/share/java/jenkins.war ./jenkins-backup.sh
#   sudo ./jenkins-backup.sh --dry-run                # show plan, no backup
#   sudo ./jenkins-backup.sh --print-config           # print resolved paths
#
# FLAGS:
#   --jenkins-home PATH   Override JENKINS_HOME
#   --war-path PATH       Override WAR path (auto-detected if omitted)
#   --backup-dir DIR      Where to write backups (default: /var/backups/jenkins)
#   --keep N              How many backups to keep (default: 7)
#   --quiesce             Temporarily quiet Jenkins via HTTP API
#                         (requires env: JENKINS_URL, JENKINS_USER, JENKINS_API_TOKEN)
#   --no-quiesce          Force skip quiesce (default behavior)
#   --dry-run             Don’t write anything; just show what would happen
#   --print-config        Print resolved config and exit
#   --preflight           Run sanity checks (space, perms, tools) then exit
#   -h|--help             This help
#
# ENV (optional overrides):
#   JENKINS_HOME, WAR_PATH, BACKUP_DIR, KEEP, JAVA_BIN, TMP_DIR
#   JENKINS_URL, JENKINS_USER, JENKINS_API_TOKEN (for --quiesce)
#
# REQUIREMENTS: bash, tar, gzip, sha256sum, curl (if --quiesce), root privileges
# Maintainer: Hieu Nguyen hugh@pobox.com
###############################################################################
set -Eeuo pipefail

#------------------------- Defaults -------------------------#
J_HOME="${JENKINS_HOME:-/var/lib/jenkins}"
WAR_PATH="${WAR_PATH:-}"        # will auto-detect below if empty
BACKUP_DIR="${BACKUP_DIR:-/var/backups/jenkins}"
KEEP="${KEEP:-7}"
TMP_DIR="${TMP_DIR:-/tmp/jenkins-backup}"
JAVA_BIN="${JAVA_BIN:-/usr/bin/java}"
DO_QUIESCE="no"
DRY_RUN="no"
PRINT_CONFIG="no"
PREFLIGHT="no"

#------------------------- Helpers --------------------------#
timestamp() { date -u +"%Y%m%dT%H%M%SZ"; }
say() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "Missing required tool: $1"; }

usage() { sed -n '1,80p' "$0" | sed '/^set -Eeuo pipefail/,$d'; }

trap 'rc=$?; [[ $rc -ne 0 ]] && echo "[ERROR] Failed (exit $rc)"; exit $rc' EXIT

#------------------------- Args -----------------------------#
while (( $# )); do
  case "$1" in
    --jenkins-home) J_HOME="$2"; shift 2;;
    --war-path) WAR_PATH="$2"; shift 2;;
    --backup-dir) BACKUP_DIR="$2"; shift 2;;
    --keep) KEEP="$2"; shift 2;;
    --quiesce) DO_QUIESCE="yes"; shift;;
    --no-quiesce) DO_QUIESCE="no"; shift;;
    --dry-run) DRY_RUN="yes"; shift;;
    --print-config) PRINT_CONFIG="yes"; shift;;
    --preflight) PREFLIGHT="yes"; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1 (use --help)";;
  esac
done

#------------------------- Root check -----------------------#
if [[ $EUID -ne 0 ]]; then
  die "Please run as root (sudo). Root is required to read secrets and preserve ownerships."
fi

#------------------------- Auto-detects ---------------------#
# JENKINS_HOME: use env -> systemd unit -> /etc/default -> common default
if [[ ! -d "$J_HOME" ]]; then
  if [[ -f /etc/systemd/system/jenkins.service || -L /etc/systemd/system/jenkins.service ]]; then
    cand=$(grep -E 'Environment=.*JENKINS_HOME=' /etc/systemd/system/jenkins.service \
           | sed -E 's/.*JENKINS_HOME=([^" ]+).*/\1/' | tail -n1 || true)
    [[ -n "${cand:-}" && -d "$cand" ]] && J_HOME="$cand"
  fi
fi
if [[ ! -d "$J_HOME" && -f /etc/default/jenkins ]]; then
  cand=$(grep -E '^JENKINS_HOME=' /etc/default/jenkins | cut -d= -f2 | tr -d '"')
  [[ -n "${cand:-}" && -d "$cand" ]] && J_HOME="$cand"
fi
[[ -d "$J_HOME" ]] || [[ -d /var/lib/jenkins ]] && J_HOME="${J_HOME:-/var/lib/jenkins}"

# WAR_PATH: use env -> common locations
if [[ -z "${WAR_PATH:-}" || ! -f "$WAR_PATH" ]]; then
  for cand in /usr/share/java/jenkins.war /opt/jenkins/jenkins.war /usr/lib/jenkins/jenkins.war; do
    [[ -f "$cand" ]] && WAR_PATH="$cand" && break
  done
fi

#------------------------- Print config ---------------------#
print_config() {
  cat <<EOF
Resolved configuration:
  JENKINS_HOME : $J_HOME
  WAR_PATH     : ${WAR_PATH:-<not found>}
  BACKUP_DIR   : $BACKUP_DIR
  KEEP         : $KEEP
  TMP_DIR      : $TMP_DIR
  JAVA_BIN     : $JAVA_BIN
  QUIESCE      : $DO_QUIESCE
EOF
  if [[ "$DO_QUIESCE" == "yes" ]]; then
cat <<EOF
  JENKINS_URL  : ${JENKINS_URL:-<unset>}
  JENKINS_USER : ${JENKINS_USER:-<unset>}
  TOKEN set?   : $( [[ -n "${JENKINS_API_TOKEN:-}" ]] && echo yes || echo no )
EOF
  fi
}
[[ "$PRINT_CONFIG" == "yes" ]] && { print_config; exit 0; }

#------------------------- Requirements ---------------------#
require tar
require gzip
require sha256sum
mkdir -p "$BACKUP_DIR" "$TMP_DIR"

# Lock to avoid concurrent runs
LOCK_FILE="${TMP_DIR}/backup.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || die "Another backup appears to be running (lock: $LOCK_FILE)."

#------------------------- Preflight ------------------------#
preflight() {
  [[ -d "$J_HOME" ]] || die "JENKINS_HOME not found: $J_HOME"
  [[ -r "$J_HOME/config.xml" ]] || warn "No config.xml readable under $J_HOME (still proceeding)"
  [[ -d "$J_HOME/secrets" ]] || warn "No secrets/ dir visible (check perms)."
  if [[ -n "${WAR_PATH:-}" ]]; then
    [[ -r "$WAR_PATH" ]] || die "WAR not readable: $WAR_PATH"
  else
    warn "WAR not found. Backup continues, but restore won’t carry WAR."
  fi

  # require free space ~1.2x $J_HOME size
  local size_bytes free_bytes need_bytes
  size_bytes=$(du -sb "$J_HOME" | awk '{print $1}')
  free_bytes=$(df -PB1 "$BACKUP_DIR" | awk 'NR==2{print $4}')
  need_bytes=$(( size_bytes + size_bytes/5 + 100*1024*1024 ))
  if (( free_bytes < need_bytes )); then
    warn "Low free space in $BACKUP_DIR (need ~$(numfmt --to=iec $need_bytes), have $(numfmt --to=iec $free_bytes))"
  fi
}
preflight
[[ "$PREFLIGHT" == "yes" ]] && { say "Preflight OK"; exit 0; }

#------------------------- Quiet Jenkins (optional) ---------#
quiet_down() {
  [[ "$DO_QUIESCE" == "yes" ]] || return 0
  require curl
  [[ -n "${JENKINS_URL:-}" && -n "${JENKINS_USER:-}" && -n "${JENKINS_API_TOKEN:-}" ]] \
    || die "--quiesce requires JENKINS_URL, JENKINS_USER, JENKINS_API_TOKEN"

  say "Requesting quietDown..."
  curl -fsS -u "${JENKINS_USER}:${JENKINS_API_TOKEN}" \
    "${JENKINS_URL%/}/quietDown" >/dev/null || warn "quietDown request failed"
}

cancel_quiet() {
  [[ "$DO_QUIESCE" == "yes" ]] || return 0
  require curl
  say "Cancelling quietDown..."
  curl -fsS -u "${JENKINS_USER}:${JENKINS_API_TOKEN}" \
    "${JENKINS_URL%/}/cancelQuietDown" >/dev/null || warn "cancelQuietDown failed"
}

#------------------------- Main backup ----------------------#
TS=$(timestamp)
WORK="${TMP_DIR}/bundle-${TS}"
BNAME="jenkins-backup-${TS}.tar.gz"
mkdir -p "$WORK"

cleanup_work() { rm -rf "$WORK"; }
trap cleanup_work EXIT

say "Backing up Jenkins..."
print_config

if [[ "$DRY_RUN" == "yes" ]]; then
  say "[DRY-RUN] Would create ${BACKUP_DIR}/${BNAME} with:"
  echo "  - METADATA (versions, paths)"
  echo "  - plugins.txt (name:version)"
  echo "  - payload/jenkins.war (if found)"
  echo "  - jenkins_home.tar (full \$JENKINS_HOME)"
  exit 0
fi

quiet_down

say "Collecting metadata..."
JVER="unknown"
if [[ -n "${WAR_PATH:-}" && -f "$WAR_PATH" ]]; then
  # Grab version string best-effort
  JVER=$("$JAVA_BIN" -jar "$WAR_PATH" --version 2>/dev/null | head -n1 || true)
fi
JAVAVER=$("$JAVA_BIN" -version 2>&1 | head -n1 || true)

PLUGIN_TXT="${WORK}/plugins.txt"
if [[ -d "${J_HOME}/plugins" ]]; then
  # Make a stable plugin:version list (best-effort if MANIFEST exists)
  find "${J_HOME}/plugins" -maxdepth 1 -type d -printf "%f\n" \
   | sort \
   | while read -r p; do
      [[ "$p" == "plugins" ]] && continue
      mf="${J_HOME}/plugins/${p}/META-INF/MANIFEST.MF"
      ver="unknown"
      [[ -f "$mf" ]] && ver=$(grep -i '^Plugin-Version:' "$mf" | awk -F': ' '{print $2}' | tr -d '\r' || true)
      echo "${p}:${ver}"
    done > "$PLUGIN_TXT"
fi

say "Staging payload..."
mkdir -p "${WORK}/payload"

# WAR (optional)
if [[ -n "${WAR_PATH:-}" && -f "$WAR_PATH" ]]; then
  install -m 0644 "$WAR_PATH" "${WORK}/payload/jenkins.war"
else
  warn "Skipping WAR copy (not found)."
fi

# Systemd unit (optional)
if [[ -f /etc/systemd/system/jenkins.service ]]; then
  install -m 0644 /etc/systemd/system/jenkins.service "${WORK}/payload/jenkins.service"
fi

# Metadata
cat > "${WORK}/METADATA" <<EOF
timestamp=${TS}
jenkins_home=${J_HOME}
jenkins_war=${WAR_PATH:-<missing>}
jenkins_version=${JVER}
java_version=${JAVAVER}
hostname=$(hostname -f 2>/dev/null || hostname)
EOF
[[ -f "$PLUGIN_TXT" ]] && echo "plugins_manifest=plugins.txt" >> "${WORK}/METADATA"

say "Archiving JENKINS_HOME (this can take a minute)..."
pushd / >/dev/null
# Preserve numeric owners/ACLs/xattrs so restore is faithful
tar --xattrs --acls --selinux --numeric-owner \
    -cpf "${WORK}/jenkins_home.tar" "${J_HOME:1}"
popd >/dev/null

say "Creating compressed bundle..."
tar -C "$WORK" -czpf "${BACKUP_DIR}/${BNAME}" METADATA payload/ jenkins_home.tar \
  $( [[ -f "$PLUGIN_TXT" ]] && echo "plugins.txt" )
( cd "$BACKUP_DIR" && sha256sum "${BNAME}" > "${BNAME}.sha256" )

say "Pruning old backups (keep ${KEEP})..."
( cd "$BACKUP_DIR" && \
    ls -1t jenkins-backup-*.tar.gz | tail -n +$((KEEP+1)) | xargs -r rm -f; \
    ls -1t jenkins-backup-*.tar.gz.sha256 | tail -n +$((KEEP+1)) | xargs -r rm -f )

cancel_quiet

# Tighten perms on backup dir the first time
chmod 700 "$BACKUP_DIR" || true

say "SUCCESS: ${BACKUP_DIR}/${BNAME}"
