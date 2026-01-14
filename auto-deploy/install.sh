#!/bin/bash

# Auto-Deploy Installation Script
# This script sets up the auto-deploy system on your server

set -e

echo "🚀 Auto-Deploy v2.0 Installation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    echo "⚠️  Please do not run as root. Run as your deploy user."
    exit 1
fi

# Set installation directory
INSTALL_DIR="/opt/auto-deploy"

echo "📁 Installation directory: $INSTALL_DIR"
echo ""

# Create directories
echo "📂 Creating directories..."
sudo mkdir -p "$INSTALL_DIR"
sudo mkdir -p "$INSTALL_DIR/.ssh"
sudo mkdir -p "$INSTALL_DIR/logs"

# Set ownership
echo "👤 Setting ownership..."
sudo chown -R "$(whoami):$(whoami)" "$INSTALL_DIR"

# Copy files
echo "📦 Copying files..."
cp -r lib/ "$INSTALL_DIR/"
cp deploy.sh "$INSTALL_DIR/"
cp README.md "$INSTALL_DIR/" 2>/dev/null || true
cp LOKI_SETUP.md "$INSTALL_DIR/" 2>/dev/null || true
cp CHANGELOG.md "$INSTALL_DIR/" 2>/dev/null || true

# Set execute permissions
echo "🔧 Setting permissions..."
chmod +x "$INSTALL_DIR/deploy.sh"
chmod +x "$INSTALL_DIR/lib/"*.sh
chmod 755 "$INSTALL_DIR/logs"

# Check dependencies
echo ""
echo "🔍 Checking dependencies..."
echo ""

MISSING_DEPS=()

if ! command -v git &> /dev/null; then
    echo "❌ git not found"
    MISSING_DEPS+=("git")
else
    echo "✅ git"
fi

if ! command -v docker &> /dev/null; then
    echo "❌ docker not found"
    MISSING_DEPS+=("docker")
else
    echo "✅ docker"
fi

if ! command -v docker-compose &> /dev/null; then
    echo "❌ docker-compose not found"
    MISSING_DEPS+=("docker-compose")
else
    echo "✅ docker-compose"
fi

if ! command -v jq &> /dev/null; then
    echo "❌ jq not found"
    MISSING_DEPS+=("jq")
else
    echo "✅ jq"
fi

if ! command -v curl &> /dev/null; then
    echo "❌ curl not found"
    MISSING_DEPS+=("curl")
else
    echo "✅ curl"
fi

echo ""

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo "⚠️  Missing dependencies: ${MISSING_DEPS[*]}"
    echo ""
    echo "Install them with:"
    echo "  sudo apt update"
    echo "  sudo apt install -y ${MISSING_DEPS[*]}"
    echo ""
fi

# SSH Key setup
echo "🔑 SSH Key Setup"
echo ""

if [ ! -f "$INSTALL_DIR/.ssh/id_ed25519" ]; then
    echo "SSH key not found at $INSTALL_DIR/.ssh/id_ed25519"
    echo ""
    read -p "Do you want to generate a new SSH key? (y/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        ssh-keygen -t ed25519 -f "$INSTALL_DIR/.ssh/id_ed25519" -N ""
        echo ""
        echo "✅ SSH key generated!"
        echo ""
        echo "📋 Add this public key to your GitHub account:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        cat "$INSTALL_DIR/.ssh/id_ed25519.pub"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "Add at: https://github.com/settings/keys"
    fi
else
    echo "✅ SSH key already exists"
fi

# Create alias
echo ""
echo "🔗 Creating alias..."
echo ""

BASHRC="$HOME/.bashrc"
ALIAS_LINE="alias deploy='cd $INSTALL_DIR && ./deploy.sh'"

if grep -q "alias deploy=" "$BASHRC" 2>/dev/null; then
    echo "ℹ️  Alias 'deploy' already exists in ~/.bashrc"
else
    echo "$ALIAS_LINE" >> "$BASHRC"
    echo "✅ Alias 'deploy' added to ~/.bashrc"
    echo ""
    echo "Run: source ~/.bashrc"
fi

# Installation complete
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Installation completed successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📍 Installation directory: $INSTALL_DIR"
echo "📝 Logs directory: $INSTALL_DIR/logs"
echo ""
echo "🚀 Usage:"
echo "   cd $INSTALL_DIR"
echo "   ./deploy.sh <service-name>"
echo ""
echo "   Or use the alias:"
echo "   deploy <service-name>"
echo ""
echo "📖 Documentation:"
echo "   cat $INSTALL_DIR/README.md"
echo "   cat $INSTALL_DIR/LOKI_SETUP.md"
echo ""
echo "🧪 Test the system:"
echo "   cd $INSTALL_DIR"
echo "   ./test-logging.sh"
echo ""

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo "⚠️  Don't forget to install missing dependencies!"
    echo "   sudo apt install -y ${MISSING_DEPS[*]}"
    echo ""
fi

echo "Happy deploying! 🎉"
echo ""
