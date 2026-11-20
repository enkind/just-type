#!/bin/zsh
# Build JustType, install it to /Applications and start it at login (LaunchAgent).
# Undo everything with ./uninstall.sh
set -e
cd "$(dirname $0)"

# stable self-signed signing identity, so macOS keeps the Accessibility grant across updates
if ! security find-identity -p codesigning 2>/dev/null | grep -q "JustType Local Signing"; then
  T=$(mktemp -d); trap 'rm -rf $T' EXIT
  cat > $T/cfg.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = JustType Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout $T/key.pem -out $T/cert.pem -days 3650 -config $T/cfg.cnf 2>/dev/null
  P=$(/usr/bin/openssl rand -hex 16)
  /usr/bin/openssl pkcs12 -export -inkey $T/key.pem -in $T/cert.pem -out $T/id.p12 -passout pass:$P -name "JustType Local Signing" 2>/dev/null
  security import $T/id.p12 -k ~/Library/Keychains/login.keychain-db -P $P -T /usr/bin/codesign >/dev/null
  echo "Created signing identity 'JustType Local Signing'"
fi

./build.sh
APP=build/JustType.app
cp Resources/model.json Resources/weights.bin $APP/Contents/Resources/
SIGN=$(security find-identity -p codesigning 2>/dev/null | awk '/JustType Local Signing/ {print $2; exit}')
codesign --force --sign "${SIGN:--}" --identifier local.justtype $APP

# stop every running copy (login agent AND any manually opened one) before replacing it
launchctl bootout gui/$(id -u)/local.justtype 2>/dev/null || true
pkill -TERM -f "/JustType.app/Contents/MacOS/JustType" 2>/dev/null || true
sleep 1

rm -rf /Applications/JustType.app
ditto $APP /Applications/JustType.app
mkdir -p ~/Library/LaunchAgents
cat > ~/Library/LaunchAgents/local.justtype.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.justtype</string>
  <key>ProgramArguments</key><array><string>/Applications/JustType.app/Contents/MacOS/JustType</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PL
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.justtype.plist
echo "JustType installed and running. Allow Accessibility when macOS asks (that's the only permission it needs)."
