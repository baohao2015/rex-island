#!/bin/bash
# Builds Rex Island with swiftc directly: no Xcode project, and no SwiftPM (some Command Line Tools
# installs ship a SwiftPM whose manifest API doesn't link).
#
#   scripts/build.sh test       run the tests
#   scripts/build.sh app        build "Rex Island.app" into .build/
#   scripts/build.sh install    build, copy to ~/Applications and (re)start it
#   scripts/build.sh dmg        build .build/Rex-Island-<version>.dmg to hand to someone
#   scripts/build.sh snapshot   render the UI states to docs/screenshots/ with demo data
#
# MODE=debug for a faster, unoptimized build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build"
APP_NAME="Rex Island"
APP="$BUILD/$APP_NAME.app"
VERSION="$(cat "$ROOT/VERSION")"
MODE="${MODE:-release}"
mkdir -p "$BUILD"

flags=(-target "$(uname -m)-apple-macos14.0" -swift-version 5 -module-name RexIsland)
if [ "$MODE" = release ]; then flags+=(-O); else flags+=(-Onone -g); fi

# Command Line Tools upgrades can leave an old usr/include/swift/module.modulemap next to
# bridging.modulemap. Both define SwiftBridging, so every SwiftUI compile fails with
# "redefinition of module". Hide the stale file with a VFS overlay instead of deleting it.
include_dir="$(cd "$(dirname "$(xcrun -f swiftc)")/../include/swift" 2>/dev/null && pwd || true)"
if [ -n "$include_dir" ] && [ -f "$include_dir/module.modulemap" ] && [ -f "$include_dir/bridging.modulemap" ] \
    && grep -q 'module SwiftBridging' "$include_dir/module.modulemap"; then
    : > "$BUILD/empty.modulemap"
    cat > "$BUILD/vfs-overlay.yaml" <<EOF
{"version":0,"case-sensitive":"false","roots":[{"name":"$include_dir","type":"directory","contents":[
  {"name":"module.modulemap","type":"file","external-contents":"$BUILD/empty.modulemap"}]}]}
EOF
    flags+=(-vfsoverlay "$BUILD/vfs-overlay.yaml")
fi

sources() { find "$@" -name '*.swift' | sort; }

build_tests() {
    # shellcheck disable=SC2046
    swiftc "${flags[@]}" $(sources "$ROOT/Sources/Shared" "$ROOT/Sources/Core" "$ROOT/Tests") -o "$BUILD/tests"
}

build_bridge() {
    # shellcheck disable=SC2046
    swiftc "${flags[@]}" $(sources "$ROOT/Sources/Shared" "$ROOT/Sources/Bridge") -o "$BUILD/rexisland-bridge"
}

build_app_binary() {
    # shellcheck disable=SC2046
    swiftc "${flags[@]}" -parse-as-library $(sources "$ROOT/Sources/Shared" "$ROOT/Sources/Core" "$ROOT/Sources/App") \
        -framework AppKit -framework SwiftUI -framework Carbon -framework ServiceManagement -o "$BUILD/RexIsland"
}

bundle() {
    build_bridge
    build_app_binary
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp "$BUILD/RexIsland" "$APP/Contents/MacOS/RexIsland"
    cp "$BUILD/rexisland-bridge" "$APP/Contents/MacOS/rexisland-bridge"
    sed "s/__VERSION__/$VERSION/g" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
    codesign --force --sign - "$APP/Contents/MacOS/rexisland-bridge" >/dev/null
    codesign --force --sign - "$APP" >/dev/null
    echo "built $APP"
}

case "${1:-app}" in
    test)
        build_tests
        "$BUILD/tests"
        ;;
    app)
        bundle
        ;;
    install)
        bundle
        dest="$HOME/Applications/$APP_NAME.app"
        mkdir -p "$HOME/Applications"
        pkill -x RexIsland 2>/dev/null || true
        rm -rf "$dest"
        cp -R "$APP" "$dest"
        open "$dest"
        echo "installed $dest"
        ;;
    dmg)
        # Ad-hoc signed, not notarized: after downloading, macOS blocks it (or calls it damaged)
        # until the quarantine flag is cleared: xattr -dr com.apple.quarantine "/Applications/Rex Island.app"
        bundle
        staging="$BUILD/dmg"
        rm -rf "$staging"
        mkdir -p "$staging"
        cp -R "$APP" "$staging/"
        ln -s /Applications "$staging/Applications"
        out="$BUILD/Rex-Island-$VERSION.dmg"
        rm -f "$out"
        hdiutil create -volname "$APP_NAME" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$out" >/dev/null
        echo "built $out"
        ;;
    snapshot)
        build_app_binary
        mkdir -p "$ROOT/docs/screenshots"
        "$BUILD/RexIsland" --snapshot "$ROOT/docs/screenshots"
        ;;
    *)
        echo "usage: scripts/build.sh test|app|install|dmg|snapshot" >&2
        exit 64
        ;;
esac
