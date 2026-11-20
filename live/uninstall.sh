#!/bin/zsh
# Remove everything install.sh and the app created.
launchctl bootout gui/$(id -u)/local.justtype 2>/dev/null
# also stop a manually opened copy; SIGTERM lets it remove its keyboard tap cleanly
pkill -TERM -f "/JustType.app/Contents/MacOS/JustType" 2>/dev/null && sleep 1
rm -f ~/Library/LaunchAgents/local.justtype.plist
rm -rf /Applications/JustType.app "$HOME/Library/Application Support/JustType" ~/Library/Logs/JustType
tccutil reset All local.justtype 2>/dev/null
defaults delete local.justtype 2>/dev/null
security delete-identity -c "JustType Local Signing" ~/Library/Keychains/login.keychain-db 2>/dev/null
echo "JustType removed."
