#!/usr/bin/env bash

[[ $EUID -ne 0 ]] && { error "This script must be run as root"; exit 1; }

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()    { echo -e "\n${BOLD}$*${NC}"; }

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    *) error "Unsupported architecture: $(uname -m)"; exit 1 ;;
  esac
}

detect_libc() {
  case "$(ldd --version 2>&1 || true)" in
    *musl*) echo "musl" ;;
    *)      echo "gnu"  ;;
  esac
}

ID=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
VERSION_ID=$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')

if [[ "$ID" == "debian" && "${VERSION_ID%%.*}" -le 11 ]] || [[ "$ID" == "ubuntu" && "${VERSION_ID%%.*}" -le 22 ]]; then
  LIBC="musl"
else
  LIBC="$(detect_libc)"
fi

ARCH="$(detect_arch)"

RELEASES_PER_PAGE="10"

INSTALL_DIR="/usr/local/bin"

TELEMT_REPO="telemt/telemt"
TELEMT_CONF="telemt.toml"
TELEMT_CONF_DIR="/etc/telemt"

PANEL_REPO="amirotin/telemt_panel"
PANEL_CONF="config.toml"
PANEL_CONF_DIR="/etc/telemt-panel"

REQUIRED_CMDS=(curl tar gzip openssl jq)
MISSING_CMDS=()

telemt_local_version() {
    TELEMT_LOCAL_VER="$(${INSTALL_DIR}/telemt --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+.*$' | head -1 || echo "unknown")"
}

