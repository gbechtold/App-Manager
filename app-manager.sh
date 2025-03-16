#!/bin/bash

# App Manager for Server Applications
# Created on: 16.03.2025
# Updated on: 16.03.2025

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default directories
DEFAULT_APP_ROOT="/opt/apps"
APP_ROOT=${APP_ROOT:-"$DEFAULT_APP_ROOT"}
TRAEFIK_DIR="$APP_ROOT/traefik"
LOG_DIR="$APP_ROOT/logs"
BACKUP_DIR="$APP_ROOT/backups"

# Logging
setup_logging() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/app-manager-$(date +%Y%m%d).log"
    
    # Create log file if it doesn't exist
    touch "$LOG_FILE"
    
    # Log to both console and file
    exec > >(tee -a "$LOG_FILE") 2>&1
    
    echo "===== App Manager started at $(date) ====="
}

# Function to create or update global .env file
setup_env() {
    ENV_FILE="$APP_ROOT/.env"
    mkdir -p "$APP_ROOT"
    
    # Check if .env file already exists
    if [ -f "$ENV_FILE" ]; then
        echo -e "${BLUE}Configuration file found. Using existing settings.${NC}"
        source "$ENV_FILE"
    else
        echo -e "${BLUE}Setting up configuration...${NC}"
        
        # Prompt for domain
        read -p "Enter your domain suffix (e.g., example.com): " domain_input
        DOMAIN_SUFFIX=${domain_input:-"example.com"}
        
        # Prompt for email (for Let's Encrypt)
        read -p "Enter email for Let's Encrypt certificates: " email_input
        EMAIL=${email_input:-"admin@$DOMAIN_SUFFIX"}
        
        # Prompt for HTTP/HTTPS ports
        read -p "Enter HTTP port (default: 80): " http_port_input
        HTTP_PORT=${http_port_input:-"80"}
        
        read -p "Enter HTTPS port (default: 443): " https_port_input
        HTTPS_PORT=${https_port_input:-"443"}
        
        # Create .env file
        cat > "$ENV_FILE" << EOL
# Global settings for app-manager
# Created on: $(date)

# Domain settings
DOMAIN_SUFFIX=$DOMAIN_SUFFIX
ADMIN_EMAIL=$EMAIL

# Paths
APP_ROOT=$APP_ROOT
TRAEFIK_DIR=$TRAEFIK_DIR
LOG_DIR=$LOG_DIR
BACKUP_DIR=$BACKUP_DIR

# Network settings
HTTP_PORT=$HTTP_PORT
HTTPS_PORT=$HTTPS_PORT
EOL
        
        echo -e "${GREEN}Configuration saved to $ENV_FILE${NC}"
        source "$ENV_FILE"
        
        # Create directories if they don't exist
        mkdir -p "$TRAEFIK_DIR" "$BACKUP_DIR"
    fi
}

# Check if the Traefik network exists
ensure_traefik_network() {
    echo -e "${BLUE}Checking Traefik network...${NC}"
    if ! docker network inspect traefik-net &>/dev/null; then
        echo -e "${YELLOW}Traefik network does not exist. Creating...${NC}"
        docker network create traefik-net
        echo -e "${GREEN}Traefik network created.${NC}"
    else
        echo -e "${GREEN}Traefik network already exists.${NC}"
    fi
}

# Make sure no Nginx or other service is blocking ports 80/443
check_port_availability() {
    echo -e "${BLUE}Checking port availability...${NC}"
    
    # Check if HTTP port is being used
    if netstat -tulpn 2>/dev/null | grep -q ":$HTTP_PORT "; then
        echo -e "${YELLOW}Port $HTTP_PORT is already in use. Checking if it's Nginx or Traefik...${NC}"
        if systemctl is-active nginx &>/dev/null; then
            echo -e "${YELLOW}Nginx is active and blocking port $HTTP_PORT. Stopping and disabling...${NC}"
            systemctl stop nginx
            systemctl disable nginx
            echo -e "${GREEN}Nginx stopped and disabled.${NC}"
        elif docker ps | grep -q traefik; then
            echo -e "${GREEN}Port $HTTP_PORT is being used by Traefik, which is fine.${NC}"
        else
            echo -e "${RED}Port $HTTP_PORT is being used by another service. Please check manually.${NC}"
            netstat -tulpn | grep ":$HTTP_PORT "
            echo -e "${RED}Please stop the blocking service manually.${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}Port $HTTP_PORT is available.${NC}"
    fi
    
    # Check if HTTPS port is being used
    if netstat -tulpn 2>/dev/null | grep -q ":$HTTPS_PORT "; then
        echo -e "${YELLOW}Port $HTTPS_PORT is being used. Checking if it's Traefik...${NC}"
        if docker ps | grep -q traefik; then
            echo -e "${GREEN}Port $HTTPS_PORT is being used by Traefik, which is fine.${NC}"
        else
            echo -e "${RED}Port $HTTPS_PORT is being used by another service. Please check manually.${NC}"
            netstat -tulpn | grep ":$HTTPS_PORT "
            echo -e "${RED}Please stop the blocking service manually.${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}Port $HTTPS_PORT is available.${NC}"
    fi
}

