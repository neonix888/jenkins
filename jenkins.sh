#!/usr/bin/env bash
#================================================================
# Jenkins Automation Script
# Description: Installs Docker, Terraform, and configures Jenkins
# Author: Senior DevOps Engineer (20+ years of Bash expertise)
#================================================================

set -euo pipefail
IFS=$'\n\t'

readonly PROJECT_DIR="$(pwd)"
readonly CONFIG_FILE="${PROJECT_DIR}/jenkins.config"
readonly ACTION="${1:-}"

#================================================================
# Logging Functions
#================================================================
log_info()    { echo -e "[INFO]    $*"; }
log_warn()    { echo -e "[WARN]    $*"; }
log_error()   { echo -e "[ERROR]   $*" >&2; }
log_success() { echo -e "[SUCCESS] $*"; }

#================================================================
# Configuration Validation
#================================================================
if [[ ! -f "${CONFIG_FILE}" ]]; then
  log_error "Configuration file not found: ${CONFIG_FILE}"
  exit 1
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

if [[ -z "${admin_user:-}" || -z "${admin_password:-}" ]]; then
  log_error "Missing admin_user or admin_password in config file"
  exit 1
fi

log_info "Loaded configuration: admin_user=${admin_user}"

#================================================================
# Helper Functions
#================================================================

check_command() {
  # Check if a command exists, otherwise install it (Debian/Ubuntu only)
  local cmd="$1" install_pkg="$2"
  if ! command -v "${cmd}" &>/dev/null; then
    log_info "Installing ${cmd}..."
    sudo apt-get install -y "${install_pkg}"
  fi
}

install_docker() {
  if ! command -v docker &>/dev/null; then
    log_info "Installing Docker..."
    sudo apt-get update -y
    sudo apt-get install -y docker.io
    sudo systemctl enable docker
    sudo systemctl start docker
  fi

  if ! groups "${USER}" | grep -q docker; then
    log_warn "Adding ${USER} to docker group..."
    sudo usermod -aG docker "${USER}"
    log_warn "You must log out and log back in for Docker group changes to apply."
  fi
}

install_terraform() {
  if ! command -v terraform &>/dev/null; then
    log_info "Installing Terraform..."
    check_command wget wget
    check_command unzip unzip
    local tf_version="1.9.5"
    wget -q "https://releases.hashicorp.com/terraform/${tf_version}/terraform_${tf_version}_linux_amd64.zip"
    unzip -o "terraform_${tf_version}_linux_amd64.zip"
    sudo mv terraform /usr/local/bin/
    rm "terraform_${tf_version}_linux_amd64.zip"
  fi
}

prepare_directories() {
  mkdir -p "${PROJECT_DIR}/"{jenkins_home,groovy,logs}
  sudo chown -R 1000:1000 "${PROJECT_DIR}/"{jenkins_home,groovy,logs}
}

create_groovy_script() {
  local groovy_file="${PROJECT_DIR}/groovy/basic-security.groovy"
  if [[ ! -f "${groovy_file}" ]]; then
    log_info "Creating Groovy script for admin setup..."
    cat > "${groovy_file}" <<EOT
import jenkins.model.*
import hudson.security.*
import jenkins.install.InstallState

println "--> Disabling Setup Wizard and ensuring admin user exists"

def instance = Jenkins.getInstance()
instance.setInstallState(InstallState.INITIAL_SETUP_COMPLETED)

def hudsonRealm = new HudsonPrivateSecurityRealm(false)
if (hudsonRealm.getAllUsers().find { it.id == "${admin_user}" } == null) {
    hudsonRealm.createAccount("${admin_user}", "${admin_password}")
    println "--> Created admin user: ${admin_user}"
} else {
    println "--> Admin user already exists"
}

instance.setSecurityRealm(hudsonRealm)
instance.setAuthorizationStrategy(new FullControlOnceLoggedInAuthorizationStrategy())
instance.save()
println "--> Jenkins security setup complete"
EOT
  fi
}

generate_terraform_file() {
  cat > "${PROJECT_DIR}/main.tf" <<'EOT'
terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

provider "docker" {
  host = "unix:///var/run/docker.sock"
}

resource "docker_image" "jenkins" {
  name = "jenkins/jenkins:lts"
}

resource "docker_container" "jenkins" {
  image = docker_image.jenkins.image_id
  name  = "jenkins"

  ports {
    internal = 8080
    external = 8080
  }

  ports {
    internal = 50000
    external = 50000
  }

  env = [
    "JAVA_OPTS=-Djenkins.install.runSetupWizard=false"
  ]

  volumes {
    host_path      = abspath("${path.module}/jenkins_home")
    container_path = "/var/jenkins_home"
  }

  volumes {
    host_path      = abspath("${path.module}/groovy")
    container_path = "/usr/share/jenkins/ref/init.groovy.d"
  }

  volumes {
    host_path      = abspath("${path.module}/logs")
    container_path = "/logs"
  }
}
EOT
}

