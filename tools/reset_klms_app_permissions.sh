#!/bin/zsh

set -euo pipefail

BUNDLE_ID="${BUNDLE_ID:-com.local.KLMSync}"
HELPER_BUNDLE_ID="${HELPER_BUNDLE_ID:-$BUNDLE_ID.notice-native-note}"

for bundle_id in "$BUNDLE_ID" "$HELPER_BUNDLE_ID"; do
  for service in Accessibility AppleEvents Calendar Reminders Notifications; do
    if tccutil reset "$service" "$bundle_id"; then
      print -r -- "reset $service for $bundle_id"
    else
      print -u2 -- "warning: failed to reset $service for $bundle_id"
    fi
  done
done

print -r -- "Open System Settings > Privacy & Security > Accessibility and enable KLMS Sync."
print -r -- "If KLMS 공지 메모 렌더러 appears there, enable it too."
print -r -- "Open System Settings > Privacy & Security > Automation and allow KLMS Sync to control Safari, Notes, System Events, Calendar, and Reminders."
print -r -- "Open System Settings > Privacy & Security > Calendars and Reminders and allow KLMS Sync if macOS shows separate entries."
print -r -- "Then open KLMS Sync > 앱/권한 > 권한 요청 to re-run the exact app, engine, and notice-renderer permission probes."