# Install Traefik
install_traefik() {
    echo -e "${BLUE}Installing Traefik...${NC}"
    
    # Create directory for Traefik
    mkdir -p "$TRAEFIK_DIR/config" "$TRAEFIK_DIR/letsencrypt"
    cd "$TRAEFIK_DIR"
    
    # Create traefik.yml configuration
    cat > config/traefik.yml << EOL
global:
  checkNewVersion: true
  sendAnonymousUsage: false

api:
  dashboard: true
  insecure: false

entryPoints:
  web:
    address: ":$HTTP_PORT"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":$HTTPS_PORT"
    http:
      tls:
        certResolver: letsencrypt

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: traefik-net
  file:
    directory: /etc/traefik/dynamic
    watch: true

certificatesResolvers:
  letsencrypt:
    acme:
      email: ${ADMIN_EMAIL}
      storage: /letsencrypt/acme.json
      httpChallenge:
        entryPoint: web
EOL
    
    # Create dynamic configuration for dashboard
    mkdir -p config/dynamic
    cat > config/dynamic/dashboard.yml << EOL
http:
  routers:
    dashboard:
      rule: "Host(\`traefik.${DOMAIN_SUFFIX}\`)"
      service: api@internal
      tls:
        certResolver: letsencrypt
      middlewares:
        - auth
      entryPoints:
        - websecure
  middlewares:
    auth:
      basicAuth:
        users:
          - "${TRAEFIK_USER}:${TRAEFIK_PASSWORD_HASH}"
EOL
    
    # Create docker-compose.yml
    cat > docker-compose.yml << EOL
version: '3'

services:
  traefik:
    image: traefik:v2.10
    container_name: traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    ports:
      - ${HTTP_PORT}:${HTTP_PORT}
      - ${HTTPS_PORT}:${HTTPS_PORT}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ${TRAEFIK_DIR}/config/traefik.yml:/etc/traefik/traefik.yml:ro
      - ${TRAEFIK_DIR}/config/dynamic:/etc/traefik/dynamic:ro
      - ${TRAEFIK_DIR}/letsencrypt:/letsencrypt
    networks:
      - traefik-net
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=traefik-net"

networks:
  traefik-net:
    external: true
EOL
    
    # Start Windmill
    docker-compose up -d
    
    echo -e "${GREEN}Windmill has been installed.${NC}"
    echo -e "${GREEN}Admin Panel: https://${WINDMILL_DOMAIN}${NC}"
    echo -e "${YELLOW}You will need to create an admin account on first login.${NC}"
}

# Backup application
backup_app() {
    app_name=$1
    
    if [ ! -d "$APP_ROOT/$app_name" ]; then
        echo -e "${RED}Application $app_name is not installed.${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}Backing up $app_name...${NC}"
    
    # Create backup directory
    mkdir -p "$BACKUP_DIR"
    backup_file="$BACKUP_DIR/${app_name}_$(date +%Y%m%d%H%M%S).tar.gz"
    
    # Create backup
    cd "$APP_ROOT"
    tar -czf "$backup_file" "$app_name"
    
    echo -e "${GREEN}Backup created: $backup_file${NC}"
}

# Restore application
restore_app() {
    backup_file=$1
    
    if [ ! -f "$backup_file" ]; then
        echo -e "${RED}Backup file does not exist: $backup_file${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}Restoring from backup: $backup_file${NC}"
    
    # Extract app name from backup file
    app_name=$(basename "$backup_file" | cut -d '_' -f 1)
    
    # Stop the app if it's running
    if [ -d "$APP_ROOT/$app_name" ] && [ -f "$APP_ROOT/$app_name/docker-compose.yml" ]; then
        echo -e "${YELLOW}Stopping existing $app_name...${NC}"
        cd "$APP_ROOT/$app_name"
        docker-compose down
    fi
    
    # Backup existing installation if any
    if [ -d "$APP_ROOT/$app_name" ]; then
        echo -e "${YELLOW}Backing up existing installation...${NC}"
        mv "$APP_ROOT/$app_name" "$APP_ROOT/${app_name}_old_$(date +%Y%m%d%H%M%S)"
    fi
    
    # Extract backup
    echo -e "${BLUE}Extracting backup...${NC}"
    cd "$APP_ROOT"
    tar -xzf "$backup_file"
    
    # Start the app
    echo -e "${BLUE}Starting restored $app_name...${NC}"
    cd "$APP_ROOT/$app_name"
    docker-compose up -d
    
    echo -e "${GREEN}$app_name has been restored from backup.${NC}"
}

