package com.doitio.callbridgehelper;

import android.os.IBinder;

/** One shell-only Binder contract shared verbatim by the helper and app_process client. */
public final class CallBridgeControl {
    private CallBridgeControl() { }
    public static final String PACKAGE = "com.doitio.callbridgehelper";
    public static final String AUTHORITY = PACKAGE + ".control";
    public static final String METHOD_CONTROL = "control";
    public static final String BINDER_KEY = "control";
    public static final String DESCRIPTOR = PACKAGE + ".IControl";
    public static final int VERSION = 2;
    public static final int PING = IBinder.FIRST_CALL_TRANSACTION;
    public static final int CLAIM = PING + 1;
    public static final int STATE = PING + 2;
    public static final int ANSWER = PING + 3;
    public static final int DISCONNECT = PING + 4;
    public static final int RELEASE = PING + 5;
    // PING: interface token -> exception, version, state. No claim or call control.
    // CLAIM: interface token, owner Binder -> exception, nullable original UUID, state, caller name, number.
    // STATE: interface token, owner Binder -> exception, state, caller name, number.
    // Others: interface token, owner Binder -> exception, state. 0=none, 1=ringing, 2=owned active.
}
