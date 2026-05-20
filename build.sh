#!/usr/bin/env bash
set -e

APP_NAME="AISwitcher"
APP_BUNDLE="${APP_NAME}.app"
BUILD_DIR=".build/release"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"

echo "► Swift build başlıyor..."
swift build -c release 2>&1

echo "► App bundle oluşturuluyor..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/"
cp "Info.plist" "${APP_BUNDLE}/Contents/"
cp "Sources/AISwitcher/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/"

if [[ -z "${CODESIGN_IDENTITY}" ]]; then
  CODESIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' '/"/ { print $2; exit }'
  )"
fi

if [[ -n "${CODESIGN_IDENTITY}" ]]; then
  echo "► App imzalanıyor: ${CODESIGN_IDENTITY}"
  codesign --force --deep --sign "${CODESIGN_IDENTITY}" "${APP_BUNDLE}"
else
  echo "► Geçerli imza kimliği bulunamadı; ad-hoc imza kullanılıyor"
  codesign --force --deep --sign - "${APP_BUNDLE}"
fi

echo "► Build tamamlandı: ${APP_BUNDLE}"
echo ""
echo "Başlatmak için:"
echo "  open ${APP_BUNDLE}"
echo ""
echo "Her oturumda otomatik başlaması için:"
echo "  cp -R ${APP_BUNDLE} /Applications/"
echo "  Sistem Tercihleri → Genel → Giriş Öğeleri → + → AISwitcher.app"
