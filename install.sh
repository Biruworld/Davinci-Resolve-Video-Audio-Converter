#!/bin/bash

# ========================================
# VIDEO CONVERTER - INSTALLER
# ========================================

echo "🎬 Installing Video & Audio Converter..."

# Check if running as root
if [[ $EUID -eq 0 ]]; then
   echo "❌ Don't run as root! Run as normal user."
   exit 1
fi

# Check dependencies
MISSING_DEPS=()
for cmd in yad ffmpeg ffprobe; do
    if ! command -v $cmd &> /dev/null; then
        MISSING_DEPS+=($cmd)
    fi
done

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
    echo "📦 Installing dependencies: ${MISSING_DEPS[*]}"
    sudo dnf install -y yad ffmpeg
fi

# Create installation directory
INSTALL_DIR="$HOME/.local/share/video-converter"
mkdir -p "$INSTALL_DIR"

# Copy main script
echo "📋 Copying files..."
cp video-converter.sh "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/video-converter.sh"

# Copy icon (if exists)
if [[ -f icon.png ]]; then
    cp icon.png "$INSTALL_DIR/"
fi

# Create symlink for command-line usage
mkdir -p "$HOME/.local/bin"
ln -sf "$INSTALL_DIR/video-converter.sh" "$HOME/.local/bin/video-converter"

# Install .desktop file (GUI launcher)
DESKTOP_DIR="$HOME/.local/share/applications"
mkdir -p "$DESKTOP_DIR"

cat > "$DESKTOP_DIR/video-converter.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Video & Audio Converter
Comment=Professional media converter with DNxHR proxy support
Exec=$INSTALL_DIR/video-converter.sh
Icon=$INSTALL_DIR/icon.png
Terminal=false
Categories=AudioVideo;Video;AudioVideoEditing;
Keywords=video;audio;converter;ffmpeg;proxy;dnxhr;
StartupNotify=true
EOF

chmod +x "$DESKTOP_DIR/video-converter.desktop"

# Update desktop database
if command -v update-desktop-database &> /dev/null; then
    update-desktop-database "$DESKTOP_DIR"
fi

echo ""
echo "✅ Installation complete!"
echo ""
echo "🎯 Launch options:"
echo "   1. GUI: Search 'Video Converter' in application menu"
echo "   2. Terminal: video-converter"
echo "   3. Direct: $INSTALL_DIR/video-converter.sh"
echo ""
echo "📝 Note: Restart your session if command not found"
echo ""
