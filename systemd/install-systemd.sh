#!/bin/bash

# MediaIndexer systemd Installation Script

set -euo pipefail

# Farben für Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Root-Rechte prüfen
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

# Benutzer und Gruppe erstellen
create_user() {
    if ! id mediaindexer &>/dev/null; then
        log "Creating mediaindexer user and group..."
        useradd -r -s /bin/false -d /var/lib/mediaindexer -m mediaindexer
    else
        log "User mediaindexer already exists"
    fi
}

# Verzeichnisse erstellen
create_directories() {
    log "Creating directories..."
    
    # Hauptverzeichnisse
    mkdir -p /opt/mediaindexer
    mkdir -p /etc/mediaindexer
    mkdir -p /var/lib/mediaindexer/{input,output,temp}
    mkdir -p /var/log/mediaindexer
    
    # Berechtigungen setzen
    chown -R mediaindexer:mediaindexer /var/lib/mediaindexer
    chown -R mediaindexer:mediaindexer /var/log/mediaindexer
    chown -R root:root /opt/mediaindexer
    chown -R root:root /etc/mediaindexer
    
    # Script ausführbar für mediaindexer user
    chmod 755 /opt/mediaindexer
    chmod 644 /etc/mediaindexer
}

# Dateien installieren
install_files() {
    local source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    
    log "Installing files..."
    
    # Hauptscript kopieren
    cp "$source_dir/mediaindexer.sh" /opt/mediaindexer/
    chmod 755 /opt/mediaindexer/mediaindexer.sh
    
    # Konfiguration kopieren
    cp "$source_dir/mediaindexer.env" /etc/mediaindexer/
    chmod 644 /etc/mediaindexer/mediaindexer.env
    
    # Systemd-Service-Dateien kopieren
    cp "$source_dir/systemd/mediaindexer@.service" /etc/systemd/system/
    cp "$source_dir/systemd/mediaindexer.target" /etc/systemd/system/
}

# Systemd konfigurieren
configure_systemd() {
    log "Configuring systemd..."
    
    # Systemd neu laden
    systemctl daemon-reload
    
    # Services aktivieren (aber noch nicht starten)
    systemctl enable mediaindexer@filmstrip.service
    systemctl enable mediaindexer@waveform.service
    systemctl enable mediaindexer@jsoninfo.service
    systemctl enable mediaindexer@xmlinfo.service
    systemctl enable mediaindexer@r128sum.service
    
    # Target aktivieren
    systemctl enable mediaindexer.target
}

# Logrotate konfigurieren
setup_logrotate() {
    log "Setting up log rotation..."
    
    cat > /etc/logrotate.d/mediaindexer << 'EOF'
/var/log/mediaindexer/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 mediaindexer mediaindexer
    postrotate
        systemctl reload-or-restart mediaindexer.target
    endscript
}
EOF
}

# Status anzeigen
show_status() {
    log "Installation completed!"
    echo
    echo -e "${BLUE}Configuration:${NC}"
    echo "  Config file: /etc/mediaindexer/mediaindexer.env"
    echo "  Scripts: /opt/mediaindexer/"
    echo "  Data: /var/lib/mediaindexer/"
    echo "  Logs: /var/log/mediaindexer/"
    echo
    echo -e "${BLUE}Management commands:${NC}"
    echo "  systemctl start mediaindexer.target    # Start all services"
    echo "  systemctl stop mediaindexer.target     # Stop all services"
    echo "  systemctl status mediaindexer.target   # Show status"
    echo
    echo "  systemctl start mediaindexer@filmstrip.service   # Start single service"
    echo "  systemctl status mediaindexer@waveform.service   # Check single service"
    echo
    echo "  journalctl -u mediaindexer@filmstrip.service -f  # Follow logs"
    echo "  journalctl -u mediaindexer.target -f             # Follow all logs"
    echo
    echo -e "${BLUE}Configuration:${NC}"
    echo "  Edit /etc/mediaindexer/mediaindexer.env to configure paths and options"
    echo
    echo -e "${YELLOW}Next steps:${NC}"
    echo "  1. Edit configuration: nano /etc/mediaindexer/mediaindexer.env"
    echo "  2. Start services: systemctl start mediaindexer.target"
    echo "  3. Check status: systemctl status mediaindexer.target"
}

