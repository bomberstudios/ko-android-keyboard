#!/bin/sh
# Builds androidkeyboard.koplugin/kbhelper.dex from java/. Needs JDK + Android SDK (ANDROID_HOME).
set -e
cd "$(dirname "$0")"
SDK=${ANDROID_HOME:-$HOME/Library/Android/sdk}
JAR=$(ls -d "$SDK"/platforms/android-*/android.jar | sort -V | tail -1)
D8=$(ls -d "$SDK"/build-tools/*/d8 | sort -V | tail -1)
rm -rf build && mkdir build
javac --release 8 -cp "$JAR" -d build java/org/koreader/kbhelper/Kb.java
"$D8" --min-api 21 --lib "$JAR" --output build build/org/koreader/kbhelper/*.class
cp build/classes.dex androidkeyboard.koplugin/kbhelper.dex
echo "built $(wc -c < androidkeyboard.koplugin/kbhelper.dex) bytes"
