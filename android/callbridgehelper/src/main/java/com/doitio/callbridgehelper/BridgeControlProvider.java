package com.doitio.callbridgehelper;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.os.Binder;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.Parcel;
import android.os.RemoteException;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;

/** DUMP protects provider acquisition; every bootstrap and control call requires the actual shell UID. */
public final class BridgeControlProvider extends ContentProvider {
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Binder control = new Binder() {
        @Override protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) throws RemoteException {
            if (Binder.getCallingUid() != 2000) throw new SecurityException("shell_uid_required");
            if (code == INTERFACE_TRANSACTION) { reply.writeString(CallBridgeControl.DESCRIPTOR); return true; }
            if (code < CallBridgeControl.PING || code > CallBridgeControl.RELEASE) return super.onTransact(code, data, reply, flags);
            data.enforceInterface(CallBridgeControl.DESCRIPTOR);
            final IBinder owner = code == CallBridgeControl.PING ? null : data.readStrongBinder();
            if (code != CallBridgeControl.PING && owner == null) throw new IllegalArgumentException("owner_binder_required");
            FutureTask<BridgeInCallService.Snapshot> request = new FutureTask<>(() -> {
                BridgeInCallService service = BridgeInCallService.current;
                return service == null ? BridgeInCallService.Snapshot.NONE : service.control(code, owner);
            });
            main.post(request);
            try {
                BridgeInCallService.Snapshot result = request.get(3, TimeUnit.SECONDS);
                reply.writeNoException();
                if (code == CallBridgeControl.PING) reply.writeInt(CallBridgeControl.VERSION);
                else if (code == CallBridgeControl.CLAIM) reply.writeString(result.callId);
                reply.writeInt(result.state);
                if (code == CallBridgeControl.CLAIM || code == CallBridgeControl.STATE) {
                    reply.writeString(result.callerName);
                    reply.writeString(result.callerNumber);
                }
                return true;
            } catch (Exception error) {
                request.cancel(false);
                // A late main-thread CLAIM must release this owner, without affecting a newer owner.
                if (code == CallBridgeControl.CLAIM) main.post(() -> {
                    BridgeInCallService service = BridgeInCallService.current;
                    if (service != null) service.releaseClaim(owner);
                });
                throw new RemoteException("helper_main_thread_unavailable");
            }
        }
    };

    @Override public boolean onCreate() { return true; }
    @Override public Bundle call(String authority, String method, String argument, Bundle extras) {
        if (Binder.getCallingUid() != 2000) throw new SecurityException("shell_uid_required");
        getContext().enforceCallingPermission("android.permission.DUMP", "existing_dump_permission_required");
        if (!CallBridgeControl.AUTHORITY.equals(authority)) throw new IllegalArgumentException("provider_authority_required");
        Bundle result = new Bundle();
        if (CallBridgeControl.METHOD_CONTROL.equals(method)) result.putBinder(CallBridgeControl.BINDER_KEY, control);
        else if ("ping".equals(method)) {
            Parcel request = Parcel.obtain(), reply = Parcel.obtain();
            try {
                request.writeInterfaceToken(CallBridgeControl.DESCRIPTOR);
                control.transact(CallBridgeControl.PING, request, reply, 0);
                reply.readException();
                result.putInt("version", reply.readInt());
                result.putInt("state", reply.readInt());
                result.putBoolean("call_control", false);
            } catch (RemoteException unavailable) { throw new IllegalStateException("helper_ping_unavailable"); }
            finally { request.recycle(); reply.recycle(); }
        } else throw new IllegalArgumentException("control_or_ping_required");
        return result;
    }
    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] args, String order) { throw new UnsupportedOperationException(); }
    @Override public String getType(Uri uri) { return null; }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String selection, String[] args) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] args) { throw new UnsupportedOperationException(); }
}
