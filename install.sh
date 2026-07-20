#!/bin/sh
# claude-desktop-profiles installer.
#
# Builds the "Claude Profiles" app into ~/Applications (SwiftUI when the
# Swift toolchain is available, AppleScript dialog otherwise) and links the
# cdp CLI onto your PATH when possible. Everything is built locally on your
# machine — nothing is downloaded, nothing needs notarization.

set -e
cd "$(dirname "$0")"

CDP="$PWD/bin/cdp"
chmod +x "$CDP"

if command -v swiftc >/dev/null 2>&1; then
    "$CDP" gui
else
    echo "swiftc not found — installing the dialog-based chooser instead."
    echo "For the full GUI: xcode-select --install, then re-run ./install.sh"
    "$CDP" chooser
fi

# Best-effort CLI symlink; the GUI is fully usable without it.
if ln -sf "$CDP" /usr/local/bin/cdp 2>/dev/null; then
    echo "✓ cdp linked into /usr/local/bin"
else
    echo "ℹ Couldn't link into /usr/local/bin (permissions). For the CLI, add to PATH:"
    echo "    export PATH=\"$PWD/bin:\$PATH\""
fi

echo ""
echo "Done. Hit ⌘Space and type: Claude Profiles"