# List available backups
list_backups() {
    echo -e "${BLUE}Available backups:${NC}"
    
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        echo -e "${YELLOW}No backups found.${NC}"
        return
    fi
    
    for backup in "$BACKUP_DIR"/*.tar.gz; do
        backup_name=$(basename "$backup")
        app_name=$(echo "$backup_name" | cut -d '_' -f 1)
        date_str=$(echo "$backup_name" | cut -d '_' -f 2 | cut -d '.' -f 1)
        
        # Format date
        year=${date_str:0:4}
        month=${date_str:4:2}
        day=${date_str:6:2}
        hour=${date_str:8:2}
        minute=${date_str:10:2}
        second=${date_str:12:2}
        
        echo -e "${GREEN}$app_name${NC} - $year-$month-$day $hour:$minute:$seconds - ${BLUE}$backup${NC}"
    done
}

# List installed apps
list_apps() {
    echo -e "${BLUE}Installed Applications:${NC}"
    
    # Check if Traefik is installed
    if [ -d "$TRAEFIK_DIR" ]; then
        echo -e "${GREEN}✓ Traefik${NC} - Reverse Proxy/Load Balancer"
    fi
    
    # Check if ActivePieces is installed
    if [ -d "$APP_ROOT/activepieces" ]; then
        domain=$(grep "AP_DOMAIN" "$APP_ROOT/activepieces/.env" 2>/dev/null | cut -d '=' -f 2)
        echo -e "${GREEN}✓ ActivePieces${NC} - Automation (https://$domain)"
    fi
    
    # Check if Twenty is installed
    if [ -d "$APP_ROOT/twenty" ]; then
        domain=$(grep "TWENTY_DOMAIN" "$APP_ROOT/twenty/.env" 2>/dev/null | cut -d '=' -f 2)
        echo -e "${GREEN}✓ Twenty CRM${NC} - CRM (https://$domain)"
    fi
    
    # Check if Windmill is installed
    if [ -d "$APP_ROOT/windmill" ]; then
        domain=$(grep "WINDMILL_DOMAIN" "$APP_ROOT/windmill/.env" 2>/dev/null | cut -d '=' -f 2)
        echo -e "${GREEN}✓ Windmill${NC} - Workflow Engine (https://$domain)"
    fi
    
    # Check if Odoo is installed
    if [ -d "$APP_ROOT/odoo" ]; then
        domain=$(grep "ODOO_DOMAIN" "$APP_ROOT/odoo/.env" 2>/dev/null | cut -d '=' -f 2)
        echo -e "${GREEN}✓ Odoo${NC} - ERP (https://$domain)"
    fi
    
    # Check if Mautic is installed
    if [ -d "$APP_ROOT/mautic" ]; then
        domain=$(grep "MAUTIC_DOMAIN" "$APP_ROOT/mautic/.env" 2>/dev/null | cut -d '=' -f 2)
        echo -e "${GREEN}✓ Mautic${NC} - Marketing Automation (https://$domain)"
    fi
}

# Start/Stop/Restart an app
manage_app() {
    action=$1
    app_name=$2
    
    if [ ! -d "$APP_ROOT/$app_name" ]; then
        echo -e "${RED}Application $app_name is not installed.${NC}"
        exit 1
    fi
    
    cd "$APP_ROOT/$app_name"
    
    case "$action" in
        "start")
            echo -e "${BLUE}Starting $app_name...${NC}"
            docker-compose up -d
            echo -e "${GREEN}$app_name has been started.${NC}"
            ;;
        "stop")
            echo -e "${BLUE}Stopping $app_name...${NC}"
            docker-compose down
            echo -e "${GREEN}$app_name has been stopped.${NC}"
            ;;
        "restart")
            echo -e "${BLUE}Restarting $app_name...${NC}"
            docker-compose restart
            echo -e "${GREEN}$app_name has been restarted.${NC}"
            ;;
        "logs")
            echo -e "${BLUE}Showing logs for $app_name...${NC}"
            docker-compose logs -f
            ;;
        *)
            echo -e "${RED}Unknown action: $action${NC}"
            exit 1
            ;;
    esac
}

# Show help
show_help() {
    echo -e "${BLUE}Server Application Manager${NC}"
    echo -e "${BLUE}=========================${NC}"
    echo -e "Usage: $0 [COMMAND] [PARAMETER]"
    echo -e ""
    echo -e "Commands:"
    echo -e "  setup               Configure global settings"
    echo -e "  install APP_NAME    Install the specified application"
    echo -e "  list                List all installed applications"
    echo -e "  start APP_NAME      Start the specified application"
    echo -e "  stop APP_NAME       Stop the specified application"
    echo -e "  restart APP_NAME    Restart the specified application"
    echo -e "  logs APP_NAME       Show logs for the specified application"
    echo -e "  backup APP_NAME     Create a backup of the specified application"
    echo -e "  restore BACKUP_FILE Restore application from a backup file"
    echo -e "  backups             List available backups"
    echo -e ""
    echo -e "Available applications:"
    echo -e "  traefik             Reverse Proxy/Load Balancer"
    echo -e "  activepieces        Automation tool"
    echo -e "  twenty              Twenty CRM"
    echo -e "  windmill            Workflow Engine"
    echo -e "  odoo                ERP System"
    echo -e "  mautic              Marketing Automation"
    echo -e ""
    echo -e "Examples:"
    echo -e "  $0 setup            Configure global settings"
    echo -e "  $0 install odoo     Install Odoo"
    echo -e "  $0 list             List all installed apps"
    echo -e "  $0 restart mautic   Restart Mautic"
    echo -e "  $0 backup twenty    Create a backup of Twenty CRM"
    echo -e "  $0 logs windmill    Show logs for Windmill"
}

# Main function
main() {
    # Setup logging
    setup_logging
    
    # Check if a command was passed
    if [ $# -eq 0 ]; then
        show_help
        exit 0
    fi
    
    command=$1
    
    case "$command" in
        "setup")
            setup_env
            ;;
        "install")
            if [ $# -lt 2 ]; then
                echo -e "${RED}Error: Application name missing.${NC}"
                show_help
                exit 1
            fi
            # Load configuration
            if [ -f "$APP_ROOT/.env" ]; then
                source "$APP_ROOT/.env"
            else
                setup_env
            fi
            # Check port availability
            check_port_availability
            # Ensure Traefik network
            ensure_traefik_network
            # Ensure Traefik is running
            ensure_traefik_running
            # Install the desired app
            install_app $2
            ;;
        "list")
            # Load configuration
            if [ -f "$APP_ROOT/.env" ]; then
                source "$APP_ROOT/.env"
            fi
            list_apps
            ;;
        "start"|"stop"|"restart"|"logs")
            if [ $# -lt 2 ]; then
                echo -e "${RED}Error: Application name missing.${NC}"
                show_help
                exit 1
            fi
            # Load configuration
            if [ -f "$APP_ROOT/.env" ]; then
                source "$APP_ROOT/.env"
            fi
            manage_app $1 $2
            ;;
        "backup")
            if [ $# -lt 2 ]; then
                echo -e "${RED}Error: Application name missing.${NC}"
                show_help
                exit 1
            fi
            # Load configuration
            if [ -f "$APP_ROOT/.env" ]; then
                source "$APP_ROOT/.env"
            fi
            backup_app $2
            ;;
        "restore")
            if [ $# -lt 2 ]; then
                echo -e "${RED}Error: Backup file path missing.${NC}"
                show_help
                exit 1
            fi
            # Load configuration
            if [ -f "$APP_ROOT/.env" ]; then
                source "$APP_ROOT/.env"
            fi
            restore_app $2
            ;;
        "backups")
            # Load configuration
            if [ -f "$APP_ROOT/.env" ]; then
                source "$APP_ROOT/.env"
            fi
            list_backups
            ;;
        "help"|"--help"|"-h")
            show_help
            ;;
        *)
            echo -e "${RED}Unknown command: $command${NC}"
            show_help
            exit 1
            ;;
    esac
}

# Start the main program
main "$@" Traefik
    docker-compose up -d
    
    echo -e "${GREEN}Traefik has been installed.${NC}"
    echo -e "${GREEN}Dashboard: https://traefik.${DOMAIN_SUFFIX}${NC}"
    echo -e "${YELLOW}Username: ${TRAEFIK_USER}${NC}"
    echo -e "${YELLOW}Password: ${TRAEFIK_PASSWORD}${NC}"
}

# Prepare Traefik setup
prepare_traefik() {
    # Check if Traefik is already installed
    if [ -d "$TRAEFIK_DIR" ] && [ -f "$TRAEFIK_DIR/docker-compose.yml" ]; then
        echo -e "${GREEN}Traefik is already installed.${NC}"
        return
    fi
    
    # Generate credentials for Traefik dashboard
    TRAEFIK_USER=${TRAEFIK_USER:-"admin"}
    TRAEFIK_PASSWORD=$(openssl rand -hex 8)
    
    # Generate password hash
    TRAEFIK_PASSWORD_HASH=$(htpasswd -nb "$TRAEFIK_USER" "$TRAEFIK_PASSWORD" | sed 's/\$/\$\$/g')
    
    # Create Traefik network
    ensure_traefik_network
    
    # Install Traefik
    install_traefik
    
    # Save Traefik credentials to .env file
    ENV_FILE="$APP_ROOT/.env"
    if grep -q "TRAEFIK_USER" "$ENV_FILE"; then
        sed -i "s/TRAEFIK_USER=.*/TRAEFIK_USER=$TRAEFIK_USER/" "$ENV_FILE"
        sed -i "s/TRAEFIK_PASSWORD=.*/TRAEFIK_PASSWORD=$TRAEFIK_PASSWORD/" "$ENV_FILE"
    else
        echo "# Traefik credentials" >> "$ENV_FILE"
        echo "TRAEFIK_USER=$TRAEFIK_USER" >> "$ENV_FILE"
        echo "TRAEFIK_PASSWORD=$TRAEFIK_PASSWORD" >> "$ENV_FILE"
    fi
}

