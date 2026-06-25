#!/bin/bash
# =============================================================================
#  Blueprint Plugin Reinstaller
#  Automatically reinstalls all Blueprint (Pterodactyl) plugins on this machine
#  https://github.com/luoxthedev/plugin-installer-for-blueprint
# =============================================================================

set -euo pipefail

VERSION="v1.3.0"

# ── Colors & formatting ───────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Banner ────────────────────────────────────────────────────────────────────
print_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "  ██████╗ ██╗     ██╗   ██╗███████╗██████╗ ██████╗ ██╗███╗   ██╗████████╗"
    echo "  ██╔══██╗██║     ██║   ██║██╔════╝██╔══██╗██╔══██╗██║████╗  ██║╚══██╔══╝"
    echo "  ██████╔╝██║     ██║   ██║█████╗  ██████╔╝██████╔╝██║██╔██╗ ██║   ██║   "
    echo "  ██╔══██╗██║     ██║   ██║██╔══╝  ██╔═══╝ ██╔══██╗██║██║╚██╗██║   ██║   "
    echo "  ██████╔╝███████╗╚██████╔╝███████╗██║     ██║  ██║██║██║ ╚████║   ██║   "
    echo "  ╚═════╝ ╚══════╝ ╚═════╝ ╚══════╝╚═╝     ╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝   ╚═╝   "
    echo -e "${RESET}"
    echo -e "${DIM}  Blueprint Plugin Reinstaller — Pterodactyl Panel (${VERSION})${RESET}"
    echo -e "${DIM}  ─────────────────────────────────────────────────────────────${RESET}"
    echo ""
}

