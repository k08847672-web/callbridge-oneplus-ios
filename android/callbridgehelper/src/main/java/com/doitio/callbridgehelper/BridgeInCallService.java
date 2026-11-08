package com.doitio.callbridgehelper;

import android.content.Intent;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.RemoteException;
import android.telecom.Call;
import android.telecom.InCallService;
import android.telecom.VideoProfile;
import java.util.IdentityHashMap;
import java.util.NoSuchElementException;
import java.util.UUID;

/** Telecom owns Call delivery; only a separately protected shell Binder can claim/control one Call. */
public final class BridgeInCallService extends InCallService {
    static volatile BridgeInCallService current;
    private final Handler main = new Handler(Looper.getMainLooper());
    private Claim claim;
    private final IdentityHashMap<Call, String> identities = new IdentityHashMap<>();

    @Override public void onCreate() { super.onCreate(); current = this; }
    @Override public boolean onUnbind(Intent intent) {
        releaseClaim(null);
        identities.clear();
        return super.onUnbind(intent);
    }
    @Override public void onDestroy() {
        if (current == this) current = null;
        releaseClaim(null);
        identities.clear();
        super.onDestroy();
    }
    @Override public void onCallAdded(Call call) { identities.put(call, UUID.randomUUID().toString()); }
    @Override public void onCallRemoved(Call call) {
        identities.remove(call);
        if (claim != null && claim.call == call) releaseClaim(claim.owner);
    }

    /** Called only on the helper main thread, after the control service checks the real Binder UID. */
    Snapshot control(int code, IBinder owner) throws RemoteException {
        if (code == CallBridgeControl.PING) {
            if (claim != null && claim.state() == 2) return new Snapshot(null, 2);
            return new Snapshot(null, eligibleRinging() == null ? 0 : 1);
        }
        if (code == CallBridgeControl.RELEASE) { releaseClaim(owner); return Snapshot.NONE; }
        if (code == CallBridgeControl.CLAIM) {
            if (claim == null) {
                Call call = eligibleRinging();
                if (call == null) return Snapshot.NONE;
                claim = new Claim(call, owner);
            }
        }
        Claim owned = claim;
        if (owned == null || !owned.owner.equals(owner)) return Snapshot.NONE;
        if (code == CallBridgeControl.ANSWER) owned.answer();
        else if (code == CallBridgeControl.DISCONNECT) owned.disconnect();
        return new Snapshot(owned.callId, owned.state());
    }

    private Call eligibleRinging() {
        if (getCalls().size() != 1) return null;
        Call call = getCalls().get(0);
        if (call.getState() != Call.STATE_RINGING
                || call.getDetails().getCallDirection() != Call.Details.DIRECTION_INCOMING
                || call.getDetails().hasProperty(Call.Details.PROPERTY_SELF_MANAGED)
                || call.getDetails().hasProperty(Call.Details.PROPERTY_IS_EXTERNAL_CALL)) return null;
        return call;
    }

    void releaseClaim(IBinder owner) {
        Claim owned = claim;
        if (owned != null && (owner == null || owned.owner.equals(owner))) {
            claim = null;
            try { owned.owner.unlinkToDeath(owned.death, 0); }
            catch (NoSuchElementException alreadyDead) { /* The dying Binder may already have removed it. */ }
        }
    }

    static final class Snapshot {
        static final Snapshot NONE = new Snapshot(null, 0);
        final String callId;
        final int state;
        Snapshot(String callId, int state) { this.callId = callId; this.state = state; }
    }

    private final class Claim {
        final Call call;
        final IBinder owner;
        final IBinder.DeathRecipient death;
        final String callId;
        boolean answerSent, disconnectSent;
        Claim(Call call, IBinder owner) throws RemoteException {
            this.call = call; this.owner = owner;
            String existing = identities.get(call);
            if (existing == null) { existing = UUID.randomUUID().toString(); identities.put(call, existing); }
            callId = existing;
            death = () -> main.post(() -> { if (claim == this) releaseClaim(owner); });
            owner.linkToDeath(death, 0);
        }
        int state() {
            if (!getCalls().contains(call)) return 0;
            int state = call.getState();
            // A sent ANSWER can remain ringing until Telecom reports ACTIVE. No second ANSWER is allowed.
            return state == Call.STATE_RINGING ? 1 : state == Call.STATE_ACTIVE && answerSent ? 2 : 0;
        }
        void answer() {
            if (answerSent || disconnectSent || !getCalls().contains(call) || call.getState() != Call.STATE_RINGING) return;
            answerSent = true;
            call.answer(VideoProfile.STATE_AUDIO_ONLY);
        }
        void disconnect() {
            if (!answerSent || disconnectSent || !getCalls().contains(call) || call.getState() != Call.STATE_ACTIVE) return;
            disconnectSent = true;
            call.disconnect();
        }
    }
}
