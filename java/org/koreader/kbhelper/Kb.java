package org.koreader.kbhelper;

import android.app.Activity;
import android.content.Context;
import android.graphics.Color;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.view.KeyEvent;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputConnectionWrapper;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.TextView;

/**
 * Hidden EditText that gives the system IME a real InputConnection
 * (predictions, swipe, handwriting/stylus IMEs...). All state is exchanged with
 * Lua by polling: Lua calls show/hide/push and reads poll().
 * Cursor offsets are in Unicode code points (matching KOReader's char lists).
 */
public final class Kb {
    private static Activity act;
    private static KbEdit edit;
    private static final Object lock = new Object();
    private static boolean dirty, enter, suppress, lastImeVisible;
    private static boolean hiddenReported;
    private static String text = "";
    private static int cursor;

    private static final class KbEdit extends EditText {
        KbEdit(Context c) { super(c); }
        @Override protected void onSelectionChanged(int s, int e) {
            super.onSelectionChanged(s, e);
            if (!suppress) capture();
        }
        // Many IMEs (e.g. Trime) send ASCII/backspace via sendKeyEvent(). By default that goes
        // through the window input queue, which NativeActivity hands to native code, so
        // route those events to this view instead.
        @Override public InputConnection onCreateInputConnection(EditorInfo info) {
            InputConnection ic = super.onCreateInputConnection(info);
            if (ic == null) return null;
            return new InputConnectionWrapper(ic, true) {
                @Override public boolean sendKeyEvent(KeyEvent ev) { return KbEdit.this.dispatchKeyEvent(ev); }
            };
        }
    }

    private static void capture() {
        KbEdit e = edit;
        if (e == null) return;
        String t = e.getText().toString();
        int sel = Math.max(0, e.getSelectionEnd());
        sel = Math.min(sel, t.length());
        synchronized (lock) {
            text = t;
            cursor = t.codePointCount(0, sel);
            dirty = true;
        }
    }

    public static void init(Activity a) { act = a; }

    /** inputType: android.text.InputType bits; imeOptions: EditorInfo bits. */
    public static void show(final String initial, final int cur, final int inputType,
                            final int imeOptions, final boolean singleLine) {
        act.runOnUiThread(new Runnable() { public void run() {
            removeEdit();
            KbEdit e = new KbEdit(act);
            edit = e;
            e.setBackground(null);
            e.setTextColor(Color.TRANSPARENT);
            e.setCursorVisible(false);
            e.setSingleLine(singleLine);
            e.setInputType(inputType);
            e.setImeOptions(imeOptions | EditorInfo.IME_FLAG_NO_EXTRACT_UI | EditorInfo.IME_FLAG_NO_FULLSCREEN);
            suppress = true;
            e.setText(initial);
            e.setSelection(offset(initial, cur));
            suppress = false;
            synchronized (lock) { text = initial; cursor = cur; dirty = false; enter = false; hiddenReported = false; lastImeVisible = false; }
            e.addTextChangedListener(new TextWatcher() {
                public void beforeTextChanged(CharSequence s, int a, int b, int c) {}
                public void onTextChanged(CharSequence s, int a, int b, int c) {}
                public void afterTextChanged(Editable s) { if (!suppress) capture(); }
            });
            e.setOnEditorActionListener(new TextView.OnEditorActionListener() {
                public boolean onEditorAction(TextView v, int id, android.view.KeyEvent ev) {
                    synchronized (lock) { enter = true; }
                    return true;
                }
            });
            act.addContentView(e, new FrameLayout.LayoutParams(2, 2, Gravity.BOTTOM | Gravity.LEFT));
            e.setFocusable(true);
            e.setFocusableInTouchMode(true);
            e.requestFocusFromTouch();
            final InputMethodManager imm = (InputMethodManager) act.getSystemService(Context.INPUT_METHOD_SERVICE);
            e.postDelayed(new Runnable() { public void run() {
                KbEdit k = edit;
                if (k == null) return;
                if (!k.hasFocus()) k.requestFocusFromTouch();
                imm.restartInput(k);
                imm.showSoftInput(k, InputMethodManager.SHOW_FORCED);
            }}, 100);
        }});
    }

    /** Re-show the IME for the existing field without recreating it. */
    public static void reshow() {
        act.runOnUiThread(new Runnable() { public void run() {
            KbEdit k = edit;
            if (k == null) return;
            InputMethodManager imm = (InputMethodManager) act.getSystemService(Context.INPUT_METHOD_SERVICE);
            synchronized (lock) { hiddenReported = false; lastImeVisible = false; }
            imm.showSoftInput(k, InputMethodManager.SHOW_FORCED);
        }});
    }

    public static void hide() {
        act.runOnUiThread(new Runnable() { public void run() {
            KbEdit e = edit;
            if (e != null) {
                InputMethodManager imm = (InputMethodManager) act.getSystemService(Context.INPUT_METHOD_SERVICE);
                imm.hideSoftInputFromWindow(e.getWindowToken(), 0);
            }
            removeEdit();
        }});
    }

    /** Lua -> IME: replace text/cursor. */
    public static void push(final String t, final int cur) {
        act.runOnUiThread(new Runnable() { public void run() {
            KbEdit e = edit;
            if (e == null) return;
            suppress = true;
            if (!e.getText().toString().equals(t)) e.setText(t);
            e.setSelection(offset(t, cur));
            suppress = false;
            synchronized (lock) { text = t; cursor = cur; dirty = false; }
        }});
    }

    /**
     * IME -> Lua. Returns null when nothing changed, else "cursor,flags,text".
     * flags: 1 = editor action (Enter/Done) pressed, 2 = IME was dismissed.
     */
    public static String poll() {
        int flags = 0;
        boolean imeNow = isImeVisible();
        synchronized (lock) {
            if (imeNow) lastImeVisible = true;
            else if (lastImeVisible && !hiddenReported) { hiddenReported = true; flags |= 2; }
            if (enter) { flags |= 1; enter = false; }
            if (!dirty && flags == 0) return null;
            dirty = false;
            return cursor + "," + flags + "," + text;
        }
    }

    /** Height in pixels the IME currently covers at the bottom of the window (0 if hidden). */
    public static int imeHeight() {
        View v = edit != null ? edit : act.getWindow().getDecorView();
        int h = 0;
        if (android.os.Build.VERSION.SDK_INT >= 30) {
            WindowInsets wi = v.getRootWindowInsets();
            if (wi != null && wi.isVisible(WindowInsets.Type.ime())) h = wi.getInsets(WindowInsets.Type.ime()).bottom;
        }
        if (h == 0) { // fallback: how much of the window is no longer visible
            android.graphics.Rect r = new android.graphics.Rect();
            View root = act.getWindow().getDecorView();
            root.getWindowVisibleDisplayFrame(r);
            h = Math.max(0, root.getHeight() - r.bottom);
        }
        return h;
    }

    private static boolean isImeVisible() {
        KbEdit e = edit;
        if (e == null || android.os.Build.VERSION.SDK_INT < 30) return true;
        WindowInsets wi = e.getRootWindowInsets();
        return wi == null || wi.isVisible(WindowInsets.Type.ime());
    }

    private static int offset(String s, int cp) {
        int n = s.codePointCount(0, s.length());
        return s.offsetByCodePoints(0, Math.max(0, Math.min(cp, n)));
    }

    private static void removeEdit() {
        KbEdit e = edit;
        edit = null;
        if (e != null && e.getParent() instanceof ViewGroup) ((ViewGroup) e.getParent()).removeView(e);
    }
}