# ── Logging helpers ───────────────────────────────────────────────────────────
info()    { echo -e "  ${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "  ${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "  ${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "  ${RED}[ERROR]${RESET} $*" >&2; }
step()    { echo -e "\n  ${BLUE}${BOLD}▶ $*${RESET}"; }
divider() { echo -e "  ${DIM}────────────────────────────────────────────────────${RESET}"; }

# ── Root check ────────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)."
        exit 1
    fi
}

# ── Update / Install Global Command ───────────────────────────────────────────
sync_global_command() {
    local target="/usr/local/bin/blueprint-plugin-installer"
    
    info "Syncing and updating global command 'blueprint-plugin-installer'..."
    
    if [[ -f "$0" && "$(basename "$0")" == "install.sh" ]]; then
        cp "$(realpath "$0")" "$target"
    else
        curl -fsSL "https://raw.githubusercontent.com/luoxthedev/plugin-installer-for-blueprint/main/install.sh" -o "$target"
    fi
    
    chmod +x "$target"
}

# ── Dependency check & Auto-installer ─────────────────────────────────────────
check_dependencies() {
    step "Checking dependencies..."
    local missing=()
    local apt_packages=()

    for cmd in php composer curl unzip jq blueprint; do
        if command -v "$cmd" &>/dev/null; then
            success "$cmd is available"
        else
            # On n'essaie pas d'installer 'blueprint' via apt s'il manque
            if [[ "$cmd" == "blueprint" ]]; then
                error "The 'blueprint' global command is missing. Please install Blueprint Framework first."
                exit 1
            fi

            warn "$cmd is NOT found"
            missing+=("$cmd")
            
            if [[ "$cmd" == "composer" ]]; then
                apt_packages+=("composer")
            elif [[ "$cmd" == "php" ]]; then
                apt_packages+=("php-cli")
            else
                apt_packages+=("$cmd")
            fi
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo ""
        warn "Missing required dependencies: ${missing[*]}"
        info "Updating package lists to calculate download size..."
        
        apt-get update -qq
        
        local size_info
        size_info=$(apt-get install -s -y "${apt_packages[@]}" 2>/dev/null | grep -E "Need to get|after this operation" || true)
        
        local disk_space="unknown size"
        if [[ "$size_info" =~ ([0-9]+[[:space:]]*[kMGT]B)[[:space:]]of[[:space:]]additional ]]; then
            disk_space="${BASH_REMATCH[1]}"
        elif [[ "$size_info" =~ ([0-9,.]+[[:space:]]*[kMGT]b)[[:space:]]d\’espace ]]; then
            disk_space="${BASH_REMATCH[1]}"
        fi

        echo ""
        info "Estimated disk space needed for installation: ${BOLD}$disk_space${RESET}"
        
        # </dev/tty force la lecture depuis le clavier même en mode curl | bash
        read -rp "  Would you like to automatically install these dependencies now? [y/N] " confirm </dev/tty
        
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            step "Installing missing dependencies..."
            if apt-get install -y "${apt_packages[@]}"; then
                success "All dependencies successfully installed!"
            else
                error "Failed to install dependencies automatically. Please run: apt-get install -y ${apt_packages[*]}"
                exit 1
            fi
        else
            info "Aborted by user. Missing tools prevent script execution."
            exit 0
        fi
    fi
}

# ── Detect Pterodactyl directory ──────────────────────────────────────────────
detect_blueprint_path() {
    step "Detecting Pterodactyl installation..."

    local candidates=(
        "/var/www/pterodactyl"
        "/var/www/panel"
        "/srv/pterodactyl"
        "/opt/pterodactyl"
    )

    PANEL_DIR=""
    for dir in "${candidates[@]}"; do
        if [[ -f "$dir/config/app.php" ]]; then
            PANEL_DIR="$dir"
            break
        fi
    done

    if [[ -z "$PANEL_DIR" ]]; then
        warn "Could not auto-detect Pterodactyl directory."
        read -rp "  Enter the panel root path manually: " PANEL_DIR </dev/tty
        if [[ ! -d "$PANEL_DIR" ]]; then
            error "Directory '$PANEL_DIR' does not exist. Aborting."
            exit 1
        fi
    fi

    success "Panel found at: ${BOLD}$PANEL_DIR${RESET}"
}

# ── Discover .blueprint files ─────────────────────────────────────────────────
discover_plugins() {
    step "Scanning for .blueprint extension files..."

    local files
    files=$(find "$PANEL_DIR" -maxdepth 1 -name "*.blueprint" -type f 2>/dev/null | sort || true)

    PLUGINS=()
    if [[ -n "$files" ]]; then
        while read -r file; do
            if [[ -n "$file" ]]; then
                local name
                name=$(basename "$file" .blueprint)
                PLUGINS+=("$name")
            fi
        done <<< "$files"
    fi

    local count=${#PLUGINS[@]}

    echo ""
    divider

    if [[ $count -eq 0 ]]; then
        warn "No '.blueprint' files were found in $PANEL_DIR"
        exit 0
    fi

    echo -e "  ${GREEN}${BOLD}Found $count extension file(s):${RESET}"
    echo ""
    for i in "${!PLUGINS[@]}"; do
        local num=$((i + 1))
        printf "  ${DIM}%2d.${RESET}  ${BOLD}%s.blueprint${RESET}\n" "$num" "${PLUGINS[$i]}"
    done

    divider
    echo ""
}

# ── Ask the user what to install ──────────────────────────────────────────────
ask_user() {
    echo -e "  ${BOLD}What would you like to do?${RESET}"
    echo ""
    echo -e "    ${CYAN}[A]${RESET}  Reinstall ALL extensions (${#PLUGINS[@]} total)"
    echo -e "    ${CYAN}[S]${RESET}  Select specific extensions"
    echo -e "    ${CYAN}[Q]${RESET}  Quit"
    echo ""
    
    local choice=""
    read -rp "  Your choice [A/S/Q]: " choice </dev/tty
    echo ""

    case "${choice^^}" in
        A)
            SELECTED_PLUGINS=("${PLUGINS[@]}")
            info "All ${#SELECTED_PLUGINS[@]} extensions will be reinstalled."
            ;;
        S)
            select_plugins
            ;;
        Q)
            info "Aborted. No changes were made."
            exit 0
            ;;
        *)
            warn "Invalid choice. Please enter A, S, or Q."
            ask_user
            ;;
    esac
}

