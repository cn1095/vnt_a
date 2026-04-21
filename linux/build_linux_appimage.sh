#!/bin/bash
set -e

BUNDLE=$1
APPIMAGE_ARCH=$2

apt-get update -q
apt-get install -y --no-install-recommends \
  curl git cmake ninja-build pkg-config clang \
  libgtk-3-dev libblkid-dev liblzma-dev \
  libappindicator3-dev libkeybinder-3.0-dev \
  libsecret-1-dev libjsoncpp-dev \
  ca-certificates wget file xz-utils unzip

# 容器内独立安装 Flutter 3.24.5
git clone --depth 1 --branch 3.24.5 \
  https://github.com/flutter/flutter.git /opt/flutter
export PATH="/opt/flutter/bin:$PATH"
flutter precache --linux
flutter --version

# 安装并强制固定 Rust 1.77.2，禁止自动升级
export CARGO_HOME=/opt/cargo
export RUSTUP_HOME=/opt/rustup
export PATH="/opt/cargo/bin:$PATH"
curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | \
  sh -s -- -y --default-toolchain 1.77.2 --no-modify-path \
    --no-update-default-toolchain
rustup set auto-self-update disable
rustup default 1.77.2
rustc -V

flutter config --no-analytics
flutter pub get
flutter build linux --release

# 下载 appimagetool（用 extract 方式兼容 arm64 容器）
wget -q -O appimagetool.AppImage \
  https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x appimagetool.AppImage
./appimagetool.AppImage --appimage-extract
mv squashfs-root appimagetool-extracted

# 构建 AppDir
mkdir -p AppDir/usr/share/icons/hicolor/256x256/apps
cp -r ${BUNDLE}/. AppDir/
cp assets/app_icon.png AppDir/vnt_app.png
cp assets/app_icon.png AppDir/usr/share/icons/hicolor/256x256/apps/vnt_app.png

cat > AppDir/vnt_app.desktop << EOF
[Desktop Entry]
Name=VNT App
Exec=vnt_app
Icon=vnt_app
Type=Application
Categories=Network;
EOF

cat > AppDir/AppRun << EOF
#!/bin/bash
HERE="\$(dirname "\$(readlink -f "\$0")")"
export LD_LIBRARY_PATH="\$HERE/lib:\$LD_LIBRARY_PATH"
exec "\$HERE/vnt_app" "\$@"
EOF
chmod +x AppDir/AppRun

ARCH=${APPIMAGE_ARCH} ./appimagetool-extracted/AppRun AppDir \
  vntApp-linux-${APPIMAGE_ARCH}.AppImage