# Check if Traefik is running
ensure_traefik_running() {
    echo -e "${BLUE}Checking Traefik status...${NC}"
    if [ ! -d "$TRAEFIK_DIR" ]; then
        echo -e "${YELLOW}Traefik directory does not exist. Setting up Traefik first.${NC}"
        prepare_traefik
    fi
    
    if ! docker ps | grep -q traefik; then
        echo -e "${YELLOW}Traefik is not active. Starting...${NC}"
        # Make sure no services are blocking the ports
        check_port_availability
        cd "$TRAEFIK_DIR" && docker-compose up -d
        echo -e "${GREEN}Traefik started.${NC}"
    else
        echo -e "${GREEN}Traefik is already running.${NC}"
    fi
}

# Install applications
install_app() {
    app_name=$1
    
    # Check for valid applications
    case "$app_name" in
        "traefik")
            prepare_traefik
            ;;
        "odoo")
            install_odoo
            ;;
        "mautic")
            install_mautic
            ;;
        "activepieces")
            install_activepieces
            ;;
        "twenty")
            install_twenty
            ;;
        "windmill")
            install_windmill
            ;;
        *)
            echo -e "${RED}Unknown application: $app_name${NC}"
            echo -e "${YELLOW}Available applications: traefik, odoo, mautic, activepieces, twenty, windmill${NC}"
            exit 1
            ;;
    esac
}