remove_existing_container() {
  if docker ps -a --format '{{.Names}}' | grep -Eq "^jenkins$"; then
    log_info "Removing existing Jenkins container..."
    docker rm -f jenkins || true
  fi
}

install_plugins() {
  if [[ -z "${plugins:-}" ]]; then
    log_info "No plugins requested."
    return
  fi

  local plugin_list="${plugins//,/ }"
  log_info "Installing plugins with jenkins-plugin-cli: ${plugin_list}"

  # Sanity: container exists?
  if ! docker ps --format '{{.Names}}' | grep -qx jenkins; then
    log_error "Container 'jenkins' not found. Did Terraform start it?"
    return 1
  fi

  # Run as the jenkins user (uid:gid 1000). Ensure Java is on PATH for that user.
  docker exec -u 1000:1000 jenkins bash -lc '
    set -euo pipefail
    # Put likely Java locations on PATH for this non-login shell
    export PATH="/opt/java/openjdk/bin:/usr/local/openjdk-17/bin:$PATH"

    if ! command -v java >/dev/null 2>&1; then
      echo "[ERROR] java not found in PATH inside container." >&2
      echo "        Checked /opt/java/openjdk/bin and /usr/local/openjdk-17/bin." >&2
      exit 1
    fi

    if ! command -v jenkins-plugin-cli >/dev/null 2>&1; then
      echo "[ERROR] jenkins-plugin-cli not found in container. Are you using jenkins/jenkins:lts?" >&2
      exit 1
    fi

    mkdir -p /var/jenkins_home/plugins
    jenkins-plugin-cli --plugins '"${plugin_list}"'
  '

  log_info "Restarting Jenkins container to load plugins..."
  docker restart jenkins >/dev/null

  # Optional: wait briefly, then verify
  sleep 3
  verify_plugins
}


verify_plugins() {
  [[ -z "${plugins:-}" ]] && return

  # Get installed plugin IDs by listing *.jpi under JENKINS_HOME/plugins
  local installed
  installed="$(docker exec -u 1000:1000 jenkins bash -lc 'ls -1 /var/jenkins_home/plugins 2>/dev/null | sed -n "s/\.jpi$//p"')"

  # Normalize requested list (strip any :version suffix)
  local missing=() present=() req p
  for req in ${plugins//,/ }; do
    p="${req%%:*}"         # strip :version if provided
    if grep -qx "$p" <<<"$installed"; then
      present+=("$p")
    else
      missing+=("$p")
    fi
  done

  log_info "Plugins present:"
  for p in "${present[@]}"; do echo "  - $p"; done

  if ((${#missing[@]})); then
    log_warn "Plugins missing:"
    for p in "${missing[@]}"; do echo "  - $p"; done
    return 1
  else
    log_success "All requested plugins are installed."
  fi
}


#install_plugins() {
#  if [[ -n "${plugins:-}" ]]; then
#    log_info "Installing plugins: ${plugins}"
#    docker exec -u 0 jenkins bash -c "
#      curl -sSL http://localhost:8080/jnlpJars/jenkins-cli.jar -o /tmp/jenkins-cli.jar &&
#      java -jar /tmp/jenkins-cli.jar -s http://localhost:8080/ -auth ${admin_user}:${admin_password} install-plugin ${plugins//,/ } &&
#      java -jar /tmp/jenkins-cli.jar -s http://localhost:8080/ -auth ${admin_user}:${admin_password} safe-restart
#    "
#  fi
#}

start_jenkins() {
  log_info "Starting Jenkins setup..."
  install_docker
  install_terraform
  prepare_directories
  create_groovy_script
  generate_terraform_file
  remove_existing_container

  cd "${PROJECT_DIR}"
  terraform init
  terraform apply -auto-approve

  log_success "Jenkins running at http://localhost:8080"
  log_info "Admin credentials: ${admin_user} / ${admin_password}"

  install_plugins
  verify_plugins
}

stop_jenkins() {
  log_info "Stopping Jenkins..."
  remove_existing_container
}

restart_jenkins() {
  log_info "Restarting Jenkins..."
  stop_jenkins
  start_jenkins
}

#================================================================
# Main Execution
#================================================================
case "${ACTION}" in
  start)   start_jenkins ;;
  stop)    stop_jenkins ;;
  restart) restart_jenkins ;;
  *)
    echo "Usage: $0 {start|stop|restart}"
    exit 1
    ;;
esac

