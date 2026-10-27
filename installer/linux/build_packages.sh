#!/usr/bin/env bash
# Build all Linux release formats on a native x86_64 or aarch64 runner.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
PYTHON="${BANDORIPET_PYTHON:-python3}"
ARCH="${1:-$(uname -m)}"
[[ "$(uname -s)" == Linux && "$(uname -m)" == "$ARCH" ]] || {
    echo 'Run this script on Linux with the requested native architecture.' >&2
    exit 1
}
case "$ARCH" in
    x86_64) BUILD_ARCH=AMD64; DEB_ARCH=amd64; TOOL_SHA=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0 ;;
    aarch64) BUILD_ARCH=ARM64; DEB_ARCH=arm64; TOOL_SHA=f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158 ;;
    *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

VERSION="$("$PYTHON" installer/package_release.py version)"
NAME="BandoriPet-$VERSION-linux-$ARCH"
OUTPUT="$ROOT/BUILD/release"
BUILD="$ROOT/BUILD/BANDORI-PET-REV-RELEASE-LINUX-$BUILD_ARCH"
mkdir -p "$OUTPUT"
"$PYTHON" setup.py build
"$PYTHON" installer/package_release.py validate-build --target linux --arch "$ARCH" --directory "$BUILD"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Portable tarball preserves executable permissions and symlinks.
tar -czf "$OUTPUT/$NAME.tar.gz" -C "$(dirname "$BUILD")" "$(basename "$BUILD")"

# Reuse the same install tree for DEB, RPM and AppImage.
TREE="$STAGE/tree"
mkdir -p "$TREE/opt" "$TREE/usr/bin" "$TREE/usr/share/applications" \
    "$TREE/usr/share/icons/hicolor/256x256/apps" "$TREE/usr/share/licenses/bandoripet"
cp -a "$BUILD" "$TREE/opt/bandoripet"
cp LICENSE "$TREE/usr/share/licenses/bandoripet/LICENSE"
cat > "$TREE/usr/bin/bandoripet" <<'SH'
#!/bin/sh
exec /opt/bandoripet/BandoriPet "$@"
SH
chmod 755 "$TREE/usr/bin/bandoripet"
cat > "$TREE/usr/share/applications/bandoripet.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=BandoriPet
Comment=Bandori Live2D desktop pet
Exec=bandoripet
Icon=bandoripet
Categories=Game;Amusement;
Terminal=false
DESKTOP
desktop-file-validate "$TREE/usr/share/applications/bandoripet.desktop"
"$PYTHON" - "$TREE/usr/share/icons/hicolor/256x256/apps/bandoripet.png" <<'PY'
import sys
from PIL import Image
with Image.open("logo.ico") as image:
    image.convert("RGBA").resize((256, 256)).save(sys.argv[1])
PY

mkdir -p "$TREE/DEBIAN"
cat > "$TREE/DEBIAN/control" <<DEB
Package: bandoripet
Version: $VERSION
Section: games
Priority: optional
Architecture: $DEB_ARCH
Maintainer: BandoriPet <noreply@bandoripet.invalid>
Homepage: https://github.com/HELPMEEADICE/BANDORI-PET-REV
Installed-Size: $(du -sk "$TREE/opt/bandoripet" | cut -f1)
Depends: libc6 (>= 2.39), libegl1, libgl1, libopengl0, libportaudio2, libsndfile1, libxkbcommon0, libxkbcommon-x11-0, libxcb-cursor0, libdbus-1-3, libxcb-icccm4, libxcb-keysyms1, libxcb-shape0, libxcb-xinerama0
Description: Bandori Live2D desktop pet
 Standalone BandoriPet application. Live2D models are downloaded separately.
DEB
chmod 755 "$TREE/DEBIAN"
chmod 644 "$TREE/DEBIAN/control"
dpkg-deb --root-owner-group --build "$TREE" "$OUTPUT/$NAME.deb"
rm -r "$TREE/DEBIAN"

RPM_TOP="$STAGE/rpmbuild"
mkdir -p "$RPM_TOP"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
cat > "$RPM_TOP/SPECS/bandoripet.spec" <<RPM
%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none
Name: bandoripet
Version: $VERSION
Release: 1
Summary: Bandori Live2D desktop pet
License: GPL-3.0-only
URL: https://github.com/HELPMEEADICE/BANDORI-PET-REV
BuildArch: $ARCH
AutoReqProv: no
Requires: glibc >= 2.39, libglvnd-egl, libglvnd-glx, libglvnd-opengl, portaudio, libsndfile, libxkbcommon, libxkbcommon-x11, xcb-util-cursor, dbus-libs, xcb-util-wm, xcb-util-keysyms, libxcb

%description
Standalone BandoriPet application. Live2D models are downloaded separately.

%prep
%build
%install
mkdir -p "%{buildroot}"
cp -a "$TREE/." "%{buildroot}/"

%files
/opt/bandoripet
/usr/bin/bandoripet
/usr/share/applications/bandoripet.desktop
/usr/share/icons/hicolor/256x256/apps/bandoripet.png
%license /usr/share/licenses/bandoripet/LICENSE
RPM
rpmbuild -bb --target "$ARCH" --define "_topdir $RPM_TOP" "$RPM_TOP/SPECS/bandoripet.spec"
cp "$RPM_TOP/RPMS/$ARCH/bandoripet-$VERSION-1.$ARCH.rpm" "$OUTPUT/$NAME.rpm"

APPDIR="$STAGE/BandoriPet.AppDir"
mkdir -p "$APPDIR"
cp -a "$TREE/opt" "$APPDIR/"
cp "$TREE/usr/share/applications/bandoripet.desktop" "$APPDIR/"
cp "$TREE/usr/share/icons/hicolor/256x256/apps/bandoripet.png" "$APPDIR/"
ln -s bandoripet.png "$APPDIR/.DirIcon"
cat > "$APPDIR/AppRun" <<'SH'
#!/bin/sh
APPDIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "$APPDIR/opt/bandoripet/BandoriPet" "$@"
SH
chmod 755 "$APPDIR/AppRun"

TOOL="$STAGE/appimagetool.AppImage"
curl --fail --silent --show-error --location --retry 3 \
    "https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-$ARCH.AppImage" -o "$TOOL"
echo "$TOOL_SHA  $TOOL" | sha256sum --check
chmod +x "$TOOL"
# Extraction avoids requiring FUSE privileges on GitHub-hosted runners.
(cd "$STAGE" && "$TOOL" --appimage-extract >/dev/null)
ARCH="$ARCH" "$STAGE/squashfs-root/AppRun" "$APPDIR" "$OUTPUT/$NAME.AppImage"
chmod +x "$OUTPUT/$NAME.AppImage"
"$PYTHON" installer/package_release.py checksums --target linux --arch "$ARCH"