# Odoo Installation
install_odoo() {
    echo -e "${BLUE}Installing Odoo...${NC}"
    
    # Create directory for Odoo
    mkdir -p "$APP_ROOT/odoo"
    cd "$APP_ROOT/odoo"
    
    # Ask for subdomain
    read -p "Enter subdomain for Odoo (default: erp): " subdomain_input
    ODOO_SUBDOMAIN=${subdomain_input:-"erp"}
    ODOO_DOMAIN="${ODOO_SUBDOMAIN}.${DOMAIN_SUFFIX}"
    
    # Generate secure passwords without special characters (safer for environment variables)
    POSTGRES_PASSWORD=$(openssl rand -hex 12)
    ADMIN_PASSWORD=$(openssl rand -hex 12)
    
    # Create docker-compose.yml for Odoo
    cat > docker-compose.yml << EOL
version: '3'

services:
  odoo:
    image: odoo:16
    restart: unless-stopped
    depends_on:
      - db
    environment:
      - HOST=db
      - PORT=5432
      - USER=odoo
      - PASSWORD=${POSTGRES_PASSWORD}
      - ADMIN_PASSWORD=${ADMIN_PASSWORD}
    volumes:
      - odoo-data:/var/lib/odoo
      - ./addons:/mnt/extra-addons
    networks:
      - traefik-net
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=traefik-net"
      - "traefik.http.routers.odoo-rt.rule=Host(\`${ODOO_DOMAIN}\`)"
      - "traefik.http.routers.odoo-rt.entrypoints=websecure"
      - "traefik.http.routers.odoo-rt.tls=true"
      - "traefik.http.routers.odoo-rt.tls.certresolver=letsencrypt"
      - "traefik.http.services.odoo-svc.loadbalancer.server.port=8069"

  db:
    image: postgres:14
    restart: unless-stopped
    environment:
      - POSTGRES_DB=postgres
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_USER=odoo
    volumes:
      - db-data:/var/lib/postgresql/data
    networks:
      - traefik-net

networks:
  traefik-net:
    external: true

volumes:
  odoo-data:
  db-data:
EOL
    
    # Create folder for custom addons
    mkdir -p addons
    
    # Save passwords in a secure file
    cat > .env << EOL
# Odoo Configuration
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
ODOO_DOMAIN=${ODOO_DOMAIN}
EOL
    chmod 600 .env
    
    # Start Odoo
    docker-compose up -d
    
    echo -e "${GREEN}Odoo has been installed.${NC}"
    echo -e "${GREEN}Admin Panel: https://${ODOO_DOMAIN}${NC}"
    echo -e "${YELLOW}Admin Password: ${ADMIN_PASSWORD}${NC}"
    echo -e "${YELLOW}Please save the admin password in a secure location!${NC}"
    
    # Wait briefly and check if containers are running
    sleep 5
    if ! docker ps | grep -q "odoo"; then
        echo -e "${RED}Warning: Odoo container does not appear to be running. Check the logs with 'docker logs odoo_odoo_1'.${NC}"
    else
        echo -e "${GREEN}Odoo container is running!${NC}"
    fi
}

