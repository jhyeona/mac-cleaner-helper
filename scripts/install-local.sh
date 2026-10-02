#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
CONFIGURATION="${1:-release}"
APP_DIR="$PROJECT_DIR/.build/Biu-${CONFIGURATION}.app"
DESTINATION="$HOME/Applications/비우.app"

"$PROJECT_DIR/scripts/build-app.sh" "$CONFIGURATION"

# Never replace a running app or a different app at the destination.
if /usr/bin/pgrep -x Biu >/dev/null; then
  print -u2 "비우를 종료한 뒤 다시 실행하세요. 개발용 앱도 종료해야 합니다."
  exit 1
fi
if [[ -L "$DESTINATION" ]]; then
  print -u2 "설치 대상이 심볼릭 링크여서 중단합니다: $DESTINATION"
  exit 1
fi
if [[ -e "$DESTINATION" ]]; then
  IDENTIFIER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINATION/Contents/Info.plist")
  [[ "$IDENTIFIER" == "io.biu.mac-clean-helper" ]] || exit 1
fi

mkdir -p "$HOME/Applications" "$PROJECT_DIR/.build/local-install-backups"
STAGING_DIR=$(mktemp -d "$HOME/Applications/.biu-install.XXXXXX")
ditto "$APP_DIR" "$STAGING_DIR/비우.app"
codesign --verify --deep --strict "$STAGING_DIR/비우.app"

BACKUP_DIR=""
if [[ -e "$DESTINATION" ]]; then
  BACKUP_DIR=$(mktemp -d "$PROJECT_DIR/.build/local-install-backups/previous.XXXXXX")
  mv "$DESTINATION" "$BACKUP_DIR/비우.app"
fi
if ! mv "$STAGING_DIR/비우.app" "$DESTINATION"; then
  if [[ -n "$BACKUP_DIR" ]]; then
    mv "$BACKUP_DIR/비우.app" "$DESTINATION"
  fi
  print -u2 "설치하지 못했습니다. 이전 앱을 복원했습니다."
  exit 1
fi
rmdir "$STAGING_DIR"
print "설치 완료: $DESTINATION"
[[ -z "$BACKUP_DIR" ]] || print "이전 앱 백업: $BACKUP_DIR/비우.app"
print "등록 폴더, 설정, 분석 기록은 그대로 유지됩니다."
