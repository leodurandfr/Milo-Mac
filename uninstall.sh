#!/bin/bash

# Uninstall script for Milo Mac and roc-vad
# Version 1.1

set -e  # Stop on error

# Every bundle identifier the app has shipped under. "leodurand.Sonoak-Menu" predates the
# rename to Milo; its leftovers are still on disk for anyone who ran that version, and the
# old glob-based cleanup never matched them.
BUNDLE_IDS=("leodurand.Milo-Mac" "leodurand.Sonoak-Menu")

# Every process name the app has run under, most recent first.
PROCESS_NAMES=("Milo" "Milo Mac" "Sonoak Menu")

# Every bundle name the app has been installed under.
APP_BUNDLES=(
    "/Applications/Milō.app"
    "/Applications/Milo Mac.app"
    "/Applications/Milo.app"
    "/Applications/Sonoak Menu.app"
)

# Every Application Support folder the app has written to.
SUPPORT_FOLDERS=(
    "$HOME/Library/Application Support/Milo Mac"
    "$HOME/Library/Application Support/Sonoak Menu"
)

# Paths macOS refused to let us delete, reported at the end.
FAILED_PATHS=()

# Removes one path, best effort. Returns 0 only if something was actually deleted.
#
# Best effort is not laziness: ~/Library/Containers is guarded by containermanagerd, and
# `rm -rf` on it returns "Operation not permitted" unless the calling program holds Full
# Disk Access — which a script run from Terminal does not. Under `set -e` that single
# refusal aborted the whole uninstall: everything after it was skipped, including the
# closing advice, and the user was left with a half-cleaned system and a stack trace.
remove_path() {
    local path="$1"
    local label="${path#"$HOME/Library/"}"

    [ -e "$path" ] || return 1

    if rm -rf "$path" 2>/dev/null; then
        echo "   Removed: $label"
        return 0
    fi

    FAILED_PATHS+=("$path")
    echo "   Could not remove: $label"
    return 1
}

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
# Every name is tried, none of them short-circuits the rest: an upgrade can leave an old
# build running beside the current one, and killing only the first would let the survivor
# keep going while step 3 deletes the bundle out from under it.
stopped_any=false
for process in "${PROCESS_NAMES[@]}"; do
    if killall "$process" 2>/dev/null; then
        echo "   Stopped: $process"
        stopped_any=true
    fi
done

if [ "$stopped_any" = false ]; then
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
for app in "${APP_BUNDLES[@]}"; do
    if remove_path "$app"; then
        removed_app=true
    fi
done

if [ "$removed_app" = false ]; then
    echo "   Application not found in /Applications/"
fi

# Clean up the configuration files
echo ""
echo "4. Cleaning up the configuration files..."

# Exact paths, derived from the bundle identifiers — never a glob.
#
# The previous version ran `find ~/Library/Caches -name "*Milo*Mac*" -type d` and `rm -rf`
# on every hit, with no depth limit. On a machine that holds a checkout of this project
# that also matches caches keyed by the PROJECT PATH — "…-Users-you-Developer-Milo-Mac" —
# which belong to other tools entirely. A pattern loose enough to find the app's own cache
# is loose enough to delete someone else's.
for id in "${BUNDLE_IDS[@]}"; do
    # `defaults delete` before the `rm`: cfprefsd holds the domain in memory and can write
    # the file back out after this script has finished, leaving an uninstall that only
    # looks complete.
    #
    # The PATH form, not the bare domain name. When a container exists — the sandboxed
    # builds left some behind — `defaults <domain>` resolves to the copy inside that
    # container and never touches ~/Library/Preferences at all.
    defaults delete "$HOME/Library/Preferences/$id" 2>/dev/null || true

    for path in \
        "$HOME/Library/Preferences/$id.plist" \
        "$HOME/Library/Caches/$id" \
        "$HOME/Library/HTTPStorages/$id" \
        "$HOME/Library/Containers/$id" \
        "$HOME/Library/Saved Application State/$id.savedState"
    do
        remove_path "$path" || true
    done

    # Startup agents left behind by versions that predate SMAppService. Anchored on the
    # bundle identifier and not recursive, for the reason given above. A glob rather than
    # `find | while read`, because that pipeline runs in a subshell and any path it failed
    # to delete would never reach FAILED_PATHS.
    for file in "$HOME/Library/LaunchAgents/$id"*; do
        remove_path "$file" || true
    done
done

for folder in "${SUPPORT_FOLDERS[@]}"; do
    remove_path "$folder" || true
done

echo ""
echo "=============================================="
if [ ${#FAILED_PATHS[@]} -gt 0 ]; then
    echo "Uninstallation finished, with leftovers."
else
    echo "Uninstallation completed successfully!"
fi
echo ""
echo "IMPORTANT: restart your Mac to finalize"
echo "the complete removal of the audio services."
echo ""
# Launch at login goes through SMAppService, whose registration lives in a system database
# and not in a file this script could remove. Only the app itself can unregister it, by
# calling SMAppService.mainApp.unregister() — which it can no longer do, having just been
# deleted. macOS prunes the orphaned entry eventually; until then it is visible, so say so
# rather than claim a cleanup that never happened.
echo "If Milo still appears in System Settings >"
echo "General > Login Items, remove it there: that"
echo "entry is held by macOS, not by a file."

if [ ${#FAILED_PATHS[@]} -gt 0 ]; then
    echo ""
    echo "macOS would not let this script delete:"
    for path in "${FAILED_PATHS[@]}"; do
        echo "  $path"
    done
    echo ""
    echo "Remove them in the Finder (Go > Go to Folder),"
    echo "which is allowed to, or grant your terminal"
    echo "Full Disk Access and run this script again."
fi

echo "=============================================="
