#!/bin/bash

# ========================================
# VIDEO CONVERTER - UNINSTALLER
# ========================================

echo "🗑️  Uninstalling Video & Audio Converter..."

# Remove installation directory
INSTALL_DIR="$HOME/.local/share/video-converter"
if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
    echo "✓ Removed installation directory"
fi

# Remove symlink
if [[ -L "$HOME/.local/bin/video-converter" ]]; then
    rm "$HOME/.local/bin/video-converter"
    echo "✓ Removed command symlink"
fi

# Remove .desktop file
DESKTOP_FILE="$HOME/.local/share/applications/video-converter.desktop"
if [[ -f "$DESKTOP_FILE" ]]; then
    rm "$DESKTOP_FILE"
    echo "✓ Removed application launcher"
fi

# Update desktop database
if command -v update-desktop-database &> /dev/null; then
    update-desktop-database "$HOME/.local/share/applications"
fi

echo ""
echo "✅ Uninstallation complete!"
echo ""
