# Android native keyboard (KOReader plugin)

Use Android's own on-screen keyboard (IME) in KOReader text fields, so you get predictions, swipe typing and
stylus/handwriting keyboards instead of KOReader's built-in virtual keyboard.

> **Note: this project is 100% AI-generated code** (written by Claude, an AI assistant). It has only been tested
> on a single Android e-ink device with one keyboard app. Review it before relying on it.

## Install

**[Download the latest release](https://github.com/bomberstudios/ko-android-keyboard/releases/latest/download/androidkeyboard.koplugin.zip)**
(`androidkeyboard.koplugin.zip`; see all versions on the [releases page](https://github.com/bomberstudios/ko-android-keyboard/releases/latest)).

1. Unzip it and copy the `androidkeyboard.koplugin` folder (including `kbhelper.dex`) to KOReader's `plugins/` folder
   on your device (e.g. `/sdcard/koreader/plugins/`), for example with
   `adb push androidkeyboard.koplugin /sdcard/koreader/plugins/`.
2. Restart KOReader.
3. Toggle it under Settings (gear) → *Android native keyboard*. Dialogs that are already open keep their old keyboard.

If the helper can't be loaded, the plugin shows a message and keeps KOReader's own keyboard.

## How it works

KOReader's `NativeActivity` gives the system keyboard no `InputConnection`, which is why swipe, predictions and
handwriting can't work out of the box. This plugin adds one without modifying the KOReader APK:

- `java/org/koreader/kbhelper/Kb.java` owns a hidden `EditText`. It is built into
  `androidkeyboard.koplugin/kbhelper.dex` by `./build.sh`.
- `kbbridge.lua` loads that `.dex` at runtime over JNI (copied to the app's code cache and marked read-only,
  as Android 14+ requires) and wraps the calls.
- `main.lua` replaces KOReader's virtual keyboard with a stub. While a text field is active it polls the helper
  (about 12 times a second) and mirrors text and cursor both ways. Enter/Done triggers the field's `enter_callback`.
- The helper routes keys the IME sends via `sendKeyEvent` (many IMEs do this for letters and backspace) to the
  hidden field. Otherwise they would go to KOReader's native input queue.
- The helper reports the IME height. The stub passes it to the dialog (`onKeyboardHeightChanged`) so the text
  field is laid out above the keyboard instead of underneath it.
- Number and password fields get the matching Android input type.

## Rebuilding the helper

Needs a JDK and the Android SDK (`ANDROID_HOME`, default `~/Library/Android/sdk`):

```sh
./build.sh
```

## Known limitations

- Android only. Tested on a single device and IME.
- The first time a dialog opens in a session it may re-layout once after the keyboard appears, because the
  keyboard height isn't known until it has been shown. The height is remembered for later dialogs.
- Only the cursor is mirrored from the IME, not text selections.
- Characters outside the Basic Multilingual Plane (e.g. emoji) may not round-trip correctly.

## License

[MIT](LICENSE) © 2026 Ale Muñoz
