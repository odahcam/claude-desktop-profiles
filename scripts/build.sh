#!/bin/sh
# Builds the release: build/Claude Profiles.app (universal, ad-hoc signed) and
# build/Claude-Profiles.zip, the asset attached to the GitHub release.
set -eu
cd "$(dirname "$0")/.."

APP="build/Claude Profiles.app"
CDP_ARCHS="arm64 x86_64" bin/cdp build "$APP"
rm -f build/Claude-Profiles.zip
ditto -c -k --keepParent "$APP" build/Claude-Profiles.zip
echo "Built $APP and build/Claude-Profiles.zip ($(bin/cdp version))"