# Hilfefunktion
show_help() {
    cat << EOF
MediaIndexer systemd Installation Script

Usage: $0 [OPTIONS]

OPTIONS:
  --uninstall    Remove MediaIndexer systemd services
  --status       Show current installation status
  -h, --help     Show this help

Default behavior (no options):
  - Create mediaindexer user and directories
  - Install scripts and configuration
  - Setup systemd services
  - Configure log rotation

Examples:
  $0               # Install MediaIndexer
  $0 --status      # Show status
  $0 --uninstall   # Remove installation

EOF
}

# Deinstallation
uninstall() {
    log "Uninstalling MediaIndexer..."
    
    # Services stoppen und deaktivieren
    systemctl stop mediaindexer.target 2>/dev/null || true
    systemctl disable mediaindexer.target 2>/dev/null || true
    
    for service in filmstrip waveform jsoninfo xmlinfo r128sum r128log mxfinfo; do
        systemctl stop "mediaindexer@${service}.service" 2>/dev/null || true
        systemctl disable "mediaindexer@${service}.service" 2>/dev/null || true
    done
    
    # Service-Dateien entfernen
    rm -f /etc/systemd/system/mediaindexer@.service
    rm -f /etc/systemd/system/mediaindexer.target
    
    # Systemd neu laden
    systemctl daemon-reload
    
    # Dateien entfernen
    rm -rf /opt/mediaindexer
    rm -rf /etc/mediaindexer
    rm -f /etc/logrotate.d/mediaindexer
    
    # Daten und Logs behalten, aber fragen
    echo
    read -p "Remove data directories? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf /var/lib/mediaindexer
        rm -rf /var/log/mediaindexer
        userdel mediaindexer 2>/dev/null || true
        log "Data directories and user removed"
    else
        log "Data directories and user preserved"
    fi
    
    log "Uninstallation completed"
}

# Status anzeigen
show_installation_status() {
    echo -e "${BLUE}MediaIndexer Installation Status${NC}"
    echo "================================="
    echo
    
    # User prüfen
    if id mediaindexer &>/dev/null; then
        echo -e "User: ${GREEN}mediaindexer exists${NC}"
    else
        echo -e "User: ${RED}mediaindexer missing${NC}"
    fi
    
    # Verzeichnisse prüfen
    for dir in /opt/mediaindexer /etc/mediaindexer /var/lib/mediaindexer /var/log/mediaindexer; do
        if [[ -d "$dir" ]]; then
            echo -e "Directory $dir: ${GREEN}exists${NC}"
        else
            echo -e "Directory $dir: ${RED}missing${NC}"
        fi
    done
    
    # Services prüfen
    echo
    echo "Services:"
    systemctl list-units --all 'mediaindexer*' --no-legend | while read line; do
        service=$(echo "$line" | awk '{print $1}')
        status=$(echo "$line" | awk '{print $3}')
        case "$status" in
            active) color="$GREEN" ;;
            inactive) color="$YELLOW" ;;
            failed) color="$RED" ;;
            *) color="$NC" ;;
        esac
        echo -e "  $service: ${color}${status}${NC}"
    done
}

# Hauptfunktion
main() {
    case "${1:-}" in
        --uninstall)
            check_root
            uninstall
            ;;
        --status)
            show_installation_status
            ;;
        -h|--help)
            show_help
            ;;
        "")
            check_root
            create_user
            create_directories
            install_files
            configure_systemd
            setup_logrotate
            show_status
            ;;
        *)
            error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
