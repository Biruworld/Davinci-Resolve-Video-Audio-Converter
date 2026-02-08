#!/bin/bash

# ========================================
# DAVINCI CONVERTER INSTALLER
# Auto-detects distro and installs deps
# ========================================

set -e  # Exit immediately on error

SCRIPT_NAME="converter.sh"
INSTALL_NAME="davinci-converter"
INSTALL_PATH="/usr/local/bin/$INSTALL_NAME"

echo "========================================="
echo "  Davinci Converter Installer (Alpha)"
echo "========================================="
echo ""

# Check if running as root
if [[ $EUID -eq 0 ]]; then
   echo "❌ ERROR: Don't run this as root/sudo!"
   echo "   The script will ask for sudo when needed."
   exit 1
fi

# Check if converter.sh exists
if [[ ! -f "$SCRIPT_NAME" ]]; then
    echo "❌ ERROR: $SCRIPT_NAME not found!"
    echo "   Make sure you're in the correct directory."
    exit 1
fi

# ========================================
# DETECT DISTRO
# ========================================

echo "🔍 Detecting Linux distribution..."

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    DISTRO=$ID
else
    echo "❌ ERROR: Cannot detect distribution!"
    exit 1
fi

echo "✅ Detected: $PRETTY_NAME"
echo ""

# ========================================
# INSTALL DEPENDENCIES
# ========================================

install_deps_arch() {
    echo "📦 Installing dependencies for Arch Linux..."
    
    # Check if yay is available
    if command -v yay &> /dev/null; then
        echo "✅ Using yay (AUR helper)"
        yay -S --needed --noconfirm ffmpeg yad || {
            echo "❌ ERROR: Failed to install dependencies with yay!"
            exit 1
        }
    else
        echo "⚠️  yay not found, using pacman"
        sudo pacman -S --needed --noconfirm ffmpeg yad || {
            echo "❌ ERROR: Failed to install dependencies with pacman!"
            exit 1
        }
    fi
}

install_deps_fedora() {
    echo "📦 Installing dependencies for Fedora..."
    
    # Enable RPM Fusion if ffmpeg is not available
    if ! dnf list ffmpeg &> /dev/null; then
        echo "⚠️  FFmpeg not found in repos, enabling RPM Fusion..."
        sudo dnf install -y \
            https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm || {
            echo "❌ ERROR: Failed to enable RPM Fusion!"
            exit 1
        }
    fi
    
    sudo dnf install -y ffmpeg yad || {
        echo "❌ ERROR: Failed to install dependencies!"
        exit 1
    }
}

install_deps_ubuntu() {
    echo "📦 Installing dependencies for Ubuntu/Debian..."
    
    sudo apt update || {
        echo "❌ ERROR: Failed to update package list!"
        exit 1
    }
    
    sudo apt install -y ffmpeg yad || {
        echo "❌ ERROR: Failed to install dependencies!"
        exit 1
    }
}

# Run appropriate installer
case "$DISTRO" in
    arch|manjaro|endeavouros)
        install_deps_arch
        ;;
    fedora)
        install_deps_fedora
        ;;
    ubuntu|debian|pop|linuxmint)
        install_deps_ubuntu
        ;;
    *)
        echo "❌ ERROR: Unsupported distribution: $DISTRO"
        echo "   Supported: Arch, Fedora, Ubuntu/Debian"
        echo ""
        echo "   Please install manually:"
        echo "   - ffmpeg"
        echo "   - yad"
        exit 1
        ;;
esac

echo "✅ Dependencies installed successfully!"
echo ""

# ========================================
# VERIFY INSTALLATION
# ========================================

echo "🔍 Verifying installations..."

for cmd in ffmpeg ffprobe yad; do
    if ! command -v $cmd &> /dev/null; then
        echo "❌ ERROR: $cmd is not installed or not in PATH!"
        exit 1
    else
        echo "  ✅ $cmd"
    fi
done

echo ""

# ========================================
# INSTALL TO /usr/local/bin
# ========================================

echo "📂 Installing to $INSTALL_PATH..."

sudo cp "$SCRIPT_NAME" "$INSTALL_PATH" || {
    echo "❌ ERROR: Failed to copy script to $INSTALL_PATH!"
    exit 1
}

sudo chmod +x "$INSTALL_PATH" || {
    echo "❌ ERROR: Failed to make script executable!"
    exit 1
}

echo "✅ Installed successfully!"
echo ""

# ========================================
# COMPLETION
# ========================================

echo "========================================="
echo "  🎉 Installation Complete!"
echo "========================================="
echo ""
echo "✅ You can now run the converter from anywhere:"
echo ""
echo "   $ davinci-converter"
echo ""
echo "📁 Installed to: $INSTALL_PATH"
echo ""
echo "⚠️  If 'davinci-converter' is not found, try:"
echo "   - Restart your terminal"
echo "   - Or run: source ~/.bashrc"
echo ""
echo "🚀 Ready to convert media for DaVinci Resolve!"
echo ""
echo "---"
echo "========================================="