# Mautic Installation
install_mautic() {
    echo -e "${BLUE}Installing Mautic...${NC}"
    
    # Create directory for Mautic
    mkdir -p "$APP_ROOT/mautic"
    cd "$APP_ROOT/mautic"
    
    # Ask for subdomain
    read -p "Enter subdomain for Mautic (default: mautic): " subdomain_input
    MAUTIC_SUBDOMAIN=${subdomain_input:-"mautic"}
    MAUTIC_DOMAIN="${MAUTIC_SUBDOMAIN}.${DOMAIN_SUFFIX}"
    
    # Generate random passwords without special characters
    MYSQL_PASSWORD=$(openssl rand -hex 12)
    MYSQL_ROOT_PASSWORD=$(openssl rand -hex 12)
    
    # Create docker-compose.yml for Mautic
    cat > docker-compose.yml << EOL
version: '3'

services:
  mautic:
    image: mautic/mautic:v4-apache
    container_name: mautic
    restart: unless-stopped
    depends_on:
      - mautic-db
    environment:
      MAUTIC_DB_HOST: mautic-db
      MAUTIC_DB_USER: mautic
      MAUTIC_DB_PASSWORD: ${MYSQL_PASSWORD}
      MAUTIC_DB_NAME: mautic
      MAUTIC_RUN_CRON_JOBS: 'true'
      MAUTIC_TRUSTED_PROXIES: 'traefik'
    volumes:
      - mautic-data:/var/www/html
    networks:
      - traefik-net
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=traefik-net"
      - "traefik.http.routers.mautic-rt.rule=Host(\`${MAUTIC_DOMAIN}\`)"
      - "traefik.http.routers.mautic-rt.entrypoints=websecure"
      - "traefik.http.routers.mautic-rt.tls=true"
      - "traefik.http.routers.mautic-rt.tls.certresolver=letsencrypt"
      - "traefik.http.services.mautic-svc.loadbalancer.server.port=80"

  mautic-db:
    image: mysql:8.0
    container_name: mautic-db
    restart: unless-stopped
    environment:
      MYSQL_DATABASE: mautic
      MYSQL_USER: mautic
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
    command: --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci --sql-mode=""
    volumes:
      - mautic-db-data:/var/lib/mysql
    networks:
      - traefik-net

networks:
  traefik-net:
    external: true

volumes:
  mautic-data:
  mautic-db-data:
EOL
    
    # Save passwords in a secure file
    cat > .env << EOL
# Mautic Configuration
MYSQL_PASSWORD=${MYSQL_PASSWORD}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
MAUTIC_DOMAIN=${MAUTIC_DOMAIN}
EOL
    chmod 600 .env
    
    # Start Mautic
    docker-compose up -d
    
    echo -e "${GREEN}Mautic has been installed.${NC}"
    echo -e "${GREEN}Admin Panel: https://${MAUTIC_DOMAIN}${NC}"
    echo -e "${YELLOW}You will need to create an admin account on first login.${NC}"
    echo -e "${YELLOW}Note: Initial setup may take a few minutes. If you see a database error, wait a moment and refresh.${NC}"
}

