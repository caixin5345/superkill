#!/usr/bin/env bash
#
# macOS 本地重签（需要付费开发者账号的证书 + 含该 App Group 的描述文件）
#
#   用法：
#     ./scripts/sign_local.sh SuperKill-unsigned.ipa \
#         "Apple Development: Your Name (TEAMID)" \
#         ~/Downloads/SuperKill_Dev.mobileprovision \
#         group.TEAMID.superkill
#
set -euo pipefail

IPA="${1:?unsigned ipa}"
IDENTITY="${2:?codesign identity}"
PROFILE="${3:?mobileprovision}"
GROUP="${4:?app group}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

unzip -q "$IPA" -d "$WORK"
APP="$WORK/Payload/SuperKill.app"
[[ -d "$APP" ]] || { echo "[!] IPA 结构异常"; exit 1; }

cp "$PROFILE" "$APP/embedded.mobileprovision"

security cms -D -i "$PROFILE" > "$WORK/profile.plist"
APPID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$WORK/profile.plist")"
TEAM="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$WORK/profile.plist")"

cat > "$WORK/ent.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>${APPID}</string>
	<key>com.apple.developer.team-identifier</key>
	<string>${TEAM}</string>
	<key>get-task-allow</key>
	<true/>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>${GROUP}</string>
	</array>
</dict>
</plist>
EOF

if [[ -d "$APP/Frameworks" ]]; then
  for bin in "$APP/Frameworks"/*; do
    codesign --force --sign "$IDENTITY" --timestamp=none "$bin" || true
  done
fi

codesign --force --sign "$IDENTITY" --entitlements "$WORK/ent.plist" \
         --generate-entitlement-der --timestamp=none "$APP"

echo "[*] 签名后的 entitlements："
codesign -d --entitlements :- "$APP"

(cd "$WORK" && zip -qry out.ipa Payload)
mv "$WORK/out.ipa" "${IPA%.ipa}-signed.ipa"
echo "[+] 产物：${IPA%.ipa}-signed.ipa"
echo "[*] 安装（任选其一）："
echo "    xcrun devicectl device install app --device <UDID> <解包目录>/Payload/SuperKill.app"
echo "    xcrun ios-deploy --bundle <解包目录>/Payload/SuperKill.app"
