#!/bin/bash

# Uninstall script for Milo Mac and roc-vad
# Version 1.0

set -e  # Stop on error

echo "=============================================="
echo "Uninstalling Milo Mac and roc-vad"
echo "=============================================="
echo ""

# Check admin permissions
if [ "$EUID" -eq 0 ]; then
    echo "Error: do not run this script with sudo directly"
    echo "The script will ask for admin permissions when needed"
    exit 1
fi

# Stop Milo Mac if it is running
echo "1. Stopping Milo Mac..."
# "Milo" is the current process name; "Milo Mac" is the one used before 0.1.0
if killall "Milo" 2>/dev/null || killall "Milo Mac" 2>/dev/null; then
    echo "   Milo Mac stopped"
else
    echo "   Milo Mac was not running"
fi

# Check whether roc-vad is installed
if command -v roc-vad &> /dev/null || [ -f "/usr/local/bin/roc-vad" ]; then
    echo ""
    echo "2. Uninstalling roc-vad..."
    echo "   (Administrator password required)"
    
    if [ -f "/usr/local/bin/roc-vad" ]; then
        sudo /usr/local/bin/roc-vad uninstall
        echo "   roc-vad uninstalled"
    else
        echo "   roc-vad not found, moving on to the next step"
    fi
else
    echo ""
    echo "2. roc-vad is not installed, moving on to the next step"
fi

# Remove the Milo Mac application
echo ""
echo "3. Removing the Milo Mac application..."

removed_app=false
# "Milō.app" is the current bundle name; the others were used before 0.1.0
for app in "/Applications/Milō.app" "/Applications/Milo Mac.app" "/Applications/Milo.app"; do
    if [ -d "$app" ]; then
        rm -rf "$app"
        echo "   Removed: $app"
        removed_app=true
    fi
done

if [ "$removed_app" = false ]; then
    echo "   Application not found in /Applications/"
fi

# Clean up the configuration files
echo ""
echo "4. Cleaning up the configuration files..."

# Find and remove the Milo Mac preferences
find ~/Library/Preferences/ -name "*Milo*Mac*" -type f 2>/dev/null | while read file; do
    rm -f "$file"
    echo "   Removed: $(basename "$file")"
done

# Find and remove the caches
find ~/Library/Caches/ -name "*Milo*Mac*" -type d 2>/dev/null | while read dir; do
    rm -rf "$dir"
    echo "   Removed: $(basename "$dir")"
done

# Remove the Application Support folder
if [ -d ~/Library/Application\ Support/Milo\ Mac/ ]; then
    rm -rf ~/Library/Application\ Support/Milo\ Mac/
    echo "   Support folder removed"
fi

# Clean up the LaunchAgents (automatic startup).
# Launch at login now goes through SMAppService, which the removal of the bundle
# takes care of; this only clears agents left behind by older versions.
find ~/Library/LaunchAgents/ -name "*Milo*Mac*" -type f 2>/dev/null | while read file; do
    rm -f "$file"
    echo "   Startup agent removed: $(basename "$file")"
done

echo ""
echo "=============================================="
echo "Uninstallation completed successfully!"
echo ""
echo "IMPORTANT: restart your Mac to finalize"
echo "the complete removal of the audio services."
echo "=============================================="