# ActivePieces Installation
install_activepieces() {
    echo -e "${BLUE}Installing ActivePieces...${NC}"
    
    # Create directory for ActivePieces
    mkdir -p "$APP_ROOT/activepieces"
    cd "$APP_ROOT/activepieces"
    
    # Ask for subdomain
    read -p "Enter subdomain for ActivePieces (default: automation): " subdomain_input
    AP_SUBDOMAIN=${subdomain_input:-"automation"}
    AP_DOMAIN="${AP_SUBDOMAIN}.${DOMAIN_SUFFIX}"
    
    # Generate random keys without special characters
    ENCRYPTION_KEY=$(openssl rand -hex 16)
    JWT_SECRET=$(openssl rand -hex 16)
    
    # Create docker-compose.yml for ActivePieces
    cat > docker-compose.yml << EOL
version: '3'

services:
  activepieces:
    image: activepieces/activepieces:latest
    container_name: activepieces
    restart: unless-stopped
    depends_on:
      - postgres
      - redis
    environment:
      - AP_ENCRYPTION_KEY=${ENCRYPTION_KEY}
      - AP_JWT_SECRET=${JWT_SECRET}
      - AP_FRONTEND_URL=https://${AP_DOMAIN}
      - AP_POSTGRES_HOST=postgres
      - AP_POSTGRES_PORT=5432
      - AP_POSTGRES_DATABASE=activepieces
      - AP_POSTGRES_USERNAME=activepieces
      - AP_POSTGRES_PASSWORD=activepieces
      - AP_REDIS_HOST=redis
      - AP_REDIS_PORT=6379
      - AP_SIGN_UP_ENABLED=true
    networks:
      - traefik-net
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=traefik-net"
      - "traefik.http.routers.activepieces-rt.rule=Host(\`${AP_DOMAIN}\`)"
      - "traefik.http.routers.activepieces-rt.entrypoints=websecure"
      - "traefik.http.routers.activepieces-rt.tls=true"
      - "traefik.http.routers.activepieces-rt.tls.certresolver=letsencrypt"
      - "traefik.http.services.activepieces-svc.loadbalancer.server.port=80"

  postgres:
    image: postgres:14
    container_name: ap-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_DB=activepieces
      - POSTGRES_PASSWORD=activepieces
      - POSTGRES_USER=activepieces
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - traefik-net

  redis:
    image: redis:alpine
    container_name: ap-redis
    restart: unless-stopped
    networks:
      - traefik-net

networks:
  traefik-net:
    external: true

volumes:
  postgres_data:
EOL
    
    # Save configuration in .env file
    cat > .env << EOL
# ActivePieces Configuration
ENCRYPTION_KEY=${ENCRYPTION_KEY}
JWT_SECRET=${JWT_SECRET}
AP_DOMAIN=${AP_DOMAIN}
EOL
    chmod 600 .env
    
    # Start ActivePieces
    docker-compose up -d
    
    echo -e "${GREEN}ActivePieces has been installed.${NC}"
    echo -e "${GREEN}Admin Panel: https://${AP_DOMAIN}${NC}"
    echo -e "${YELLOW}You will need to create an admin account on first login.${NC}"
}