check_dependencies() {
    step "Checking dependencies"
    for cmd in "${REQUIRED_CMDS[@]}"; do
      command -v "$cmd" &>/dev/null || MISSING_CMDS+=("$cmd")
    done
    if [[ ${#MISSING_CMDS[@]} -gt 0 ]]; then
        warn "Missing packages: ${MISSING_CMDS[*]}"
        info "Installing missing packages..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y "${MISSING_CMDS[@]}"
        else
            error "Cannot detect package manager. Please install manually: ${MISSING_CMDS[*]}"
            exit 1
        fi
        success "Dependencies installed"
    else
      success "All dependencies present"
    fi
}

fetch_telemt_releases() {
    step "Fetching available releases"
    RELEASES_JSON=$(curl --connect-timeout 10 --retry 2 --retry-delay 1 -fsSL "https://api.github.com/repos/${TELEMT_REPO}/releases?per_page=${RELEASES_PER_PAGE}")
    RELEASE_LIST=$(echo "$RELEASES_JSON" | jq -r '.[] | "\(.tag_name)|\(.name)|\(.prerelease)"' | sort -V | tac)
    if [[ -z "$RELEASE_LIST" ]]; then
      error "Could not fetch releases from GitHub."
      exit 1
    fi
    LATEST_STABLE=$(echo "$RELEASE_LIST" | awk -F'|' '$3=="false"{print $1; exit}')
    echo ""
    echo -e "  ${BOLD}Available releases:${NC}"
    echo ""
    i=1
    declare -a TAG_ARRAY
    while IFS='|' read -r tag name prerelease; do
      TAG_ARRAY+=("$tag")
      if [[ "$prerelease" == "true" ]]; then
        STATUS="${YELLOW}pre-release${NC}"
      else
        STATUS="${GREEN}stable${NC}"
      fi
      printf "  ${DIM}%2d)${NC}  ${MAGENTA}${BOLD}%-12s${NC}  ${DIM}%-30s${NC}  %b\n" \
        "$i" "$tag" "$name" "$STATUS"
      (( i++ ))
    done <<< "$RELEASE_LIST"
    echo
    echo -e "  ${DIM}(Enter number, tag name, or press Enter for latest stable: ${MAGENTA}${BOLD}${LATEST_STABLE}${NC}${DIM})${NC}"
    echo
    echo -ne "${BOLD}Your choice${NC} ${YELLOW}[${LATEST_STABLE}]${NC}: "
    read -r INPUT_RELEASE
    if [[ -z "$INPUT_RELEASE" ]]; then
      RELEASE_TAG="$LATEST_STABLE"
    elif [[ "$INPUT_RELEASE" =~ ^[0-9]+$ ]]; then
      IDX=$(( INPUT_RELEASE - 1 ))
      RELEASE_TAG="${TAG_ARRAY[$IDX]:-$LATEST_STABLE}"
    else
      RELEASE_TAG="$INPUT_RELEASE"
    fi
    echo
    success "${BOLD}Selected release:${NC} ${MAGENTA}${BOLD}${RELEASE_TAG}${NC}"
    echo
    TELEMT_ASSET="telemt-${ARCH}-linux-${LIBC}.tar.gz"
    TELEMT_DL_URL="https://github.com/${TELEMT_REPO}/releases/download/${RELEASE_TAG}/${TELEMT_ASSET}"
    info "Downloading ${BOLD}${TELEMT_DL_URL}${NC}"
    if ! wget --timeout=10 -qO- "${TELEMT_DL_URL}" | tar -xz; then
        error "Download failed. URL: ${BOLD}${TELEMT_DL_URL}${NC}"
        exit 1
    fi
    if systemctl list-unit-files | grep -q telemt.service; then
        info "Stopping ${CYAN}telemt${NC} service"
        systemctl stop telemt
    fi
    info "Installing binary"
    if [[ ! -f telemt || ! -s telemt ]]; then
        error "Downloaded file 'telemt' is missing or empty (size = 0)"
    exit 1
    fi
    mv telemt ${INSTALL_DIR}/telemt
    chmod +x ${INSTALL_DIR}/telemt
}

fetch_panel_releases() {
    step "Fetching available releases"
    RELEASES_JSON=$(curl --connect-timeout 10 --retry 2 --retry-delay 1 -fsSL "https://api.github.com/repos/${PANEL_REPO}/releases?per_page=${RELEASES_PER_PAGE}")
    RELEASE_LIST=$(echo "$RELEASES_JSON" | jq -r '.[] | "\(.tag_name)|\(.name)|\(.prerelease)"' | sort -V | tac)
    if [[ -z "$RELEASE_LIST" ]]; then
      error "Could not fetch releases from GitHub."
      exit 1
    fi
    LATEST_STABLE=$(echo "$RELEASE_LIST" | awk -F'|' '$3=="false"{print $1; exit}')
    echo ""
    echo -e "  ${BOLD}Available releases:${NC}"
    echo ""
    i=1
    declare -a TAG_ARRAY
    while IFS='|' read -r tag name prerelease; do
      TAG_ARRAY+=("$tag")
      if [[ "$prerelease" == "true" ]]; then
        STATUS="${YELLOW}pre-release${NC}"
      else
        STATUS="${GREEN}stable${NC}"
      fi
      printf "  ${DIM}%2d)${NC}  ${MAGENTA}${BOLD}%-12s${NC}  ${DIM}%-30s${NC}  %b\n" \
        "$i" "$tag" "$name" "$STATUS"
      (( i++ ))
    done <<< "$RELEASE_LIST"
    echo
    echo -e "  ${DIM}(Enter number, tag name, or press Enter for latest stable: ${MAGENTA}${BOLD}${LATEST_STABLE}${NC}${DIM})${NC}"
    echo
    echo -ne "${BOLD}Your choice${NC} ${YELLOW}[${LATEST_STABLE}]${NC}: "
    read -r INPUT_RELEASE
    if [[ -z "$INPUT_RELEASE" ]]; then
      RELEASE_TAG="$LATEST_STABLE"
    elif [[ "$INPUT_RELEASE" =~ ^[0-9]+$ ]]; then
      IDX=$(( INPUT_RELEASE - 1 ))
      RELEASE_TAG="${TAG_ARRAY[$IDX]:-$LATEST_STABLE}"
    else
      RELEASE_TAG="$INPUT_RELEASE"
    fi
    echo
    success "${BOLD}Selected release:${NC} ${MAGENTA}${BOLD}${RELEASE_TAG}${NC}"
    echo
    PANEL_ASSET="telemt-panel-${ARCH}-linux-gnu.tar.gz"
    PANEL_DL_URL="https://github.com/${PANEL_REPO}/releases/download/${RELEASE_TAG}/${PANEL_ASSET}"
    info "Downloading ${BOLD}${PANEL_DL_URL}${NC}"
    if ! wget --timeout=10 -qO- "${PANEL_DL_URL}" | tar -xz; then
        error "Download failed. URL: ${BOLD}${PANEL_DL_URL}${NC}"
        exit 1
    fi
    if systemctl list-unit-files | grep -q telemt-panel.service; then
        info "Stopping ${CYAN}telemt-panel${NC} service"
        systemctl stop telemt-panel
    fi
    info "Installing binary"
    if [[ ! -f telemt-panel-${ARCH}-linux || ! -s telemt-panel-${ARCH}-linux ]]; then
        error "Downloaded file 'telemt-panel-${ARCH}-linux' is missing or empty (size = 0)"
    exit 1
    fi
    mv telemt-panel-${ARCH}-linux ${INSTALL_DIR}/telemt-panel
    chmod +x ${INSTALL_DIR}/telemt-panel
}

create_telemt_config() {
    echo
    info "Creating telemt config"
    echo
    until [[ ${PROXY_USER_NAME} =~ ^[a-zA-Z0-9]+$ && "${#PROXY_USER_NAME}" -ge 1 && ${#PROXY_USER_NAME} -lt 16 ]]; do
            read -rp "Enter proxy username: " -e -i user1 PROXY_USER_NAME
    done
    PROXY_USER_SECRET=$(openssl rand -hex 16)
    read -rp "TLS domain: " -e -i www.bing.com TLS_DOMAIN
    until [[ ${TLS_PORT} =~ ^[0-9]+$ ]] && [ "${TLS_PORT}" -ge 1 ] && [ "${TLS_PORT}" -le 65535 ]; do
        read -rp "TLS port: " -e -i 443 TLS_PORT
    done
    echo
    mkdir -p ${TELEMT_CONF_DIR}
    cat > ${TELEMT_CONF_DIR}/${TELEMT_CONF} << EOF
[general]
use_middle_proxy = false

[general.modes]
classic = false
secure = false
tls = true

[server]
port = ${TLS_PORT}
max_connections = 0

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "${TLS_DOMAIN}"

[access.users]
${PROXY_USER_NAME} = "${PROXY_USER_SECRET}"
EOF
}

create_panel_config() {
    echo
    step "Creating panel config"
    echo
    RANDOM_PANEL_PORT=$(printf "%d" $((60000 + RANDOM % 5536)))
    until [[ ${PANEL_PORT} =~ ^[0-9]+$ ]] && [ "${PANEL_PORT}" -ge 1 ] && [ "${PANEL_PORT}" -le 65535 ]; do
        read -rp "Listen port: " -e -i "${RANDOM_PANEL_PORT}" PANEL_PORT
    done
    until [[ ${PANEL_ADMIN_USER} =~ ^[a-zA-Z0-9]+$  && ${#PANEL_ADMIN_USER} -ge 1 && ${#PANEL_ADMIN_USER} -lt 16 ]]; do
        read -rp "Panel admin username: " -e -i admin PANEL_ADMIN_USER
    done
    PANEL_ADMIN_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12)
    echo "------------------------------------"
    echo -e " Panel admin password: ${YELLOW}${BOLD}${PANEL_ADMIN_PASS}${NC}"
    echo "------------------------------------"
    read -rsp "Press ENTER to use this password, or enter yours: " INPUT_PANEL_ADMIN_PASS
    echo
    if [[ -n "${INPUT_PANEL_ADMIN_PASS}" ]]; then
        PANEL_ADMIN_PASS="${INPUT_PANEL_ADMIN_PASS}"
    fi
    PANEL_PASS_HASH=$("${INSTALL_DIR}/telemt-panel" hash-password <<< "${PANEL_ADMIN_PASS}")
    JWT_SECRET=$(openssl rand -hex 32)
    mkdir -p ${PANEL_CONF_DIR}
    cat > ${PANEL_CONF_DIR}/${PANEL_CONF} << EOF
listen = "0.0.0.0:${PANEL_PORT}"

[telemt]
url = "http://127.0.0.1:9091"
auth_header = ""
binary_path = "${INSTALL_DIR}/telemt"

[auth]
username = "${PANEL_ADMIN_USER}"
password_hash = "${PANEL_PASS_HASH}"
jwt_secret = "${JWT_SECRET}"
session_ttl = "24h"
EOF
}

proxy_users_list() {
    echo
    echo -e "${BOLD}USER\tLINK${NC}"
    echo -e "${CYAN}-------------------------------------------------------------------------------------------------------------------${NC}"
    curl --max-time 3 --retry 2 --retry-delay 1 -s http://127.0.0.1:9091/v1/users | jq -r '.data[] | [.username, (.links.tls[0] // "-")] | join("\t")' | column -t -s $'\t'
    echo -e "${CYAN}-------------------------------------------------------------------------------------------------------------------${NC}"
    echo
}

create_telemt_user() {
    if systemctl list-unit-files | grep -q telemt.service; then
        if [[ ! -f "${TELEMT_CONF_DIR}/${TELEMT_CONF}" ]]; then
            error "Telemt config not found"
            exit 1
        fi
        proxy_users_list
        until [[ ${PROXY_USER_NAME_NEW} =~ ^[a-zA-Z0-9_\-]+$ && ${PROXY_USER_EXISTS} == '0' && "${#PROXY_USER_NAME_NEW}" -ge 1 && ${#PROXY_USER_NAME_NEW} -lt 16 ]]; do
            echo
            read -rp "Enter proxy username: " -e PROXY_USER_NAME_NEW
            PROXY_USER_EXISTS=$(grep -c -E "^${PROXY_USER_NAME_NEW}\s\=.*\$" "${TELEMT_CONF_DIR}/${TELEMT_CONF}")
            if [[ ${PROXY_USER_EXISTS} != 0 ]]; then
                echo
                warn "User ${CYAN}${PROXY_USER_NAME_NEW}${NC} already exist"
                warn "Please enter a different name"
            fi
        done
    PROXY_USER_SECRET_NEW=$(openssl rand -hex 16)
    sed -i  "/\[access\.users\]/a\\${PROXY_USER_NAME_NEW} = \"${PROXY_USER_SECRET_NEW}\"" ${TELEMT_CONF_DIR}/${TELEMT_CONF}
    echo
    success "User added: ${CYAN}${PROXY_USER_NAME_NEW}${NC}"
    echo
    sleep 3
    proxy_users_list
    else
        error "Telemt is not installed"
    fi
}

delete_telemt_user() {
    if systemctl list-unit-files | grep -q telemt.service; then
        if [[ ! -f "${TELEMT_CONF_DIR}/${TELEMT_CONF}" ]]; then
            error "Telemt config not found"
            exit 1
        fi
        proxy_users_list
        until [[ ${PROXY_USER_NAME_DEL} =~ ^[a-zA-Z0-9_\-]+$ && ${PROXY_USER_EXISTS} == '1' && "${#PROXY_USER_NAME_DEL}" -ge 1 && ${#PROXY_USER_NAME_DEL} -lt 16 ]]; do
            echo
            read -rp "Enter proxy username: " -e PROXY_USER_NAME_DEL
            PROXY_USER_EXISTS=$(grep -c -E "^${PROXY_USER_NAME_DEL}\s\=.*\$" "${TELEMT_CONF_DIR}/${TELEMT_CONF}")
            if [[ ${PROXY_USER_EXISTS} == 0 ]]; then
                echo
                warn "User ${CYAN}${PROXY_USER_NAME_DEL}${NC} non found"
                warn "Please enter a different name"
            fi
        done
    sed -i "/^${PROXY_USER_NAME_DEL}\s\=.*\$/d" "${TELEMT_CONF_DIR}/${TELEMT_CONF}"
    echo
    success "User removed: ${CYAN}${PROXY_USER_NAME_DEL}${NC}"
    echo
    sleep 3
    proxy_users_list
    else
        error "Telemt is not installed"
    fi
}

install_telemt() {
    if systemctl list-unit-files | grep -q telemt.service; then
        telemt_local_version
        echo
        info "Installed Telemt was found. Version: ${MAGENTA}${BOLD}${TELEMT_LOCAL_VER}${NC}"
        echo
        step "-----------------"
        step " Updating Telemt"
        step "-----------------"
        echo
        fetch_telemt_releases
        info "Starting ${CYAN}telemt${NC} service"
        systemctl start telemt
        sleep 5
        if systemctl is-active --quiet telemt; then
            telemt_local_version
            echo
            success "${DIM}Telemt has been successfully updated to ${MAGENTA}${BOLD}${TELEMT_LOCAL_VER}${NC}"
            proxy_users_list
            info "Telemt config: ${CYAN}${TELEMT_CONF_DIR}/${TELEMT_CONF}${NC}"
            info
            info "Check service:"
            info "  systemctl status telemt"
            info
            info "Check logs:"
            info "  journalctl -ef -u telemt --no-hostname -n 40"
            info
        else
            error "Service failed to start"
            echo
            info "Check logs:"
            info "  journalctl -ef -u telemt --no-hostname -n 40"
            echo
            exit 1
        fi
    else
        echo
        step "-------------------"
        step " Installing Telemt"
        step "-------------------"
        echo
        fetch_telemt_releases
        if [[ -f "${TELEMT_CONF_DIR}/${TELEMT_CONF}" ]]; then
            while true; do
                echo
                read -rp "The existing tememt config file has been found. Use it? (yes/no) [yes]: " KEEP_TELEMT_CONF
                case "${KEEP_TELEMT_CONF,,}" in
                    no|n|false|0)
                        KEEP_TELEMT_CONF_STATE=false
                        break
                        ;;
                    yes|y|true|1|"")
                        KEEP_TELEMT_CONF_STATE=true
                        echo
                        info "Using an existing telemt config"
                        break
                        ;;
                    *)
                        warn "Error: Please enter only yes/no/true/false or yes/y/no/n"
                        warn "By default, 'yes' is used when pressing ENTER"
                        ;;
                esac
            done
            if [[ "$KEEP_TELEMT_CONF_STATE" == false ]]; then
                create_telemt_config
            fi
        else
            create_telemt_config
        fi
        info "Creating ${CYAN}telemt${NC} service"
        cat > /etc/systemd/system/telemt.service << EOF
[Unit]
Description=Telemt
After=network-online.target nss-lookup.target
Wants=network-online.target nss-lookup.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/telemt ${TELEMT_CONF_DIR}/${TELEMT_CONF}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable telemt --now > /dev/null 2>&1
        sleep 5
        if systemctl is-active --quiet telemt; then
            telemt_local_version
            echo
            success "${DIM}Telemt ${MAGENTA}${BOLD}${TELEMT_LOCAL_VER}${NC} has been successfully installed"
            proxy_users_list
            info "Telemt config: ${CYAN}${TELEMT_CONF_DIR}/${TELEMT_CONF}${NC}"
            info
            info "Check service:"
            info "  systemctl status telemt"
            info
            info "Check logs:"
            info "  journalctl -ef -u telemt --no-hostname -n 40"
            echo
        else
            error "Service failed to start"
            echo
            info "Check logs:"
            info "  journalctl -ef -u telemt --no-hostname -n 40"
            echo
            exit 1
        fi
    fi
}

install_telemt_panel() {
    if systemctl list-unit-files | grep -q telemt.service; then
        if systemctl list-unit-files | grep -q telemt-panel.service; then
            echo
            info "Installed Telemt Panel was found"
            echo
            step "-----------------------"
            step " Updating Telemt Panel"
            step "-----------------------"
            echo
            fetch_panel_releases
            info "Starting ${CYAN}telemt-panel${NC} service"
            systemctl start telemt-panel
            if systemctl is-active --quiet telemt-panel; then
                echo
                success "${DIM}Telemt Panel has been successfully updated to ${MAGENTA}${BOLD}${RELEASE_TAG}${NC}"
                echo
                info "Panel config: ${CYAN}${PANEL_CONF_DIR}/${PANEL_CONF}${NC}"
                info
                info "Check service:"
                info "  systemctl status telemt-panel"
                info
                info "Check logs:"
                info "  journalctl -ef -u telemt-panel --no-hostname -n 40"
                info
            else
                error "Service failed to start"
                echo
                info "Check logs:"
                info "  journalctl -ef -u telemt-panel --no-hostname -n 40"
                echo
                exit 1
            fi
        else
            echo
            step "-------------------------"
            step " Installing Telemt Panel"
            step "-------------------------"
            echo
            fetch_panel_releases
            if [[ -f "${PANEL_CONF_DIR}/${PANEL_CONF}" ]]; then
                while true; do
                    echo
                    read -rp "The existing panel config file has been found. Use it? (yes/no) [yes]: " KEEP_PANEL_CONF
                    case "${KEEP_PANEL_CONF,,}" in
                        no|n|false|0)
                            KEEP_PANEL_CONF_STATE=false
                            break
                            ;;
                        yes|y|true|1|"")
                            KEEP_PANEL_CONF_STATE=true
                            echo
                            info "Using an existing panel config"
                            break
                            ;;
                        *)
                            warn "Error: Please enter only yes/no/true/false or yes/y/no/n"
                            warn "By default, 'yes' is used when pressing ENTER"
                            ;;
                    esac
                done
                if [[ "$KEEP_PANEL_CONF_STATE" == false ]]; then
                    create_panel_config
                fi
            else
                create_panel_config
            fi
            info "Creating ${CYAN}telemt-panel${NC} service"
            cat > /etc/systemd/system/telemt-panel.service << EOF
[Unit]
Description=Telemt Panel
After=network-online.target nss-lookup.target
Wants=network-online.target nss-lookup.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/telemt-panel --config ${PANEL_CONF_DIR}/${PANEL_CONF}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable telemt-panel --now > /dev/null 2>&1
            if systemctl is-active --quiet telemt-panel; then
                echo
                success "${DIM}Telemt Panel ${MAGENTA}${BOLD}${RELEASE_TAG}${NC} has been successfully installed"
                echo
                info "Telemt Panel is running at ${BOLD}http://$(hostname -I | awk '{print $1}'):$PANEL_PORT${NC}"
                info
                info "Panel config: ${CYAN}${PANEL_CONF_DIR}/${PANEL_CONF}${NC}"
                info
                info "Check service:"
                info "  systemctl status telemt-panel"
                info
                info "Check logs:"
                info "  journalctl -ef -u telemt-panel --no-hostname -n 40"
                echo
            else
                error "Service failed to start"
                echo
                info "Check logs:"
                info "  journalctl -ef -u telemt-panel --no-hostname -n 40"
                echo
                exit 1
            fi
        fi
    else
        echo
        warn "Telemt not installed"
        install_telemt
        install_telemt_panel
    fi
}

uninstall_telemt() {
    if systemctl list-unit-files | grep -q telemt.service; then
        echo
        step "---------------------"
        step " Uninstalling Telemt"
        step "---------------------"
        echo
        systemctl stop telemt > /dev/null 2>&1
        systemctl disable telemt > /dev/null 2>&1
        rm -f /etc/systemd/system/telemt.service
        systemctl daemon-reload
        rm -f ${INSTALL_DIR}/telemt
        if [[ -f "${TELEMT_CONF_DIR}/${TELEMT_CONF}" ]]; then
            while true; do
                read -rp "Delete Telemt config file? (yes/no) [no]: " DEL_TELEMT_CONF
                case "${DEL_TELEMT_CONF,,}" in
                    yes|y|true|1)
                        DEL_TELEMT_CONF_STATE=true
                        echo
                        info "Telemt config file has been deleted"
                        break
                        ;;
                    no|n|false|0|"")
                        DEL_TELEMT_CONF_STATE=false
                        echo
                        info "Telemt config file has been saved"
                        break
                        ;;
                    *)
                        warn "Error: Please enter only yes/no/true/false or yes/y/no/n"
                        warn "By default, 'no' is used when pressing Enter"
                        ;;
                esac
            done
            if [[ "$DEL_TELEMT_CONF_STATE" == true ]]; then
                rm -rf ${TELEMT_CONF_DIR}
            fi
        fi
        echo
        success "Done"
        echo
    else
        echo
        info "Telemt is not installed"
        info "Nothing to do"
        echo
    fi
}

uninstall_telemt_panel() {
    if systemctl list-unit-files | grep -q telemt-panel.service; then
        echo
        step "---------------------------"
        step " Uninstalling Telemt Panel"
        step "---------------------------"
        echo
        systemctl stop telemt-panel > /dev/null 2>&1
        systemctl disable telemt-panel > /dev/null 2>&1
        rm -f /etc/systemd/system/telemt-panel.service
        systemctl daemon-reload
        rm -f ${INSTALL_DIR}/telemt-panel
        if [[ -f "${PANEL_CONF_DIR}/${PANEL_CONF}" ]]; then
            while true; do
                read -rp "Delete Telemt Panel config file? (yes/no) [no]: " DEL_TELEMT_PANEL_CONF
                case "${DEL_TELEMT_PANEL_CONF,,}" in
                    yes|y|true|1)
                        DEL_TELEMT_PANEL_CONF_STATE=true
                        echo
                        info "Telemt Panel config file has been deleted"
                        break
                        ;;
                    no|n|false|0|"")
                        DEL_TELEMT_PANEL_CONF_STATE=false
                        echo
                        info "Telemt Panel config file has been saved"
                        break
                        ;;
                    *)
                        warn "Error: Please enter only yes/no/true/false or yes/y/no/n"
                        warn "By default, 'no' is used when pressing ENTER"
                        ;;
                esac
            done
            if [[ "$DEL_TELEMT_PANEL_CONF_STATE" == true ]]; then
                rm -rf ${PANEL_CONF_DIR}
            fi
        fi
        echo
        success "Done"
        echo
    else
        echo
        info "Telemt Panel is not installed"
        info "Nothing to do"
        echo
    fi
}

manage_menu() {
    echo
    echo -e "${BOLD}${CYAN} ----------------${NC}"
    echo -e "${BOLD}${CYAN}  Telemt Manager${NC}"
    echo -e "${BOLD}${CYAN} ----------------${NC}"
    echo
    echo -e "   ${BOLD}1)${NC} Install or update Telemt"
    echo -e "   ${BOLD}2)${NC} Add proxy user"
    echo -e "   ${BOLD}3)${NC} Delete proxy user"
    echo -e "   ${BOLD}4)${NC} Show proxy links"
    echo -e "   ${BOLD}5)${NC} Install or update Telemt Panel"
    echo -e "   ${BOLD}6)${NC} Uninstall Telemt"
    echo -e "   ${BOLD}7)${NC} Uninstall Telemt Panel"
    echo -e "   ${BOLD}0)${NC} Exit"
    echo
    until [[ ${MENU_OPTION} =~ ^[0-9]$ ]]; do
            read -rp "Select an option: " MENU_OPTION
    done
    case "${MENU_OPTION}" in
        1)
            install_telemt
            ;;
        2)
            create_telemt_user
            ;;
        3)
            delete_telemt_user
            ;;
        4)
            proxy_users_list
            ;;
        5)
            install_telemt_panel
            ;;
        6)
            uninstall_telemt
            ;;
        7)
            uninstall_telemt_panel
            ;;
        0)
            echo
            info "Bye, see you later"
            echo
            exit 0
            ;;
        *)
            echo
            info "Bye, see you later"
            echo
            exit 0
            ;;
    esac
}

check_dependencies
manage_menu