# ── Manual selection ──────────────────────────────────────────────────────────
select_plugins() {
    echo -e "  Enter the ${BOLD}numbers${RESET} of the extensions to reinstall, separated by spaces."
    echo -e "  Example: ${DIM}1 3 5${RESET}"
    echo ""
    local raw_indices=()
    read -rp "  Extensions: " -a raw_indices </dev/tty
    echo ""

    SELECTED_PLUGINS=()
    for idx in "${raw_indices[@]}"; do
        if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#PLUGINS[@]} )); then
            SELECTED_PLUGINS+=("${PLUGINS[$((idx-1))]}")
        else
            warn "Skipping invalid index: $idx"
        fi
    done

    if [[ ${#SELECTED_PLUGINS[@]} -eq 0 ]]; then
        warn "No valid extensions selected. Aborting."
        exit 0
    fi

    info "Selected: ${SELECTED_PLUGINS[*]}"
}

# ── Confirmation ──────────────────────────────────────────────────────────────
confirm_reinstall() {
    local count=${#SELECTED_PLUGINS[@]}
    echo ""
    echo -e "  ${YELLOW}${BOLD}⚠  You are about to REINSTALL $count extension(s):${RESET}"
    echo ""
    for p in "${SELECTED_PLUGINS[@]}"; do
        echo -e "    ${DIM}•${RESET} $p.blueprint"
    done
    echo ""
    warn "This will re-run the Blueprint framework install command."
    warn "Existing data in the database is NOT removed."
    echo ""
    local confirm=""
    read -rp "  Confirm reinstall? [y/N] " confirm </dev/tty
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "Aborted by user."; exit 0; }
    echo ""
}

# ── Reinstall plugins ─────────────────────────────────────────────────────────
reinstall_plugins() {
    step "Starting reinstallation..."
    echo ""

    local total=${#SELECTED_PLUGINS[@]}
    local success_count=0
    local fail_count=0
    local failed_list=()

    cd "$PANEL_DIR"

    for i in "${!SELECTED_PLUGINS[@]}"; do
        local plugin="${SELECTED_PLUGINS[$i]}"
        local num=$((i + 1))

        echo -e "  ${BOLD}[$num/$total]${RESET} Installing ${CYAN}${plugin}.blueprint${RESET}..."

        # Correction ici : Utilisation directe de la commande globale 'blueprint -i'
        if blueprint -i "$plugin" 2>&1 | sed 's/^/          /'; then
            success "[$num/$total] ${plugin} — done"
            (( success_count++ )) || true
        else
            error "[$num/$total] ${plugin} — FAILED"
            (( fail_count++ )) || true
            failed_list+=("$plugin")
        fi

        echo ""
    done

    # ── Summary ───────────────────────────────────────────────────────────────
    divider
    echo ""
    echo -e "  ${BOLD}Reinstallation Summary${RESET}"
    echo ""
    echo -e "    ${GREEN}✔  Success:${RESET}  $success_count / $total"

    if [[ $fail_count -gt 0 ]]; then
        echo -e "    ${RED}✘  Failed:${RESET}   $fail_count / $total"
        echo ""
        echo -e "  ${RED}Failed extensions:${RESET}"
        for p in "${failed_list[@]}"; do
            echo -e "    ${DIM}•${RESET} $p.blueprint"
        done
    fi

    echo ""
    divider
}

# ── Post-install tasks ────────────────────────────────────────────────────────
post_install() {
    step "Running post-install tasks..."

    cd "$PANEL_DIR"

    info "Clearing Laravel cache..."
    php artisan cache:clear    2>&1 | sed 's/^/          /'
    php artisan config:clear   2>&1 | sed 's/^/          /'
    php artisan view:clear     2>&1 | sed 's/^/          /'
    php artisan route:clear    2>&1 | sed 's/^/          /'
    success "Cache cleared."

    info "Running database migrations..."
    php artisan migrate --force 2>&1 | sed 's/^/          /'
    success "Migrations done."

    info "Setting correct permissions..."
    chown -R www-data:www-data "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null || \
    chown -R nginx:nginx      "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null || \
    warn "Could not set permissions automatically. Set them manually if needed."
    success "Permissions applied."

    info "Restarting queue workers..."
    php artisan queue:restart 2>&1 | sed 's/^/          /'
    success "Queue restarted."
}

# ── Entrypoint ────────────────────────────────────────────────────────────────
main() {
    print_banner
    check_root
    sync_global_command
    check_dependencies
    detect_blueprint_path
    discover_plugins
    ask_user
    confirm_reinstall
    reinstall_plugins
    post_install

    echo ""
    echo -e "  ${GREEN}${BOLD}✔  All done! Your Blueprint extensions have been reinstalled.${RESET}"
    echo -e "  ${DIM}If you encounter issues, check the logs in $PANEL_DIR/storage/logs/${RESET}"
    echo ""
}

main "$@"
