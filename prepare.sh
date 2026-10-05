#!/usr/bin/env bash
# יוצר את תיקיות הפלטפורמה (android / ios) ומגדיר הרשאות רשת ושם אפליקציה
set -e
cd "$(dirname "$0")/.."

if [ ! -d android ] || [ ! -d ios ]; then
  flutter create --org il.lior --project-name tcl_remote --platforms=android,ios .
  rm -rf test
fi

flutter pub get

# אנדרואיד: הרשאת אינטרנט + שם
M=android/app/src/main/AndroidManifest.xml
if [ -f "$M" ]; then
  grep -q 'android.permission.INTERNET' "$M" || \
    perl -0pi -e 's#<application#<uses-permission android:name="android.permission.INTERNET"/>\n    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>\n    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE"/>\n    <application#' "$M"
  perl -0pi -e 's#android:label="[^"]*"#android:label="שלט TCL"#' "$M"
fi

# אייפון: הרשאת רשת מקומית + שם
P=ios/Runner/Info.plist
if [ -f "$P" ] && [ -x /usr/libexec/PlistBuddy ]; then
  /usr/libexec/PlistBuddy -c "Delete :NSLocalNetworkUsageDescription" "$P" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :NSLocalNetworkUsageDescription string השלט צריך גישה לרשת הביתית כדי להתחבר לטלוויזיות" "$P"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName שלט TCL" "$P" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string שלט TCL" "$P"
fi

# אייקונים
dart run flutter_launcher_icons || echo "icons step skipped"
