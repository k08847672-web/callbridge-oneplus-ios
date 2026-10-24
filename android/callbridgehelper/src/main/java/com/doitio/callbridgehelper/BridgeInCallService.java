package com.doitio.callbridgehelper;

import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.Handler;
import android.os.Looper;
import android.telecom.Call;
import android.telecom.InCallService;
import android.telecom.VideoProfile;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.util.Arrays;
import java.util.IdentityHashMap;
import java.util.UUID;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;

/** No Activity, network permission, number/contacts access, settings changes or stored call data. */
public final class BridgeInCallService extends InCallService {
    private final Handler main = new Handler(Looper.getMainLooper());
    private volatile LocalServerSocket listener;
    private volatile Claim claim;
    private volatile boolean stopping;
    private Thread server;
    // Identity keys deliberately track the exact Telecom Call, never a number or a replacement Call.
    private final IdentityHashMap<Call, String> identities = new IdentityHashMap<>();
    private final Call.Callback callback = new Call.Callback() {
        @Override public void onStateChanged(Call call, int state) {
            Claim current = claim;
            if (current != null && current.call == call) current.publishState();
        }
    };

    @Override public void onCreate() {
        super.onCreate();
        server = new Thread(() -> {
            try (LocalServerSocket endpoint = new LocalServerSocket("pjz-callbridge-owned-call")) {
                listener = endpoint;
                while (!stopping) {
                    try (LocalSocket socket = endpoint.accept()) {
                        if (socket.getPeerCredentials().getUid() != 2000) continue;
                        DataInputStream input = new DataInputStream(socket.getInputStream());
                        if (input.readInt() != 0x50435a32) continue;
                        byte[] token = new byte[32]; input.readFully(token);
                        Claim selected = null;
                        long readyUntil = android.os.SystemClock.elapsedRealtime() + 3000;
                        while (selected == null && !stopping && android.os.SystemClock.elapsedRealtime() < readyUntil) {
                            FutureTask<Claim> select = new FutureTask<>(() -> claimRinging(socket, token));
                            main.post(select);
                            selected = select.get(3, TimeUnit.SECONDS);
                            if (selected == null) Thread.sleep(20); // Telecom may still be delivering onCallAdded.
                        }
                        Arrays.fill(token, (byte) 0);
                        if (selected == null) continue;
                        final Claim owned = selected;
                        owned.initialize();
                        try {
                            while (!stopping) {
                                int command = input.readUnsignedByte();
                                if (command != 1 && command != 2) throw new IOException("invalid_command");
                                main.post(() -> {
                                    if (claim != owned) return;
                                    if (command == 1) owned.answer();
                                    else owned.disconnect();
                                });
                            }
                        } finally {
                            main.post(() -> { if (claim == owned) { claim = null; owned.clear(); } });
                        }
                    } catch (Exception ignored) { /* No raw exception, phone details or token logs. */ }
                }
            } catch (IOException ignored) { }
        }, "callbridge-owned-call");
        server.setDaemon(true); server.start();
    }

    private Claim claimRinging(LocalSocket socket, byte[] token) throws IOException {
        if (claim != null || getCalls().size() != 1) return null;
        Call call = getCalls().get(0);
        if (call.getState() != Call.STATE_RINGING || call.getDetails().getCallDirection() != Call.Details.DIRECTION_INCOMING
                || call.getDetails().hasProperty(Call.Details.PROPERTY_SELF_MANAGED)
                || call.getDetails().hasProperty(Call.Details.PROPERTY_IS_EXTERNAL_CALL)) return null;
        claim = new Claim(call, socket, token.clone());
        return claim;
    }

    @Override public void onCallAdded(Call call) {
        identities.put(call, UUID.randomUUID().toString());
        call.registerCallback(callback, main);
    }
    @Override public void onCallRemoved(Call call) {
        call.unregisterCallback(callback);
        identities.remove(call);
        Claim current = claim;
        if (current != null && current.call == call) current.sendState(0);
    }
    @Override public void onDestroy() {
        stopping = true;
        Claim current = claim;
        claim = null;
        if (current != null) current.clear();
        LocalServerSocket endpoint = listener;
        if (endpoint != null) try { endpoint.close(); } catch (IOException ignored) { }
        super.onDestroy();
    }

    private final class Claim {
        final Call call;
        final LocalSocket socket;
        final DataOutputStream output;
        final byte[] token;
        final String callId;
        boolean answerSent, disconnectSent, initialized;
        Claim(Call call, LocalSocket socket, byte[] token) throws IOException {
            this.call = call; this.socket = socket; this.token = token;
            String existing = identities.get(call);
            if (existing == null) { existing = UUID.randomUUID().toString(); identities.put(call, existing); }
            callId = existing;
            output = new DataOutputStream(socket.getOutputStream());
        }
        synchronized void initialize() throws IOException {
            output.write(callId.getBytes(StandardCharsets.US_ASCII)); output.flush();
            initialized = true; publishState();
        }
        void answer() {
            if (answerSent || disconnectSent || !getCalls().contains(call) || call.getState() != Call.STATE_RINGING) return;
            answerSent = true;
            call.answer(VideoProfile.STATE_AUDIO_ONLY); // This exact Call, once; never an existing active call.
        }
        void disconnect() {
            if (!answerSent || disconnectSent || !getCalls().contains(call) || call.getState() != Call.STATE_ACTIVE) return;
            disconnectSent = true;
            call.disconnect(); // Original object remains the target even if a different call arrives.
        }
        void publishState() {
            int state = call.getState();
            sendState(state == Call.STATE_RINGING && !answerSent ? 1 : state == Call.STATE_ACTIVE && answerSent ? 2 : 0);
        }
        synchronized void sendState(int state) {
            if (!initialized) return;
            try { output.writeByte(state); output.flush(); } catch (IOException ignored) { }
        }
        void clear() {
            Arrays.fill(token, (byte) 0);
            try { socket.close(); } catch (IOException ignored) { }
        }
    }
}
