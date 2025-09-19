#!/usr/bin/env bash
set -Eeuo pipefail

# Usage:
#   sudo ./jenkins-restore.sh /var/backups/jenkins/jenkins-backup-YYYYmmddTHHMMSSZ.tar.gz
#
# It will:
#  - Stop Jenkins
#  - Verify checksum & contents
#  - Backup current JENKINS_HOME to /var/lib/jenkins.RECOVER-<ts>
#  - Restore from tar
#  - Ensure Java 17 installed
#  - Restore WAR + systemd unit (if present in backup)
#  - Fix perms
#  - Start + health-check
#  - Roll back if health-check fails
# Maintainer: Hieu Nguyen (hugh@pobox.com)

BACKUP_TARBALL="${1:-}"
J_HOME="${JENKINS_HOME:-/var/lib/jenkins}"
WAR_DST="${WAR_DST:-/opt/jenkins/jenkins.war}"
SERVICE_FILE="/etc/systemd/system/jenkins.service"
JAVA_BIN="${JAVA_BIN:-/usr/bin/java}"
JAVA_PKG="${JAVA_PKG:-openjdk-17-jre-headless}"
TMP_DIR="${TMP_DIR:-/tmp/jenkins-restore}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:8080/login}"
TIMEOUT="${TIMEOUT:-120}"  # seconds to wait for healthy

require() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1"; exit 1; }; }

die() { echo "ERROR: $*"; exit 1; }

timestamp() { date -u +"%Y%m%dT%H%M%SZ"; }

install_java_if_needed() {
  if ! command -v "$JAVA_BIN" >/dev/null 2>&1; then
    echo "[INFO] Installing Java 17..."
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$JAVA_PKG"
  fi
}

stop_jenkins() {
  systemctl stop jenkins || true
  # best-effort kill if a rogue process remains
  pkill -f 'jenkins.war' || true
}

start_jenkins() {
  systemctl daemon-reload || true
  systemctl start jenkins
}

wait_healthy() {
  echo "[INFO] Waiting for Jenkins to become healthy at ${HEALTH_URL} (timeout ${TIMEOUT}s)..."
  local end=$((SECONDS+TIMEOUT))
  while (( SECONDS < end )); do
    # curl quietly, follow redirects, fail on non-2xx
    if curl -fsSL --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; then
      echo "[SUCCESS] Jenkins is responding."
      return 0
    fi
    sleep 3
  done
  return 1
}

restore() {
  local tarball="$1"
  [[ -f "$tarball" ]] || die "Backup tarball not found"

  require tar
  require gzip
  require sha256sum
  mkdir -p "$TMP_DIR"

  if [[ -f "${tarball}.sha256" ]]; then
    echo "[INFO] Verifying checksum..."
    (cd "$(dirname "$tarball")" && sha256sum -c "$(basename "${tarball}.sha256")")
  else
    echo "[WARN] No .sha256 file found; skipping checksum verification."
  fi

  echo "[INFO] Stopping Jenkins..."
  stop_jenkins

  local TS; TS=$(timestamp)
  local SAFETY="${J_HOME}.RECOVER-${TS}"
  echo "[INFO] Creating safety copy: ${SAFETY}"
  rsync -aHAX --delete "$J_HOME/" "$SAFETY/" 2>/dev/null || rsync -a --delete "$J_HOME/" "$SAFETY/" || true

  echo "[INFO] Extracting bundle to temp..."
  local WORK="${TMP_DIR}/restore-${TS}"
  mkdir -p "$WORK"
  tar -C "$WORK" -xzpf "$tarball"

  [[ -f "${WORK}/jenkins_home.tar" ]] || die "Backup missing jenkins_home.tar"
  [[ -f "${WORK}/METADATA" ]] || echo "[WARN] METADATA missing (continuing)"

  # Restore systemd unit and WAR if present
  if [[ -f "${WORK}/payload/jenkins.service" ]]; then
    echo "[INFO] Restoring systemd unit..."
    install -m 0644 "${WORK}/payload/jenkins.service" "$SERVICE_FILE"
  fi
  if [[ -f "${WORK}/payload/jenkins.war" ]]; then
    echo "[INFO] Restoring WAR to ${WAR_DST}..."
    install -D -m 0644 "${WORK}/payload/jenkins.war" "$WAR_DST"
  fi

  echo "[INFO] Restoring JENKINS_HOME..."
  # Make sure the home exists and is owned by jenkins
  id jenkins >/dev/null 2>&1 || useradd -r -m -d "$J_HOME" -s /bin/bash jenkins
  mkdir -p "$J_HOME"
  chown -R jenkins:jenkins "$J_HOME"

  # Wipe current contents (keeping folder) then extract
  find "$J_HOME" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  tar -C / -xpf "${WORK}/jenkins_home.tar"

  # Fix perms
  chown -R jenkins:jenkins "$J_HOME"

  # Ensure Java present
  install_java_if_needed

  echo "[INFO] Starting Jenkins..."
  start_jenkins

  if wait_healthy; then
    echo "[SUCCESS] Restore complete."
    echo "[INFO] Leaving safety copy at ${SAFETY} (clean it later once you’re confident)."
  else
    echo "[ERROR] Jenkins did not become healthy in time. Rolling back..."
    stop_jenkins
    # restore safety copy back
    rsync -a --delete "$SAFETY/" "$J_HOME/"
    start_jenkins
    die "Rolled back to ${SAFETY}. Investigate logs in /var/log/syslog and ${J_HOME}/logs"
  fi

  rm -rf "$WORK"
}

restore "$BACKUP_TARBALL"