# Twenty Installation
install_twenty() {
    echo -e "${BLUE}Installing Twenty CRM...${NC}"
    
    # Create directory for Twenty
    mkdir -p "$APP_ROOT/twenty"
    cd "$APP_ROOT/twenty"
    
    # Ask for subdomain
    read -p "Enter subdomain for Twenty CRM (default: crm): " subdomain_input
    TWENTY_SUBDOMAIN=${subdomain_input:-"crm"}
    TWENTY_DOMAIN="${TWENTY_SUBDOMAIN}.${DOMAIN_SUFFIX}"
    
    # Generate random App Secret without special characters
    APP_SECRET=$(openssl rand -hex 16)
    
    # Create docker-compose.yml for Twenty
    cat > docker-compose.yml << EOL
version: '3'

services:
  change-vol-ownership:
    image: ubuntu
    user: root
    volumes:
      - server-local-data:/tmp/server-local-data
      - docker-data:/tmp/docker-data
    command: >
      bash -c "
      chown -R 1000:1000 /tmp/server-local-data
      && chown -R 1000:1000 /tmp/docker-data"

  server:
    image: twentycrm/twenty:latest
    container_name: twenty-server
    volumes:
      - server-local-data:/app/packages/twenty-server/.local-storage
      - docker-data:/app/docker-data
    environment:
      NODE_PORT: 3000
      PG_DATABASE_URL: postgres://postgres:postgres@db:5432/default
      SERVER_URL: https://${TWENTY_DOMAIN}
      REDIS_URL: redis://redis:6379
      STORAGE_TYPE: local
      APP_SECRET: ${APP_SECRET}
    depends_on:
      change-vol-ownership:
        condition: service_completed_successfully
      db:
        condition: service_healthy
    healthcheck:
      test: curl --fail http://localhost:3000/healthz
      interval: 5s
      timeout: 5s
      retries: 10
    restart: always
    networks:
      - default
      - traefik-net
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=traefik-net"
      - "traefik.http.routers.twenty-rt.rule=Host(\`${TWENTY_DOMAIN}\`)"
      - "traefik.http.routers.twenty-rt.entrypoints=websecure"
      - "traefik.http.routers.twenty-rt.tls=true"
      - "traefik.http.routers.twenty-rt.tls.certresolver=letsencrypt"
      - "traefik.http.services.twenty-svc.loadbalancer.server.port=3000"

  worker:
    image: twentycrm/twenty:latest
    container_name: twenty-worker
    command: ['yarn', 'worker:prod']
    environment:
      PG_DATABASE_URL: postgres://postgres:postgres@db:5432/default
      SERVER_URL: https://${TWENTY_DOMAIN}
      REDIS_URL: redis://redis:6379
      DISABLE_DB_MIGRATIONS: 'true'
      STORAGE_TYPE: local
      APP_SECRET: ${APP_SECRET}
    depends_on:
      db:
        condition: service_healthy
      server:
        condition: service_healthy
    restart: always
    networks:
      - default

  db:
    image: postgres:16
    container_name: twenty-db
    volumes:
      - db-data:/var/lib/postgresql/data
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
    healthcheck:
      test: pg_isready -U postgres -h localhost -d postgres
      interval: 5s
      timeout: 5s
      retries: 10
    restart: always
    networks:
      - default

  redis:
    image: redis
    container_name: twenty-redis
    restart: always
    networks:
      - default

volumes:
  docker-data:
  db-data:
  server-local-data:

networks:
  default:
  traefik-net:
    external: true
EOL
    
    # Create cron job script
    cat > start-cron-jobs.sh << EOL
#!/bin/bash
docker exec twenty-server yarn workspace twenty-server cron:run
EOL
    chmod +x start-cron-jobs.sh
    
    # Save configuration in .env file
    cat > .env << EOL
# Twenty CRM Configuration
APP_SECRET=${APP_SECRET}
PG_DATABASE_PASSWORD=postgres
TWENTY_DOMAIN=${TWENTY_DOMAIN}
STORAGE_TYPE=local
EOL
    chmod 600 .env
    
    # Start Twenty
    docker-compose up -d
    
    echo -e "${GREEN}Twenty CRM has been installed.${NC}"
    echo -e "${GREEN}Admin Panel: https://${TWENTY_DOMAIN}${NC}"
    echo -e "${YELLOW}You will need to create an admin account on first login.${NC}"
    echo -e "${YELLOW}Note: Initial setup may take a few minutes to complete.${NC}"
}

# Windmill Installation
install_windmill() {
    echo -e "${BLUE}Installing Windmill...${NC}"
    
    # Create directory for Windmill
    mkdir -p "$APP_ROOT/windmill"
    cd "$APP_ROOT/windmill"
    
    # Ask for subdomain
    read -p "Enter subdomain for Windmill (default: windmill): " subdomain_input
    WINDMILL_SUBDOMAIN=${subdomain_input:-"windmill"}
    WINDMILL_DOMAIN="${WINDMILL_SUBDOMAIN}.${DOMAIN_SUFFIX}"
    
    # Create docker-compose.yml for Windmill
    cat > docker-compose.yml << EOL
version: '3'

services:
  windmill:
    image: ghcr.io/windmill-labs/windmill:latest
    container_name: windmill
    restart: unless-stopped
    environment:
      - DATABASE_URL=postgresql://postgres:postgres@postgres:5432/windmill?sslmode=disable
      - BASE_INTERNAL_URL=http://windmill:8000
      - BASE_URL=https://${WINDMILL_DOMAIN}
      - NUM_WORKERS=1
    depends_on:
      - postgres
    networks:
      - traefik-net
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=traefik-net"
      - "traefik.http.routers.windmill-rt.rule=Host(\`${WINDMILL_DOMAIN}\`)"
      - "traefik.http.routers.windmill-rt.entrypoints=websecure"
      - "traefik.http.routers.windmill-rt.tls=true"
      - "traefik.http.routers.windmill-rt.tls.certresolver=letsencrypt"
      - "traefik.http.services.windmill-svc.loadbalancer.server.port=8000"

  postgres:
    image: postgres:14
    container_name: windmill-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_PASSWORD=postgres
      - POSTGRES_USER=postgres
      - POSTGRES_DB=windmill
    volumes:
      - windmill-db:/var/lib/postgresql/data
    networks:
      - traefik-net

networks:
  traefik-net:
    external: true

volumes:
  windmill-db:
EOL
    
    # Save configuration in .env file
    cat > .env << EOL
# Windmill Configuration
WINDMILL_DOMAIN=${WINDMILL_DOMAIN}
EOL
    chmod 600 .env
    
    # Start
