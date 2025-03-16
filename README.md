# App Manager

A comprehensive self-hosted application manager for Docker containers with Traefik integration. Easily deploy, manage, and secure various open-source applications with automatic HTTPS.

## Features

- **One-Click Deployment**: Deploy popular open-source applications with a single command
- **Traefik Integration**: Automatic HTTPS with Let's Encrypt
- **Interactive Setup**: Configure domains through simple prompts
- **Application Management**: Start, stop, restart, and view logs with simple commands
- **Backup & Restore**: Built-in functionality to backup and restore application data
- **Secure by Default**: Proper password generation and secure storage
- **Customizable**: Easily modify domains, ports, and other settings

## Supported Applications

| Application | Description | URL |
|-------------|-------------|-----|
| Traefik | Modern reverse proxy and load balancer | [traefik.io](https://traefik.io/) |
| Odoo | Open source ERP and business apps | [odoo.com](https://www.odoo.com/) |
| Mautic | Open source marketing automation | [mautic.org](https://www.mautic.org/) |
| ActivePieces | Automation and workflow platform | [activepieces.com](https://www.activepieces.com/) |
| Twenty | Modern open source CRM | [twenty.com](https://www.twenty.com/) |
| Windmill | Low-code backend platform | [windmill.dev](https://www.windmill.dev/) |

## Requirements

- Linux server (Debian/Ubuntu recommended)
- Docker and Docker Compose
- Open ports 80 and 443
- Domain with DNS pointing to your server
- Root or sudo access

## Quick Start

1. Clone this repository:
   ```bash
   git clone https://github.com/gbechtold/App-Manager.git
   cd App-Manager
   ```

2. Make the script executable:
   ```bash
   chmod +x app-manager.sh
   ```

3. Run the setup to configure global settings:
   ```bash
   ./app-manager.sh setup
   ```

4. Install Traefik (required as the base for other applications):
   ```bash
   ./app-manager.sh install traefik
   ```

5. Install any supported application:
   ```bash
   ./app-manager.sh install mautic
   ```

## Command Reference

### Configuration

```bash
./app-manager.sh setup
```
Creates or updates the global configuration file with your domain and other settings.

### Installation

```bash
./app-manager.sh install [app-name]
```
Installs and configures the specified application.

### Management

```bash
./app-manager.sh list          # List all installed applications
./app-manager.sh start [app]   # Start an application
./app-manager.sh stop [app]    # Stop an application
./app-manager.sh restart [app] # Restart an application
./app-manager.sh logs [app]    # View application logs
```

### Backup and Restore

```bash
./app-manager.sh backup [app]          # Backup an application
./app-manager.sh backups               # List available backups
./app-manager.sh restore [backup-file] # Restore from a backup
```

## DNS Configuration

For each application, create an A record in your DNS settings pointing to your server's IP address:

```
traefik.example.com    → Your server IP
mautic.example.com     → Your server IP
erp.example.com        → Your server IP
crm.example.com        → Your server IP
automation.example.com → Your server IP
windmill.example.com   → Your server IP
```

## Directory Structure

```
/opt/apps/              # Default application root
├── .env                # Global configuration
├── logs/               # Log files
├── backups/            # Application backups
├── traefik/            # Traefik configuration and data
├── mautic/             # Mautic configuration and data
├── odoo/               # Odoo configuration and data
└── ...                 # Other applications
```

## Advanced Configuration

### Custom Installation Path

To change the default installation directory:

```bash
export APP_ROOT="/custom/path"
./app-manager.sh setup
```

### Custom Ports

During setup, you can specify custom HTTP and HTTPS ports if the defaults (80/443) are already in use.

## Troubleshooting

### SSL Certificate Issues

If you encounter SSL certificate problems:
- Verify your DNS is correctly pointing to your server
- Check that ports 80 and 443 are open in your firewall
- Review Traefik logs: `./app-manager.sh logs traefik`

### Application Not Starting

If an application fails to start:
1. Check the logs: `./app-manager.sh logs [app-name]`
2. Verify that Traefik is running: `./app-manager.sh list`
3. Check the application's .env file in its directory

## Security Considerations

- All generated passwords are stored in `.env` files with restricted permissions (600)
- The application uses Docker networks for isolation
- Traefik handles HTTPS encryption automatically
- Consider setting up a firewall to only allow necessary ports

## Contributing

Contributions are welcome! Please feel free to submit pull requests or create issues for bugs and feature requests.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- All the amazing open-source projects that this tool helps to deploy
- The Docker and Traefik communities for their excellent documentation
