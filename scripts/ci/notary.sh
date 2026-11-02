#!/bin/bash
set -euo pipefail
: "${APPLE_ID:?}" "${APPLE_ID_PWD:?}" "${APPLE_TEAM_ID:?}" "${SIGNING_CERTIFICATE_NAME:?}"
APP_PATH=output/output.xcarchive/Products/Applications/Lumik.app
codesign --verify --deep --strict "$APP_PATH"
# Notarize and staple the app before making the distribution image.
ditto -c -k --keepParent "$APP_PATH" output/Lumik.zip
xcrun notarytool submit output/Lumik.zip --apple-id "$APPLE_ID" --password "$APPLE_ID_PWD" --team-id "$APPLE_TEAM_ID" --wait
xcrun stapler staple "$APP_PATH"
mkdir -p output/dmg
 ditto "$APP_PATH" output/dmg/Lumik.app
ln -s /Applications output/dmg/Applications
hdiutil create -volname Lumik -srcfolder output/dmg -ov -format UDZO Lumik.dmg
codesign --sign "$SIGNING_CERTIFICATE_NAME" --timestamp Lumik.dmg
xcrun notarytool submit Lumik.dmg --apple-id "$APPLE_ID" --password "$APPLE_ID_PWD" --team-id "$APPLE_TEAM_ID" --wait
xcrun stapler staple Lumik.dmg
xcrun stapler validate Lumik.dmg
