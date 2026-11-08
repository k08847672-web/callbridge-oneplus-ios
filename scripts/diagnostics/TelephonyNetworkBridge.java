package com.doitio.diagnostics;

import android.content.AttributionSource;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.pm.PackageManager;
import android.media.AudioAttributes;
import android.media.AudioDeviceInfo;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.media.MediaRecorder;
import android.os.Looper;
import android.os.Binder;
import android.os.Bundle;
import android.os.IBinder;
import android.os.Parcel;
import com.doitio.callbridgehelper.CallBridgeControl;
import android.os.Process;
import android.os.SystemClock;
import android.telecom.TelecomManager;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.lang.reflect.InvocationTargetException;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.attribute.PosixFilePermission;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.ArrayDeque;
import java.util.Arrays;
import java.util.EnumSet;
import java.util.Properties;
import java.util.Set;
import java.util.UUID;
import java.util.function.Supplier;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.FutureTask;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import org.json.JSONObject;

/**
 * Explicitly started shell listener, not a dialer, root daemon or boot service.
 * Usage: app_process ... com.doitio.diagnostics.TelephonyNetworkBridge /absolute/private.properties
 * "self-test" tests pure protocol logic; "simulate CONFIG" runs synthetic network audio only.
 * Never changes device settings, writes PCM, places calls or adopts an existing call.
 * Explicit end/recovery expiry can disconnect only the incoming connection answered by this bridge.
 */
public final class TelephonyNetworkBridge {
    private static final int RATE = 16000;
    private static final int SAMPLES = 320;
    private static final int PCM_BYTES = 640;
    private static final int MAX_PCM_QUEUE = 10;
    private static final long STARTED_NS = System.nanoTime();

    private TelephonyNetworkBridge() {}

    public static void main(String[] args) {
        // This branch intentionally precedes all Android accesses so the same regression runs on a JVM.
        if (args.length == 1 && "self-test".equals(args[0])) {
            try { Protocol.selfTest(); Recovery.selfTest(); System.out.println("PJZ_BRIDGE protocol_self_test_passed recovery_self_test_passed audio_opened=false"); }
            catch (Throwable error) { System.err.println("PJZ_BRIDGE protocol_self_test_failed " + error.getClass().getName()); System.exit(1); }
            return;
        }
        if (args.length == 3 && "local-fixture".equals(args[0])) {
            try { LocalFixture.run(Integer.parseInt(args[1]), args[2]); }
            catch (Throwable error) { error.printStackTrace(); System.exit(1); }
            return;
        }
        if (args.length == 2 && ("simulate".equals(args[0]) || "simulate-disconnect".equals(args[0]))) {
            Config simulationConfig = null;
            int result = 1;
            try {
                if (Process.myUid() != 2000) throw new SecurityException("shell_uid_required");
                simulationConfig = Config.load(args[1]);
                if (simulationConfig.allowAnswer) throw new SecurityException("simulation_requires_call_control_disabled");
                try (Simulation simulation = new Simulation(simulationConfig, "simulate-disconnect".equals(args[0]))) {
                    result = simulation.run() ? 0 : 2;
                }
            } catch (Throwable error) { failure("simulation_failed", error); }
            finally {
                if (simulationConfig != null) Arrays.fill(simulationConfig.key, (byte) 0);
                emit("simulation_closed", "exit_status", result, "audio_opened", false,
                        "calls_placed_or_answered", false, "pcm_saved", false);
            }
            System.exit(result);
            return;
        }
        int status = 1;
        Config config = null;
        Session session = null;
        ServerSocket listener = null;
        try {
            if (args.length != 1) throw new IllegalArgumentException("one_private_config_path_required");
            if (Process.myUid() != 2000) throw new SecurityException("shell_uid_required");
            config = Config.load(args[0]);
            Context context = shellContext();
            AudioManager audio = AudioManager.class.getConstructor(Context.class).newInstance(context);
            TelecomManager telecom = TelecomManager.class.getConstructor(Context.class).newInstance(context);
            inspect(context, audio, telecom);
            requireIdle(audio, telecom);
            prepareHelper(context);
            listener = new ServerSocket();
            listener.setReuseAddress(false);
            listener.bind(new InetSocketAddress(config.bindAddress, config.port), 2);
            // One explicit process can observe later incoming calls without keeping an iPhone socket open.
            while (true) {
                session = new Session(config, context, audio, telecom, listener);
                session.run();
                status = session.completedAudioExchange() ? 0 : 2;
                session.close(); session = null;
            }
        } catch (Throwable error) { failure(session == null ? "startup_failed" : session.phase + "_failed", error); }
        finally {
            if (session != null) {
                try { session.close(); }
                catch (Throwable error) { failure("cleanup_failed", error); status = 1; }
            }
            if (listener != null) try { listener.close(); } catch (IOException ignored) { }
            if (config != null) Arrays.fill(config.key, (byte) 0);
            emit("closed", "exit_status", status, "pcm_saved", false, "settings_written", false,
                    "calls_placed", false, "owned_hangup_attempted", session != null && session.recovery.ended,
                    "remote_hearing_verified", false);
        }
        System.exit(status);
    }

    private static Context shellContext() throws Exception {
        if (Looper.getMainLooper() == null) Looper.prepareMainLooper();
        Class<?> activityThread = Class.forName("android.app.ActivityThread");
        Object thread = activityThread.getMethod("systemMain").invoke(null);
        Context system = (Context) activityThread.getMethod("getSystemContext").invoke(thread);
        final AttributionSource source = new AttributionSource.Builder(Process.myUid())
                .setPid(Process.myPid()).setPackageName("com.android.shell").build();
        return new ContextWrapper(system) {
            @Override public String getPackageName() { return "com.android.shell"; }
            @Override public String getOpPackageName() { return "com.android.shell"; }
            @Override public AttributionSource getAttributionSource() { return source; }
            @Override public int getDeviceId() { return 0; }
            @Override public Context getApplicationContext() { return this; }
        };
    }

    private static void prepareHelper(Context context) throws Exception {
        // A new APK has no launcher Activity. Clear only this installed helper's initial
        // stopped bit so Telecom may bind it; never change the default dialer or app-op.
        String name = "com.doitio.callbridgehelper";
        android.content.pm.ApplicationInfo info = context.getPackageManager().getApplicationInfo(name, 0);
        if ((info.flags & android.content.pm.ApplicationInfo.FLAG_STOPPED) != 0) {
            Object binder = Class.forName("android.os.ServiceManager").getMethod("getService", String.class).invoke(null, "package");
            Object packages = Class.forName("android.content.pm.IPackageManager$Stub")
                    .getMethod("asInterface", android.os.IBinder.class).invoke(null, binder);
            Class.forName("android.content.pm.IPackageManager").getMethod("setPackageStoppedState", String.class, boolean.class, int.class)
                    .invoke(packages, name, false, Process.myUid() / 100000);
        }
        emit("helper_ready", "installed", true, "default_dialer_changed", false);
    }

    private static void inspect(Context context, AudioManager audio, TelecomManager telecom) throws Exception {
        if (audio == null || telecom == null) throw new IllegalStateException("services_missing");
        AttributionSource source = context.getAttributionSource();
        emit("identity", "uid", Process.myUid(), "attribution_uid", source.getUid(),
                "shell_package", "com.android.shell".equals(source.getPackageName()),
                "mode", audio.getMode(), "in_call", telecom.isInCall());
        if (source.getUid() != 2000 || !"com.android.shell".equals(source.getPackageName()))
            throw new SecurityException("shell_attribution_required");
        for (String name : new String[]{"RECORD_AUDIO", "CAPTURE_AUDIO_OUTPUT", "CALL_AUDIO_INTERCEPTION",
                "MODIFY_AUDIO_ROUTING", "MODIFY_PHONE_STATE", "READ_PHONE_STATE", "INTERNET"}) {
            boolean granted = context.checkSelfPermission("android.permission." + name) == PackageManager.PERMISSION_GRANTED;
            emit("permission", "name", name, "granted", granted);
            if (!granted) throw new SecurityException("existing_permission_required");
        }
        // Fail now if the observable ringing API is unavailable; do not guess from an audio mode.
        TelecomManager.class.getMethod("isRinging");
        AudioAttributes attrs = attributes();
        emit("attributes", "usage", attrs.getUsage(), "speech", attrs.getContentType() == AudioAttributes.CONTENT_TYPE_SPEECH,
                "samsung_api_used", false);
    }

    private static AudioAttributes attributes() {
        AudioAttributes result = new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build();
        if (result.getUsage() != 2) throw new IllegalStateException("usage_not_preserved");
        return result;
    }

    private static boolean ringing(TelecomManager telecom) throws Exception {
        return (Boolean) TelecomManager.class.getMethod("isRinging").invoke(telecom);
    }

    private static boolean active(AudioManager audio, TelecomManager telecom) {
        return audio.getMode() == AudioManager.MODE_IN_CALL && telecom.isInManagedCall();
    }

    private static void requireIdle(AudioManager audio, TelecomManager telecom) throws Exception {
        if (telecom.isInCall() || ringing(telecom) || audio.getMode() != AudioManager.MODE_NORMAL)
            throw new IllegalStateException("idle_phone_required");
    }

    private static final class Config {
        final InetAddress bindAddress;
        final int port;
        final byte[] key;
        final boolean allowAnswer;
        final String pairingId, providerUrl, providerToken;
        Config(InetAddress bindAddress, int port, byte[] key, boolean allowAnswer) {
            this(bindAddress, port, key, allowAnswer, null, null, null);
        }
        Config(InetAddress bindAddress, int port, byte[] key, boolean allowAnswer,
                String pairingId, String providerUrl, String providerToken) {
            this.bindAddress = bindAddress; this.port = port; this.key = key; this.allowAnswer = allowAnswer;
            this.pairingId = pairingId; this.providerUrl = providerUrl; this.providerToken = providerToken;
        }
        static Config load(String name) throws Exception {
            Path path = Paths.get(name);
            if (!path.isAbsolute() || Files.isSymbolicLink(path) || !Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS))
                throw new SecurityException("private_absolute_regular_config_required");
            Set<PosixFilePermission> expected = EnumSet.of(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE);
            if (!Files.getPosixFilePermissions(path, LinkOption.NOFOLLOW_LINKS).equals(expected) || Files.size(path) > 4096)
                throw new SecurityException("private_config_mode_600_required");
            Properties properties = new Properties();
            byte[] bytes = Files.readAllBytes(path);
            try { properties.load(new ByteArrayInputStream(bytes)); }
            finally { Arrays.fill(bytes, (byte) 0); }
            try {
                for (String item : properties.stringPropertyNames())
                    if (!"bindAddress".equals(item) && !"port".equals(item) && !"pairingKey".equals(item) && !"allowAnswer".equals(item)
                            && !"pairingId".equals(item) && !"providerUrl".equals(item) && !"providerToken".equals(item))
                        throw new IllegalArgumentException("unknown_config_property");
                InetAddress address = tailscaleAddress(properties.getProperty("bindAddress"));
                NetworkInterface iface = NetworkInterface.getByInetAddress(address);
                if (iface == null || !iface.isUp()) throw new IllegalStateException("bind_address_not_local_up");
                int port = Integer.parseInt(properties.getProperty("port", "47631"));
                if (port < 1024 || port > 65535) throw new IllegalArgumentException("port_out_of_range");
                String flag = properties.getProperty("allowAnswer", "false");
                if (!"true".equals(flag) && !"false".equals(flag)) throw new IllegalArgumentException("allow_answer_boolean_required");
                byte[] key = Protocol.decodeKey(properties.getProperty("pairingKey"));
                String pair = properties.getProperty("pairingId"), provider = properties.getProperty("providerUrl"), token = properties.getProperty("providerToken");
                if (pair != null) canonicalId(pair);
                if (provider != null || token != null) {
                    if (pair == null || provider == null || token == null || !token.matches("[A-Za-z0-9_-]{32,256}"))
                        throw new IllegalArgumentException("complete_provider_pairing_required");
                    validateProvider(provider);
                }
                return new Config(address, port, key, "true".equals(flag), pair, provider, token);
            } finally { properties.clear(); }
        }
    }

    private static InetAddress tailscaleAddress(String value) throws Exception {
        if (value == null || !value.matches("[0-9]{1,3}(\\.[0-9]{1,3}){3}"))
            throw new IllegalArgumentException("literal_tailscale_ipv4_required");
        String[] parts = value.split("\\.");
        byte[] octets = new byte[4];
        for (int i = 0; i < 4; i++) {
            int part = Integer.parseInt(parts[i]);
            if (part > 255) throw new IllegalArgumentException("ipv4_octet_out_of_range");
            octets[i] = (byte) part;
        }
        InetAddress address = InetAddress.getByAddress(octets);
        if (!isTailscale(address)) throw new SecurityException("tailscale_only");
        return address;
    }

    private static boolean isTailscale(InetAddress address) {
        byte[] bytes = address.getAddress();
        return address instanceof Inet4Address && bytes.length == 4 && (bytes[0] & 255) == 100
                && (bytes[1] & 255) >= 64 && (bytes[1] & 255) <= 127;
    }

    static String canonicalId(String value) {
        if (value == null || !value.matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
                || !UUID.fromString(value).toString().equals(value)) throw new IllegalArgumentException("canonical_uuid_required");
        return value;
    }

    /** Actual Call state, not push delivery expiry, determines whether a JOIN can still answer. */
    static final class IncomingLifecycle {
        volatile String callId;
        volatile boolean ringing, answered, ended;
        synchronized void ring(String id) {
            if (callId != null) throw new IllegalStateException("one_original_call_per_session");
            callId = canonicalId(id); ringing = true;
        }
        synchronized String joinableId() { return ringing && !answered && !ended ? callId : null; }
        synchronized boolean answer() {
            if (joinableId() == null) return false;
            answered = true; ringing = false; return true;
        }
        synchronized boolean end() {
            if (callId == null || ended) return false;
            ended = true; ringing = false; return true;
        }
        byte[] idBytes() { return callId.getBytes(StandardCharsets.US_ASCII); }
    }

    /** Shared by the Android listener and the JVM localhost fixture; no Android or audio calls. */
    static final class Admission {
        final DataInputStream input;
        final DataOutputStream output;
        final String requestedId;
        final boolean accepted;
        final long nextInput, nextOutput;
        Admission(DataInputStream input, DataOutputStream output, String requestedId, boolean accepted, long rx, long tx) {
            this.input = input; this.output = output; this.requestedId = requestedId;
            this.accepted = accepted; nextInput = rx; nextOutput = tx;
        }
        static Admission initial(Socket candidate, byte[] key, byte[] token, Supplier<String> joinable) throws Exception {
            candidate.setTcpNoDelay(true);
            candidate.setSoTimeout(5000);
            DataInputStream input = new DataInputStream(candidate.getInputStream());
            DataOutputStream output = new DataOutputStream(candidate.getOutputStream());
            byte[] challenge = new byte[32]; new SecureRandom().nextBytes(challenge);
            byte[] expected = null;
            Frame auth = null, request = null;
            try {
                Protocol.write(output, new Frame(Protocol.CHALLENGE, 0, challenge));
                auth = Protocol.read(input, 0);
                expected = Protocol.auth(key, challenge);
                if (auth.type != Protocol.AUTH || !MessageDigest.isEqual(expected, auth.payload))
                    throw new SecurityException("authentication_failed");
                // Existing foreground clients wait for SESSION after AUTH. Wake clients send JOIN immediately.
                // The timeout is a handshake discriminator only; it never expires a ringing Call.
                candidate.setSoTimeout(250);
                int first;
                try { first = input.readUnsignedByte(); }
                catch (SocketTimeoutException foreground) { first = -1; }
                if (first != -1) {
                    candidate.setSoTimeout(5000);
                    request = Protocol.readAfterType(input, 1, first);
                    if (request.type != Protocol.JOIN) throw new SecurityException("initial_join_or_foreground_required");
                    String id = new String(request.payload, StandardCharsets.US_ASCII);
                    Protocol.write(output, new Frame(Protocol.JOIN, 1, request.payload));
                    if (!id.equals(joinable.get())) {
                        Protocol.write(output, new Frame(Protocol.STATE, 2, new byte[]{0}));
                        return new Admission(input, output, id, false, 2, 3);
                    }
                    Protocol.write(output, new Frame(Protocol.SESSION, 2, token));
                    Protocol.write(output, new Frame(Protocol.STATE, 3, new byte[]{1}));
                    candidate.setSoTimeout(0);
                    return new Admission(input, output, id, true, 2, 4);
                }
                Protocol.write(output, new Frame(Protocol.SESSION, 1, token));
                Protocol.write(output, new Frame(Protocol.STATE, 2, new byte[]{0}));
                candidate.setSoTimeout(0);
                return new Admission(input, output, null, true, 1, 3);
            } finally {
                Arrays.fill(challenge, (byte) 0);
                if (expected != null) Arrays.fill(expected, (byte) 0);
                if (auth != null) auth.clear();
                if (request != null) request.clear();
            }
        }
    }

    static URL validateProvider(String value) throws Exception {
        URL url = new URL(value);
        if (url.getUserInfo() != null || url.getQuery() != null || url.getRef() != null
                || !("https".equals(url.getProtocol()) || "http".equals(url.getProtocol())))
            throw new IllegalArgumentException("provider_http_url_required");
        if ("http".equals(url.getProtocol()) && !("127.0.0.1".equals(url.getHost()) || isTailscale(InetAddress.getByName(url.getHost()))))
            throw new SecurityException("cleartext_provider_requires_tailnet_or_loopback");
        return url;
    }

    /** Serial, bounded HTTP publisher. No contacts, numbers, audio, bridge key or session token leave here. */
    private static final class PushEvents implements AutoCloseable {
        final Config config;
        final ArrayDeque<String> events = new ArrayDeque<>();
        final Thread worker;
        volatile boolean closed;
        PushEvents(Config config) {
            this.config = config;
            worker = config.providerUrl == null ? null : daemon("bridge-push-events", this::publishLoop);
        }
        synchronized void publish(String callId, int revision, String state) {
            if (worker == null || closed) return;
            String stateValue = "ringing".equals(state) ? "ringing" : "ended";
            String event = "{\"pairing_id\":\"" + canonicalId(config.pairingId) + "\",\"call_id\":\""
                    + canonicalId(callId) + "\",\"revision\":" + revision + ",\"state\":\"" + stateValue + "\"}";
            events.addLast(event); notifyAll();
        }
        void publishLoop() {
            while (true) {
                String event;
                synchronized (this) {
                    while (events.isEmpty() && !closed) try { wait(); }
                    catch (InterruptedException done) { Thread.currentThread().interrupt(); return; }
                    if (events.isEmpty()) return;
                    event = events.removeFirst();
                }
                boolean sent = false;
                int status = 0, attempts = 0;
                String errorClass = "none";
                for (int attempt = 0; attempt < 3 && !sent; attempt++) {
                    attempts++;
                    HttpURLConnection connection = null;
                    byte[] body = event.getBytes(StandardCharsets.UTF_8);
                    try {
                        String base = config.providerUrl.replaceAll("/+$", "");
                        connection = (HttpURLConnection) new URL(base + "/v1/calls").openConnection();
                        connection.setInstanceFollowRedirects(false);
                        connection.setConnectTimeout(3000); connection.setReadTimeout(3000);
                        connection.setRequestMethod("POST"); connection.setDoOutput(true);
                        connection.setRequestProperty("Authorization", "Bearer " + config.providerToken);
                        connection.setRequestProperty("Content-Type", "application/json");
                        connection.setFixedLengthStreamingMode(body.length);
                        try (java.io.OutputStream output = connection.getOutputStream()) { output.write(body); }
                        status = connection.getResponseCode();
                        errorClass = "none";
                        sent = status >= 200 && status < 300;
                        if (!sent && status < 500) break;
                    } catch (Exception error) {
                        status = 0;
                        errorClass = error.getClass().getName();
                    }
                    finally { Arrays.fill(body, (byte) 0); if (connection != null) connection.disconnect(); }
                    if (!sent && attempt < 2) try { Thread.sleep(200 * (attempt + 1)); }
                    catch (InterruptedException done) { Thread.currentThread().interrupt(); return; }
                }
                if (config.bindAddress.isLoopbackAddress()) System.out.println("PJZ_LOCAL_PUSH accepted=" + sent);
                else emit("push_event_result", "accepted", sent, "http_status", status,
                        "attempts", attempts, "error_class", errorClass);
            }
        }
        @Override public synchronized void close() { closed = true; notifyAll(); /* Worker drains ordered events. */ }
    }

    /** Local-only fake original Call and synthetic PCM; shares production AUTH/JOIN and call lifetime logic. */
    static final class LocalFixture {
        static final String CALL_ID = "00000000-0000-4000-8000-000000000001";
        static void run(int port, String mode) throws Exception {
            if (!Arrays.asList("ringing", "ended", "mismatch", "foreground").contains(mode))
                throw new IllegalArgumentException("fixture_mode_invalid");
            byte[] key = new byte[32], token = new byte[32]; Arrays.fill(key, (byte) 0x5a); Arrays.fill(token, (byte) 0x6b);
            IncomingLifecycle call = new IncomingLifecycle();
            call.ring("mismatch".equals(mode) ? "00000000-0000-4000-8000-000000000002" : CALL_ID);
            if ("ended".equals(mode)) call.end();
            try (ServerSocket listener = new ServerSocket(port, 2, InetAddress.getByName("127.0.0.1"))) {
                listener.setSoTimeout(15000);
                System.out.println("PJZ_LOCAL_READY " + listener.getLocalPort()); System.out.flush();
                String fixtureProvider = System.getenv("CALLBRIDGE_FIXTURE_PROVIDER_URL");
                PushEvents publisher = null;
                if (fixtureProvider != null) {
                    URL fixtureURL = new URL(fixtureProvider);
                    if (!"http".equals(fixtureURL.getProtocol()) || !"127.0.0.1".equals(fixtureURL.getHost()))
                        throw new SecurityException("fixture_provider_loopback_required");
                    Config fixtureConfig = new Config(InetAddress.getByName("127.0.0.1"), port, key, true,
                            "00000000-0000-4000-8000-000000000010", fixtureProvider,
                            "5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a");
                    publisher = new PushEvents(fixtureConfig); publisher.publish(call.callId, 1, "ringing");
                }
                try (Socket socket = listener.accept()) {
                    Admission admission = Admission.initial(socket, key, token, call::joinableId);
                    if (!admission.accepted) {
                        if (call.answered) throw new AssertionError("unavailable_answered");
                        System.out.println("PASS local_join_unavailable no_session no_answer"); return;
                    }
                    long sequence = admission.nextOutput, expected = admission.nextInput;
                    if (admission.requestedId == null) {
                        Protocol.write(admission.output, new Frame(Protocol.JOIN, sequence++, call.idBytes()));
                        Protocol.write(admission.output, new Frame(Protocol.STATE, sequence++, new byte[]{1}));
                    }
                    socket.setSoTimeout(10000);
                    int answers = 0, uplink = 0, downlink = 0;
                    boolean active = false;
                    while (true) {
                        Frame frame = Protocol.read(admission.input, expected++);
                        try {
                            if (frame.type == Protocol.HEARTBEAT) continue;
                            if (frame.type == Protocol.ANSWER) {
                                if (frame.payload[0] != 1 || !call.answer() || ++answers != 1) throw new AssertionError("answer_once");
                                active = true;
                                Protocol.write(admission.output, new Frame(Protocol.STATE, sequence++, new byte[]{2}));
                                short[] samples = new short[SAMPLES];
                                for (int i = 0; i < samples.length; i++) samples[i] = (short) (500 * Math.sin(i * 0.1));
                                for (int i = 0; i < 12; i++) {
                                    Protocol.write(admission.output, new Frame(Protocol.DOWN_PCM, sequence++, Protocol.pcmBytes(samples))); downlink++;
                                }
                            } else if (frame.type == Protocol.UP_PCM && active) { uplink++; }
                            else if (frame.type == Protocol.HANGUP && active && MessageDigest.isEqual(token, frame.payload)) {
                                call.end(); Protocol.write(admission.output, new Frame(Protocol.STATE, sequence++, new byte[]{0})); break;
                            } else throw new AssertionError("fixture_client_state");
                        } finally { frame.clear(); }
                    }
                    if (answers != 1 || uplink == 0 || downlink != 12 || !call.ended) throw new AssertionError("fixture_audio_exchange");
                    System.out.println("PASS local_join actual_admission answer_once synthetic_pcm_both_directions hangup_idle_ack");
                    if (publisher != null) { publisher.publish(call.callId, 2, "ended"); publisher.close(); publisher.worker.join(10000); }
                }
            } finally { Arrays.fill(key, (byte) 0); Arrays.fill(token, (byte) 0); }
        }
    }

    /** Reuses the real framing/authentication, but never obtains Telecom or audio services. */
    private static final class Simulation implements AutoCloseable {
        final Config config;
        final AtomicBoolean stopped = new AtomicBoolean();
        final AtomicBoolean failed = new AtomicBoolean();
        final AtomicInteger state = new AtomicInteger();
        final AtomicInteger answers = new AtomicInteger();
        final AtomicLong upFrames = new AtomicLong();
        final Levels upLevels = new Levels();
        ServerSocket listener;
        Socket socket;
        Thread reader, deadline;
        long sequence;
        volatile long downFrames;
        volatile boolean ending;
        final boolean disconnectEarly;
        Simulation(Config config, boolean disconnectEarly) { this.config = config; this.disconnectEarly = disconnectEarly; }

        boolean run() throws Exception {
            listener = new ServerSocket();
            listener.setReuseAddress(false);
            listener.bind(new InetSocketAddress(config.bindAddress, config.port), 1);
            listener.setSoTimeout(30000);
            emit("simulation_listening", "real_call_control", false, "audio_opened", false);
            socket = listener.accept();
            listener.close(); listener = null;
            if (!isTailscale(socket.getInetAddress())) throw new SecurityException("tailscale_peer_required");
            socket.setTcpNoDelay(true);
            socket.setSoTimeout(5000);
            deadline = daemon("simulation-deadline", () -> {
                try { Thread.sleep(25000); }
                catch (InterruptedException done) { return; }
                failed.set(true); stopped.set(true);
                try { socket.close(); } catch (IOException ignored) { }
            });
            DataInputStream input = new DataInputStream(socket.getInputStream());
            DataOutputStream output = new DataOutputStream(socket.getOutputStream());
            byte[] challenge = new byte[32];
            new SecureRandom().nextBytes(challenge);
            byte[] expected = null;
            Frame auth = null;
            try {
                send(output, Protocol.CHALLENGE, challenge);
                auth = Protocol.read(input, 0);
                expected = Protocol.auth(config.key, challenge);
                if (auth.type != Protocol.AUTH || !MessageDigest.isEqual(auth.payload, expected))
                    throw new SecurityException("simulation_authentication_failed");
            } finally {
                Arrays.fill(challenge, (byte) 0);
                if (expected != null) Arrays.fill(expected, (byte) 0);
                if (auth != null) auth.clear();
            }
            socket.setSoTimeout(10000);
            send(output, Protocol.SIMULATION, Protocol.SIMULATION_LABEL);
            send(output, Protocol.STATE, new byte[]{0});
            reader = daemon("simulation-reader", () -> read(input));
            Thread.sleep(250);
            state.set(1);
            send(output, Protocol.STATE, new byte[]{1});
            long answerDeadline = now() + 5000;
            while (answers.get() == 0 && !stopped.get() && now() < answerDeadline) Thread.sleep(10);
            if (answers.get() != 1 || stopped.get()) throw new IllegalStateException("simulation_answer_not_received");
            state.set(2);
            send(output, Protocol.STATE, new byte[]{2});
            long started = now();
            short[] tone = new short[SAMPLES];
            try {
                // Short sound immediately on activation, then a second sound after startup settles.
                // These expose lost first-syllable audio instead of masking it with a continuous tone.
                for (int packet = 0; packet < (disconnectEarly ? 150 : 500) && !stopped.get(); packet++) {
                    boolean audible = packet < 15 || packet >= 150 && (packet / 25) % 2 == 0;
                    int frequency = packet < 15 ? 400 : 700;
                    for (int i = 0; i < SAMPLES; i++)
                        tone[i] = audible ? (short) Math.round(2000 * Math.sin(2 * Math.PI * frequency * i / RATE)) : 0;
                    byte[] pcm = Protocol.pcmBytes(tone);
                    try { send(output, Protocol.DOWN_PCM, pcm); downFrames++; }
                    finally { Arrays.fill(pcm, (byte) 0); }
                    if (packet % 100 == 99) send(output, Protocol.HEARTBEAT, new byte[0]);
                    long delay = started + (packet + 1) * 20 - now();
                    if (delay > 0) Thread.sleep(delay);
                }
            } finally { Arrays.fill(tone, (short) 0); }
            if (!stopped.get() && !disconnectEarly) {
                ending = true;
                send(output, Protocol.STATE, new byte[]{0});
                // Give the client its normal call-ended cleanup path before closing the socket.
                Thread.sleep(100);
            }
            boolean passed = !failed.get() && downFrames == (disconnectEarly ? 150 : 500)
                    && upFrames.get() >= (disconnectEarly ? 100 : 300) && answers.get() == 1;
            emit("simulation_result", "passed", passed, "answers", answers.get(), "down_frames", downFrames,
                    "up_frames", upFrames.get(), "up_nonzero_samples", upLevels.nonzero, "up_rms", upLevels.rms(),
                    "real_call_control", false, "audio_opened", false, "hearing_verified", false,
                    "forced_disconnect", disconnectEarly);
            return passed;
        }

        void read(DataInputStream input) {
            long expected = 1;
            short[] samples = new short[SAMPLES];
            try {
                while (!stopped.get()) {
                    Frame frame = Protocol.read(input, expected++);
                    try {
                        if (frame.type == Protocol.HEARTBEAT) { /* no echo */ }
                        else if (frame.type == Protocol.ANSWER && state.get() == 1 && answers.compareAndSet(0, 1)) { /* simulated only */ }
                        else if (frame.type == Protocol.UP_PCM && state.get() == 2) {
                            Protocol.pcmShorts(frame.payload, samples);
                            for (short sample : samples) upLevels.add(sample);
                            Arrays.fill(samples, (short) 0);
                            upFrames.incrementAndGet();
                        } else throw new SecurityException("simulation_client_state_or_direction_invalid");
                    } finally { frame.clear(); }
                }
            } catch (Throwable error) {
                // A normal client closes on the explicit idle frame after all 500 downlink frames.
                if (!stopped.get() && !(ending && (error instanceof java.io.EOFException || error instanceof java.net.SocketException))) {
                    failed.set(true); failure("simulation_receive_failed", error);
                }
                stopped.set(true);
            } finally { Arrays.fill(samples, (short) 0); }
        }
        void send(DataOutputStream output, int type, byte[] payload) throws IOException {
            Protocol.write(output, new Frame(type, sequence++, payload));
        }
        @Override public void close() throws Exception {
            stopped.set(true);
            if (deadline != null) deadline.interrupt();
            if (socket != null) socket.close();
            if (listener != null) listener.close();
            join(reader); join(deadline);
            emit("simulation_released", "socket_closed", true, "listener_closed", true);
        }
    }

    /** Clock supplied by caller; a normal connected call has no deadline. */
    static final class Recovery {
        static final long WINDOW_MS = 30000;
        long deadline;
        boolean ended;
        synchronized void lost(long time) { if (deadline == 0 && !ended) deadline = time + WINDOW_MS; }
        synchronized boolean expired(long time) { return deadline != 0 && time >= deadline; }
        synchronized boolean resumed(long time) {
            if (ended || deadline == 0 || expired(time)) return false;
            deadline = 0; return true;
        }
        synchronized boolean endOnce() { if (ended) return false; ended = true; return true; }
        static void selfTest() {
            IncomingLifecycle incoming = new IncomingLifecycle();
            incoming.ring("00000000-0000-4000-8000-000000000001");
            // No wall clock/transport TTL participates: a still ringing original remains JOIN-able.
            if (incoming.joinableId() == null || !incoming.answer() || incoming.answer()
                    || incoming.joinableId() != null || !incoming.end() || incoming.end())
                throw new AssertionError("original_call_lifetime_and_answer_once");
            Recovery value = new Recovery();
            if (value.expired(Long.MAX_VALUE)) throw new AssertionError("normal_call_deadline");
            value.lost(1000); value.lost(10000);
            if (value.deadline != 31000 || value.expired(30999) || !value.resumed(30999))
                throw new AssertionError("recovery_fixed_window");
            if (value.expired(Long.MAX_VALUE)) throw new AssertionError("resumed_call_deadline");
            value.lost(100000);
            if (!value.expired(130000) || value.resumed(130000) || !value.endOnce() || value.endOnce())
                throw new AssertionError("recovery_expiry_once");
        }
    }

    /** Shell-only Binder control of one exact Call object held by the minimal InCallService. */
    private static final class OwnedCallFailure extends IOException {
        final String reason;
        OwnedCallFailure(String reason, Throwable cause) { super(reason, cause); this.reason = reason; }
    }

    private static final class OwnedCall implements AutoCloseable {
        final IBinder owner = new Binder();
        final IBinder externalToken = new Binder();
        final String callId;
        final CountDownLatch initialState = new CountDownLatch(1);
        final AtomicBoolean closed = new AtomicBoolean();
        final int userId = Process.myUid() / 100000;
        volatile int state = -1;
        volatile IOException observationError;
        volatile IBinder control;
        Object activityManager;
        boolean providerAcquired;
        Thread observer;
        OwnedCall(Context context) throws Exception {
            String phase = "helper_provider_acquire_failed";
            try {
                // Same AMS external-provider entry used by Android's official shell content command.
                Class<?> api = Class.forName("android.app.IActivityManager");
                activityManager = Class.forName("android.app.ActivityManager").getMethod("getService").invoke(null);
                Object holder = api.getMethod("getContentProviderExternal", String.class, int.class, IBinder.class, String.class)
                        .invoke(activityManager, CallBridgeControl.AUTHORITY, userId, externalToken, "CallBridgeOwnedCall");
                if (holder == null) throw new OwnedCallFailure("helper_provider_unavailable", null);
                providerAcquired = true;
                Object provider = holder.getClass().getField("provider").get(holder);
                phase = "helper_control_acquire_failed";
                AttributionSource source = new AttributionSource.Builder(Process.myUid()).setPid(Process.myPid())
                        .setPackageName("com.android.shell").build();
                Bundle bootstrap = (Bundle) Class.forName("android.content.IContentProvider")
                        .getMethod("call", AttributionSource.class, String.class, String.class, String.class, Bundle.class)
                        .invoke(provider, source, CallBridgeControl.AUTHORITY, CallBridgeControl.METHOD_CONTROL, null, null);
                control = bootstrap == null ? null : bootstrap.getBinder(CallBridgeControl.BINDER_KEY);
                if (control == null || !CallBridgeControl.DESCRIPTOR.equals(control.getInterfaceDescriptor()))
                    throw new OwnedCallFailure("helper_control_unavailable", null);
                phase = "helper_binder_claim_failed";
                Parcel reply = request(CallBridgeControl.CLAIM);
                try {
                    String id = reply.readString();
                    int value = reply.readInt();
                    if (id == null) throw new OwnedCallFailure("helper_no_ringing_call", null);
                    callId = canonicalId(id);
                    state = checkedState(value);
                    initialState.countDown();
                } finally { reply.recycle(); }
            } catch (Exception error) {
                close();
                while (error instanceof InvocationTargetException && error.getCause() instanceof Exception)
                    error = (Exception) error.getCause();
                if (error instanceof OwnedCallFailure) throw error;
                throw new OwnedCallFailure(phase, error);
            }
            observer = daemon("bridge-original-call-observer", () -> {
                try {
                    while (!closed.get() && state != 0) {
                        int value = command(CallBridgeControl.STATE);
                        if (!closed.get()) state = value;
                        if (value == 0) return;
                        SystemClock.sleep(20);
                    }
                } catch (IOException ended) { observationError = ended; state = 0; }
            });
        }
        private static int checkedState(int value) throws IOException {
            if (value < 0 || value > 2) throw new IOException("owned_call_state_invalid");
            return value;
        }
        private Parcel request(int code) throws IOException {
            Parcel data = Parcel.obtain(), reply = Parcel.obtain();
            boolean success = false;
            try {
                IBinder binder = control;
                if (binder == null) throw new IOException("helper_binder_disconnected");
                data.writeInterfaceToken(CallBridgeControl.DESCRIPTOR);
                data.writeStrongBinder(owner);
                if (!binder.transact(code, data, reply, 0)) throw new IOException("helper_binder_transaction_unavailable");
                reply.readException(); success = true;
                return reply;
            } catch (Exception error) { throw new IOException("helper_binder_transaction_failed", error); }
            finally { data.recycle(); if (!success) reply.recycle(); }
        }
        private int command(int code) throws IOException {
            Parcel reply = request(code);
            try { return checkedState(reply.readInt()); }
            finally { reply.recycle(); }
        }
        void observeBeforeAnswer() throws Exception {
            if (!initialState.await(3, TimeUnit.SECONDS)) throw new OwnedCallFailure("helper_initial_state_timeout", null);
            if (state != 1) throw new OwnedCallFailure(observationError == null ? "helper_call_not_ringing" : "helper_initial_state_failed", observationError);
        }
        synchronized void answer() throws IOException {
            if (state != 1) throw new IOException("original_call_not_ringing");
            command(CallBridgeControl.ANSWER);
        }
        boolean active() { return state == 2; }
        synchronized void disconnect() throws IOException {
            if (active()) command(CallBridgeControl.DISCONNECT);
        }
        @Override public void close() {
            if (!closed.compareAndSet(false, true)) return;
            state = 0;
            try { if (control != null) command(CallBridgeControl.RELEASE); } catch (IOException ignored) { }
            if (providerAcquired) {
                providerAcquired = false;
                try {
                    Class.forName("android.app.IActivityManager")
                            .getMethod("removeContentProviderExternalAsUser", String.class, IBinder.class, int.class)
                            .invoke(activityManager, CallBridgeControl.AUTHORITY, externalToken, userId);
                } catch (Exception error) { failure("helper_provider_release_failed", error); }
            }
            join(observer);
        }
    }

    private static final class Session implements AutoCloseable {
        final Config config;
        final Context context;
        final AudioManager audio;
        final TelecomManager telecom;
        final AtomicBoolean stopped = new AtomicBoolean();
        final AtomicBoolean answerRequested = new AtomicBoolean();
        final AtomicBoolean hangupRequested = new AtomicBoolean();
        final AtomicBoolean transportLost = new AtomicBoolean();
        final Recovery recovery = new Recovery();
        final byte[] sessionToken = new byte[32];
        final AtomicInteger state = new AtomicInteger();
        final AtomicLong downSent = new AtomicLong();
        final AtomicLong upReceived = new AtomicLong();
        final Outbound outbound = new Outbound();
        final PcmQueue inbound = new PcmQueue();
        final Levels rxLevels = new Levels();
        final Levels txLevels = new Levels();
        final Object transportLock = new Object();
        final IncomingLifecycle incoming = new IncomingLifecycle();
        final PushEvents pushes;
        volatile String stopReason = "not_started";
        volatile String phase = "listen";
        volatile String endingReason;
        volatile Socket socket;
        OwnedCall ownedCall;
        ServerSocket listener;
        AudioRecord recorder;
        AudioTrack track;
        Thread reader;
        Thread writer;
        Thread resumeAcceptor;
        volatile Socket pendingResume;
        volatile Socket authenticatingResume;
        volatile long lastPeerFrame;
        FutureTask<Boolean> flagCheck;
        Thread flagThread;
        boolean ringSeen;
        volatile boolean answerAttempted;
        volatile boolean gate;
        long downQueued;
        long txSamples;
        long routeChecks;
        long lastHead;
        final Settings initialSettings;

        Session(Config config, Context context, AudioManager audio, TelecomManager telecom, ServerSocket listener) {
            this.config = config; this.context = context; this.audio = audio; this.telecom = telecom;
            this.listener = listener;
            initialSettings = new Settings(audio);
            pushes = new PushEvents(config);
            new SecureRandom().nextBytes(sessionToken);
        }

        void run() throws Exception {
            listener.setSoTimeout(250);
            resumeAcceptor = daemon("bridge-connection-listener", this::acceptResumes);
            emit("listening", "tailscale_only", true, "allow_answer", config.allowAnswer,
                    "observes_without_client", true);
            phase = "wait_new_call";
            long heartbeatAt = now() + 2000;
            String lastHelperFailure = null;
            while (!stopped.get()) {
                long time = now();
                if (time >= heartbeatAt) {
                    if (socket != null && !transportLost.get()) outbound.control(new Frame(Protocol.HEARTBEAT, 0, new byte[0]));
                    heartbeatAt = time + 2000;
                }
                boolean isRinging = ringing(telecom);
                boolean isActive = active(audio, telecom);
                if (isRinging) {
                    if (!ringSeen) {
                        OwnedCall observed = null;
                        try {
                            observed = new OwnedCall(context);
                            observed.observeBeforeAnswer();
                        } catch (OwnedCallFailure notReady) {
                            if (observed != null) observed.close();
                            String reason = notReady.reason + ":" + ioReason(notReady);
                            if (!reason.equals(lastHelperFailure)) {
                                failure("helper_waiting", notReady);
                                lastHelperFailure = reason;
                            }
                            SystemClock.sleep(20);
                            continue; // The real ringing state, not a readiness deadline, owns retries.
                        } catch (Exception error) {
                            if (observed != null) observed.close();
                            throw error;
                        }
                        if (!ringing(telecom)) { observed.close(); continue; }
                        lastHelperFailure = null;
                        synchronized (transportLock) {
                            ownedCall = observed;
                            incoming.ring(observed.callId);
                            ringSeen = true; state.set(1);
                            if (socket != null && !transportLost.get()) {
                                outbound.control(new Frame(Protocol.JOIN, 0, incoming.idBytes()));
                                outbound.control(new Frame(Protocol.STATE, 0, new byte[]{1}));
                            }
                        }
                        pushes.publish(observed.callId, 1, "ringing");
                        emit("new_ringing_call", "answer_enabled", config.allowAnswer, "original_call_observer_ready", true);
                    }
                    if (answerRequested.getAndSet(false)) {
                        if (!config.allowAnswer || answerAttempted || state.get() != 1)
                            throw new SecurityException("answer_not_authorized_now");
                        if (!ringing(telecom) || ownedCall == null || ownedCall.state != 1 || !incoming.answer()) {
                            finishRemoteCall("ringing_call_ended_before_answer"); return;
                        }
                        answerAttempted = true;
                        phase = "answer_ringing_call";
                        ownedCall.answer();
                        emit("answer_requested", "attempts", 1);
                        phase = "wait_new_call";
                    }
                } else if (answerRequested.getAndSet(false)) {
                    finishRemoteCall("ringing_call_ended_before_answer"); return;
                }
                if (isActive) {
                    if (ringSeen && !answerAttempted) { finishRemoteCall("answered_on_phone"); return; }
                    if (ownedCall != null && ownedCall.active()) { live(); return; }
                }
                if (ringSeen && ownedCall != null && ownedCall.state == 0) { finishRemoteCall("ringing_call_ended"); return; }
                // Local calls and Telecom/audio state transitions are observed, never adopted or controlled.
                if (!isRinging && !ringSeen) lastHelperFailure = null;
                SystemClock.sleep(10);
            }
        }

        String joinableCall() {
            OwnedCall original = ownedCall;
            return original != null && original.state == 1 && !answerAttempted ? incoming.joinableId() : null;
        }

        void attachInitial(Socket candidate) throws Exception {
            Admission admitted = Admission.initial(candidate, config.key, sessionToken, this::joinableCall);
            if (!admitted.accepted) return;
            synchronized (transportLock) {
                // The original Call may finish while the handshake is in flight; ANSWER rechecks its object/state.
                Socket previous = socket;
                socket = null;
                if (previous != null) previous.close();
                outbound.close(); inbound.close(); join(reader); join(writer);
                outbound.reset(); inbound.reset();
                socket = candidate; lastPeerFrame = now(); transportLost.set(false);
                state.set(ringSeen ? 1 : 0);
                if (admitted.requestedId == null && incoming.joinableId() != null) {
                    outbound.control(new Frame(Protocol.JOIN, 0, incoming.idBytes()));
                    outbound.control(new Frame(Protocol.STATE, 0, new byte[]{1}));
                }
                writer = daemon("bridge-network-writer", () -> writeLoop(admitted.output, candidate, admitted.nextOutput));
                reader = daemon("bridge-network-reader", () -> readLoop(admitted.input, candidate, admitted.nextInput));
            }
        }

        void authenticate(Socket candidate, boolean resume) throws Exception {
            if (!isTailscale(candidate.getInetAddress())) throw new SecurityException("tailscale_peer_required");
            candidate.setTcpNoDelay(true);
            candidate.setSendBufferSize(8192);
            candidate.setReceiveBufferSize(8192);
            candidate.setSoTimeout(resume ? (int) Math.max(1, recovery.deadline - now()) : 0);
            phase = "authenticate";
            DataInputStream input = new DataInputStream(candidate.getInputStream());
            DataOutputStream output = new DataOutputStream(candidate.getOutputStream());
            byte[] challenge = new byte[32];
            new SecureRandom().nextBytes(challenge);
            Frame auth = null;
            byte[] expected = null;
            try {
                Protocol.write(output, new Frame(Protocol.CHALLENGE, 0, challenge));
                auth = Protocol.read(input, 0);
                expected = Protocol.auth(config.key, challenge);
                if (auth.type != Protocol.AUTH || !MessageDigest.isEqual(expected, auth.payload))
                    throw new SecurityException("authentication_failed");
                if (resume) {
                    Frame request = Protocol.read(input, 1);
                    try {
                        if (request.type != Protocol.RESUME || !MessageDigest.isEqual(sessionToken, request.payload)
                                || !ownedActive() || recovery.expired(now()))
                            throw new SecurityException("same_owned_call_resume_required");
                    } finally { request.clear(); }
                }
            } finally {
                Arrays.fill(challenge, (byte) 0);
                if (auth != null) auth.clear();
                if (expected != null) Arrays.fill(expected, (byte) 0);
            }
            attachAuthenticated(candidate, resume);
        }

        void attachAuthenticated(Socket candidate, boolean resume) throws Exception {
            if (!resume) requireIdle(audio, telecom);
            DataOutputStream output = new DataOutputStream(candidate.getOutputStream());
            DataInputStream input = new DataInputStream(candidate.getInputStream());
            candidate.setSoTimeout(0);
            Protocol.write(output, new Frame(Protocol.SESSION, 1, sessionToken));
            Protocol.write(output, new Frame(Protocol.STATE, 2, new byte[]{(byte) (resume ? 2 : 0)}));
            if (resume && !recovery.resumed(now())) throw new IOException("recovery_expired");
            socket = candidate;
            lastPeerFrame = now();
            transportLost.set(false);
            outbound.reset(); inbound.reset();
            state.set(resume ? 2 : 0);
            emit(resume ? "session_resumed" : "authenticated", "audio_opened", resume, "state", resume ? "active" : "idle", "answer_repeated", false);
            writer = daemon("bridge-network-writer", () -> writeLoop(output, candidate));
            reader = daemon("bridge-network-reader", () -> readLoop(input, candidate, resume ? 2 : 1));
        }

        void acceptResumes() {
            while (!stopped.get()) {
                Socket candidate = null;
                try {
                    candidate = listener.accept();
                    authenticatingResume = candidate;
                    if (!isTailscale(candidate.getInetAddress())) throw new SecurityException("tailscale_peer_required");
                    candidate.setTcpNoDelay(true);
                    if (!answerAttempted) {
                        attachInitial(candidate);
                        if (socket == candidate) candidate = null;
                        continue;
                    }
                    if (!ownedActive() || state.get() != 2) throw new SecurityException("resume_only_owned_active_call");
                    long expiry = recovery.deadline == 0 ? now() + Recovery.WINDOW_MS : recovery.deadline;
                    candidate.setSoTimeout((int) Math.max(1, expiry - now()));
                    Protocol.verifyResume(candidate, config.key, sessionToken);
                    if (!ownedActive() || recovery.expired(now())) throw new SecurityException("original_call_no_longer_resumable");
                    Socket old = socket;
                    loseTransport(old, "authenticated_resume_takeover", new IOException());
                    if (!transportLost.get() || pendingResume != null) throw new IOException("resume_not_available");
                    pendingResume = candidate;
                    candidate = null;
                    while (pendingResume != null && !stopped.get()) SystemClock.sleep(5);
                } catch (SocketTimeoutException expected) { }
                catch (Throwable error) { if (!stopped.get()) failure("connection_attempt_failed", error); }
                finally {
                    authenticatingResume = null;
                    if (candidate != null) try { candidate.close(); } catch (IOException ignored) { }
                }
            }
        }

        boolean ownedActive() { return answerAttempted && ownedCall != null && ownedCall.active() && active(audio, telecom); }

        void endOwnedCall(String reason) throws Exception {
            if (ownedActive() && recovery.endOnce()) {
                ownedCall.disconnect();
                emit("owned_hangup_requested", "reason", reason, "exact_call_object", true, "attempts", 1);
                long observeUntil = now() + 2000;
                while (ownedCall.active() && now() < observeUntil) SystemClock.sleep(10);
            }
            finishRemoteCall(reason);
        }

        void finishRemoteCall(String reason) {
            if (ringSeen && incoming.end()) pushes.publish(incoming.callId, 2, "ended");
            endingReason = reason;
            if (!transportLost.get() && socket != null) {
                try { outbound.control(new Frame(Protocol.STATE, 0, new byte[]{0})); join(writer); }
                catch (Throwable error) { failure("end_state_delivery_failed", error); }
            }
            stop(reason);
        }

        void loseTransport(Socket failed, String reason, Throwable error) {
            if (socket != failed || stopped.get()) return;
            if (ownedActive()) {
                state.set(2);
                if (transportLost.compareAndSet(false, true)) {
                    recovery.lost(now());
                    failure(reason, error);
                    emit("recovering", "window_ms", Recovery.WINDOW_MS, "original_call_retained", true);
                    try { if (failed != null) failed.close(); } catch (IOException ignored) { }
                    outbound.close(); inbound.close();
                }
            } else {
                // A locked or suspended iPhone is expected before ANSWER. Keep observing the same Call.
                synchronized (transportLock) {
                    if (socket != failed) return;
                    socket = null;
                    try { if (failed != null) failed.close(); } catch (IOException ignored) { }
                    outbound.close(); inbound.close(); answerRequested.set(false);
                    emit("preanswer_transport_detached", "original_call_retained", ringSeen);
                }
            }
        }

        boolean recoverTransport() throws Exception {
            join(reader); join(writer);
            reader = null; writer = null;
            while (!stopped.get() && ownedActive()) {
                if (recovery.expired(now())) { endOwnedCall("recovery_expired"); return false; }
                Socket candidate = pendingResume;
                if (candidate != null) {
                    try { attachAuthenticated(candidate, true); return true; }
                    catch (Throwable error) {
                        failure("resume_attach_failed", error);
                        try { candidate.close(); } catch (IOException ignored) { }
                    } finally { pendingResume = null; }
                }
                SystemClock.sleep(5);
            }
            finishRemoteCall("original_call_ended_during_recovery");
            return false;
        }

        void openAudio() throws Exception {
            phase = "audio_initialize";
            AudioDeviceInfo rxDevice = telephonyDevice(audio, true);
            AudioDeviceInfo txDevice = telephonyDevice(audio, false);
            if (rxDevice == null || txDevice == null) throw new IllegalStateException("telephony_devices_required");
            int rxMin = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
            int txMin = AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT);
            if (rxMin <= 0 || txMin <= 0) throw new IllegalStateException("pcm16_16k_required");
            recorder = new AudioRecord.Builder().setContext(context).setAudioSource(MediaRecorder.AudioSource.VOICE_DOWNLINK)
                    .setAudioFormat(new AudioFormat.Builder().setSampleRate(RATE).setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build()).setBufferSizeInBytes(Math.max(rxMin, RATE / 5)).build();
            track = new AudioTrack.Builder().setContext(context).setAudioAttributes(attributes())
                    .setAudioFormat(new AudioFormat.Builder().setSampleRate(RATE).setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                    .setBufferSizeInBytes(Math.max(txMin, RATE / 5)).setTransferMode(AudioTrack.MODE_STREAM).build();
            boolean rxPreferred = recorder.setPreferredDevice(rxDevice);
            boolean txPreferred = track.setPreferredDevice(txDevice);
            emit("initialized", "rx_ok", recorder.getState() == AudioRecord.STATE_INITIALIZED,
                    "tx_ok", track.getState() == AudioTrack.STATE_INITIALIZED, "rx_rate", recorder.getSampleRate(),
                    "tx_rate", track.getSampleRate(), "rx_source", recorder.getAudioSource(),
                    "rx_preferred_telephony", rxPreferred, "tx_preferred_telephony", txPreferred,
                    "rx_buffer_frames", recorder.getBufferSizeInFrames(), "tx_buffer_frames", track.getBufferSizeInFrames());
            if (recorder.getState() != AudioRecord.STATE_INITIALIZED || track.getState() != AudioTrack.STATE_INITIALIZED
                    || recorder.getSampleRate() != RATE || track.getSampleRate() != RATE
                    || recorder.getAudioSource() != MediaRecorder.AudioSource.VOICE_DOWNLINK || !rxPreferred || !txPreferred)
                throw new IllegalStateException("audio_initialization_gate_failed");
            if (stopped.get() || !active(audio, telecom)) throw new IllegalStateException("call_ended_before_audio_start");
            phase = "audio_start";
            recorder.startRecording();
            track.play();
            emit("started", "rx_recording", recorder.getRecordingState() == AudioRecord.RECORDSTATE_RECORDING,
                    "tx_playing", track.getPlayState() == AudioTrack.PLAYSTATE_PLAYING, "tx_digital_silence_only", true);
            if (recorder.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING || track.getPlayState() != AudioTrack.PLAYSTATE_PLAYING)
                throw new IllegalStateException("audio_start_gate_failed");
        }

        void live() throws Exception {
            long callStart = now();
            openAudio();
            short[] rx = new short[SAMPLES];
            short[] tx = new short[SAMPLES];
            int rxOffset = 0;
            int txOffset = 0;
            boolean txPrepared = false;
            long heartbeatAt = now() + 2000;
            long reportAt = now() + 5000;
            long nextFlagAt = callStart + 500;
            boolean reportedRouteWait = false;
            try {
                while (!stopped.get() && active(audio, telecom)) {
                    if (!ownedActive()) { finishRemoteCall("original_call_ended"); break; }
                    if (hangupRequested.get()) { endOwnedCall("explicit_hangup"); break; }
                    if (!transportLost.get() && now() - lastPeerFrame >= 4000) {
                        // Two missing 2-second peer heartbeats start the approved recovery
                        // window; its deadline remains last valid frame + 30 seconds.
                        recovery.lost(lastPeerFrame);
                        loseTransport(socket, "peer_heartbeat_lost", new IOException());
                    }
                    if (transportLost.get()) {
                        gate = false;
                        releaseAudio();
                        Arrays.fill(rx, (short) 0); Arrays.fill(tx, (short) 0);
                        rxOffset = 0; txOffset = 0; txPrepared = false;
                        if (!recoverTransport()) return;
                        openAudio();
                        nextFlagAt = now() + 500; reportedRouteWait = false;
                        heartbeatAt = now() + 2000; reportAt = now() + 5000;
                    }
                    phase = "route_validation";
                    long time = now();
                    if (time >= heartbeatAt) { outbound.control(new Frame(Protocol.HEARTBEAT, 0, new byte[0])); heartbeatAt = time + 2000; }
                    if (ringing(telecom)) throw new IllegalStateException("new_ringing_or_call_waiting_stopped");
                    AudioDeviceInfo rxRoute = recorder.getRoutedDevice();
                    AudioDeviceInfo txRoute = track.getRoutedDevice();
                    boolean rxOk = rxRoute != null && rxRoute.getType() == AudioDeviceInfo.TYPE_TELEPHONY;
                    boolean txOk = txRoute != null && txRoute.getType() == AudioDeviceInfo.TYPE_TELEPHONY;
                    if ((rxRoute != null && !rxOk) || (txRoute != null && !txOk) || (gate && (!rxOk || !txOk)))
                        throw new IllegalStateException("telephony_route_lost");
                    if (!gate && !reportedRouteWait) {
                        emit("route_waiting", "rx_telephony", rxOk, "tx_telephony", txOk);
                        reportedRouteWait = true;
                    }
                    if (rxOk && txOk && flagCheck == null && time >= nextFlagAt) {
                        final int sessionId = track.getAudioSessionId();
                        flagCheck = new FutureTask<>(() -> verifyIncallOutput(sessionId));
                        flagThread = daemon("bridge-output-gate", flagCheck);
                    }
                    if (flagCheck != null && flagCheck.isDone()) {
                        if (!flagCheck.get()) throw new IllegalStateException("incall_music_output_not_verified");
                        flagCheck = null; flagThread = null; routeChecks++; nextFlagAt = time + 2000;
                        if (!gate) {
                            if (!active(audio, telecom) || stopped.get() || !rxOk || !txOk)
                                throw new IllegalStateException("call_or_route_changed_before_activation");
                            gate = true; state.set(2);
                            outbound.control(new Frame(Protocol.STATE, 0, new byte[]{2}));
                            emit("active", "rx_type", rxRoute.getType(), "tx_type", txRoute.getType(),
                                    "incall_music_verified", true, "audio_session", track.getAudioSessionId());
                        }
                    }
                    // Never reads a fallback microphone. No RX is uploaded before both route gates pass.
                    if (gate) {
                        phase = "rx_pcm";
                        int count = recorder.read(rx, rxOffset, SAMPLES - rxOffset, AudioRecord.READ_NON_BLOCKING);
                        if (count < 0) throw new IllegalStateException("rx_read_failed");
                        for (int i = rxOffset; i < rxOffset + count; i++) rxLevels.add(rx[i]);
                        rxOffset += count;
                        if (rxOffset == SAMPLES) {
                            byte[] pcm = Protocol.pcmBytes(rx);
                            outbound.pcm(new Frame(Protocol.DOWN_PCM, 0, pcm));
                            downQueued++; rxOffset = 0; Arrays.fill(rx, (short) 0);
                        }
                    }
                    if (!txPrepared) {
                        Arrays.fill(tx, (short) 0);
                        byte[] pcm = gate ? inbound.take() : null;
                        if (pcm != null) {
                            try { Protocol.pcmShorts(pcm, tx); }
                            finally { Arrays.fill(pcm, (byte) 0); }
                        }
                        txPrepared = true;
                    }
                    phase = "tx_pcm";
                    int written = track.write(tx, txOffset, SAMPLES - txOffset, AudioTrack.WRITE_NON_BLOCKING);
                    if (written < 0) throw new IllegalStateException("tx_write_failed");
                    for (int i = txOffset; i < txOffset + written; i++) txLevels.add(tx[i]);
                    txSamples += written; txOffset += written;
                    if (txOffset == SAMPLES) { txOffset = 0; txPrepared = false; Arrays.fill(tx, (short) 0); }
                    lastHead = Integer.toUnsignedLong(track.getPlaybackHeadPosition());
                    if (time >= reportAt) { levels("levels"); reportAt = time + 5000; }
                    phase = "phone_state";
                    SystemClock.sleep(5);
                }
                if (!stopped.get()) finishRemoteCall("call_ended");
            } finally {
                state.set(0); gate = false;
                Arrays.fill(rx, (short) 0); Arrays.fill(tx, (short) 0);
                stop(stopReason.equals("not_started") ? "audio_loop_exited" : stopReason);
                releaseAudio();
            }
        }

        void readLoop(DataInputStream input, Socket transport, long sequence) {
            try {
                while (!stopped.get() && socket == transport && !transportLost.get()) {
                    Frame frame = Protocol.read(input, sequence++);
                    try {
                        if (socket != transport || transportLost.get()) continue;
                        lastPeerFrame = now();
                        if (frame.type == Protocol.HEARTBEAT) { /* no echo */ }
                        else if (frame.type == Protocol.UP_PCM) {
                            if (state.get() != 2) throw new SecurityException("pcm_before_active");
                            if (!gate) continue; // Reopened audio must pass its route gate again.
                            inbound.offer(frame.payload); frame.payload = null; upReceived.incrementAndGet();
                        } else if (frame.type == Protocol.ANSWER) {
                            if (!config.allowAnswer || state.get() != 1 || answerAttempted || !answerRequested.compareAndSet(false, true))
                                throw new SecurityException("answer_not_authorized");
                        } else if (frame.type == Protocol.HANGUP) {
                            if (!answerAttempted || state.get() != 2 || !MessageDigest.isEqual(sessionToken, frame.payload))
                                throw new SecurityException("owned_call_hangup_required");
                            hangupRequested.set(true); // Duplicate requests have one main-loop effect.
                        } else throw new SecurityException("client_direction_or_type_invalid");
                    } finally { frame.clear(); }
                }
            } catch (Throwable error) { if (!stopped.get()) loseTransport(transport, "receive_failed", error); }
        }

        void writeLoop(DataOutputStream output, Socket transport) { writeLoop(output, transport, 3); }

        void writeLoop(DataOutputStream output, Socket transport, long sequence) {
            try {
                while (!stopped.get() && socket == transport && !transportLost.get()) {
                    Frame frame = outbound.take();
                    if (frame == null) continue;
                    try {
                        if (frame.type == Protocol.DOWN_PCM && state.get() != 2) continue;
                        frame.sequence = sequence++;
                        Protocol.write(output, frame);
                        if (frame.type == Protocol.DOWN_PCM) downSent.incrementAndGet();
                        if (frame.type == Protocol.STATE && frame.payload[0] == 0 && endingReason != null) {
                            stop(endingReason); return;
                        }
                    } finally { frame.clear(); }
                }
            } catch (Throwable error) { if (!stopped.get()) loseTransport(transport, "send_failed", error); }
        }

        void stop(String reason) {
            if (stopped.compareAndSet(false, true)) {
                stopReason = reason;
                state.set(0);
                Socket value = socket;
                if (value != null) try { value.close(); } catch (IOException ignored) { }
                outbound.close(); inbound.close();
            }
        }

        void releaseAudio() {
            if (recorder != null) {
                try { recorder.stop(); } catch (RuntimeException ignored) { }
                recorder.release(); recorder = null;
            }
            if (track != null) {
                try { track.stop(); } catch (RuntimeException ignored) { }
                track.release(); track = null;
            }
        }

        void levels(String stage) {
            emit(stage, "rx_samples", rxLevels.samples, "rx_nonzero", rxLevels.nonzero, "rx_peak", rxLevels.peak,
                    "rx_rms", rxLevels.rms(), "tx_samples", txSamples, "tx_nonzero", txLevels.nonzero,
                    "tx_peak", txLevels.peak, "tx_rms", txLevels.rms(), "tx_head_frames", lastHead,
                    "down_frames_queued", downQueued, "down_frames_sent", downSent.get(), "up_frames_received", upReceived.get(),
                    "down_queue_dropped", outbound.dropped, "up_queue_dropped", inbound.dropped, "route_checks", routeChecks);
        }

        boolean completedAudioExchange() {
            return "call_ended".equals(stopReason)
                    && routeChecks > 0 && downSent.get() > 0 && upReceived.get() > 0;
        }

        @Override public void close() {
            stop(stopReason.equals("not_started") ? "closed" : stopReason);
            if (authenticatingResume != null) try { authenticatingResume.close(); } catch (IOException ignored) { }
            if (pendingResume != null) try { pendingResume.close(); } catch (IOException ignored) { }
            if (flagCheck != null) flagCheck.cancel(true);
            releaseAudio();
            if (ownedCall != null) {
                if (ownedCall.state == 0 && incoming.end()) pushes.publish(incoming.callId, 2, "ended");
                ownedCall.close();
            }
            pushes.close();
            Arrays.fill(sessionToken, (byte) 0);
            join(reader); join(writer); join(flagThread); join(resumeAcceptor);
            levels("summary");
            emit("exit_diagnostics", "stop_reason", stopReason, "answer_attempts", answerAttempted ? 1 : 0,
                    "pcm_buffers_cleared", true, "threads_closed", (reader == null || !reader.isAlive()) && (writer == null || !writer.isAlive())
                            && (flagThread == null || !flagThread.isAlive()),
                    "call_still_active", active(audio, telecom), "owned_hangup_attempted", recovery.ended);
            initialSettings.compare(audio);
        }
    }

    private static final class Outbound {
        private final ArrayDeque<Frame> controls = new ArrayDeque<>();
        private final ArrayDeque<Frame> pcm = new ArrayDeque<>();
        private boolean closed;
        volatile long dropped;
        synchronized void control(Frame frame) throws IOException {
            if (closed) { frame.clear(); return; }
            if (controls.size() >= 8) { frame.clear(); throw new IOException("control_queue_full"); }
            controls.addLast(frame); notifyAll();
        }
        synchronized void pcm(Frame frame) {
            if (closed) { frame.clear(); return; }
            if (pcm.size() == MAX_PCM_QUEUE) { pcm.removeFirst().clear(); dropped++; }
            pcm.addLast(frame); notifyAll();
        }
        synchronized Frame take() throws InterruptedException {
            if (!closed && controls.isEmpty() && pcm.isEmpty()) wait(100);
            return !controls.isEmpty() ? controls.pollFirst() : pcm.pollFirst();
        }
        synchronized void close() {
            closed = true;
            for (Frame frame : controls) frame.clear();
            for (Frame frame : pcm) frame.clear();
            controls.clear(); pcm.clear(); notifyAll();
        }
        synchronized void reset() { close(); closed = false; }
    }

    private static final class PcmQueue {
        private final ArrayDeque<byte[]> values = new ArrayDeque<>();
        private boolean closed;
        volatile long dropped;
        synchronized void offer(byte[] pcm) {
            if (closed) { Arrays.fill(pcm, (byte) 0); return; }
            if (values.size() == MAX_PCM_QUEUE) { Arrays.fill(values.removeFirst(), (byte) 0); dropped++; }
            values.addLast(pcm);
        }
        synchronized byte[] take() { return values.pollFirst(); }
        synchronized void close() {
            closed = true;
            for (byte[] pcm : values) Arrays.fill(pcm, (byte) 0);
            values.clear();
        }
        synchronized void reset() { close(); closed = false; }
    }

    private static AudioDeviceInfo telephonyDevice(AudioManager audio, boolean input) {
        for (AudioDeviceInfo device : audio.getDevices(input ? AudioManager.GET_DEVICES_INPUTS : AudioManager.GET_DEVICES_OUTPUTS))
            if (device.getType() == AudioDeviceInfo.TYPE_TELEPHONY) return device;
        return null;
    }

    /** Runs off the phone-state loop and only returns this PID/session's metadata. */
    private static boolean verifyIncallOutput(int session) {
        java.lang.Process diagnostic = null;
        try {
            String command = "/system/bin/dumpsys media.audio_flinger | /system/bin/awk '" + outputFilter(Process.myPid(), session) + "'";
            diagnostic = new ProcessBuilder("/system/bin/sh", "-c", command).start();
            // This worker is cancelled by call/socket cleanup, not by an experimental timer.
            diagnostic.waitFor();
            byte[] buffer = new byte[1024];
            int count = diagnostic.getInputStream().read(buffer);
            if (count <= 0 || diagnostic.exitValue() != 0) return false;
            String filtered = new String(buffer, 0, count, StandardCharsets.UTF_8);
            for (String line : filtered.split("\\n")) {
                String[] fields = line.trim().split("\\s+");
                if (fields.length != 2 || !fields[0].matches("0x[0-9a-fA-F]+|[0-9]+") || !fields[1].matches("[0-9]+")) continue;
                long flags = Long.decode(fields[0]);
                long writes = Long.parseLong(fields[1]);
                boolean verified = (flags & 0x10000) != 0 && writes > 0;
                emit("native_tx_output", "session", session, "output_flags", flags, "total_writes", writes, "incall_music", verified);
                if (verified) return true;
            }
            return false;
        } catch (Exception error) { failure("output_gate_failed", error); return false; }
        finally { if (diagnostic != null) diagnostic.destroyForcibly(); }
    }

    private static String outputFilter(int pid, int session) {
        String client = pid + "[[:space:]]*\\/[[:space:]]*2000[[:space:]]+" + session + "[[:space:]]";
        return "/^(Output|Input) thread / {flags=\"\"; writes=0; current=0} "
                + "/^[[:space:]]*Total writes:/ {writes=$3} "
                + "/AudioStreamOut:.* flags / {for(i=1;i<=NF;i++) if($i==\"flags\") flags=$(i+1)} "
                + "/^[[:space:]]*[0-9]+ Tracks/ {current=1} "
                + "/^[[:space:]]*([0-9]+ Effect Chains|Local log:|Orphan Effect Chains)/ {current=0} "
                + "/" + client + "/ && current && flags!=\"\" {print flags, writes}";
    }

    static final class Frame {
        final int type;
        long sequence;
        byte[] payload;
        Frame(int type, long sequence, byte[] payload) { this.type = type; this.sequence = sequence; this.payload = payload; }
        void clear() { if (payload != null) Arrays.fill(payload, (byte) 0); payload = null; }
    }

    /** Pure JVM protocol implementation; no Android calls, sockets or audio in selfTest. */
    static final class Protocol {
        static final int CHALLENGE = 1, AUTH = 2, DOWN_PCM = 0x10, UP_PCM = 0x11,
                STATE = 0x20, SESSION = 0x21, ANSWER = 0x30, RESUME = 0x31, HANGUP = 0x32, JOIN = 0x33,
                HEARTBEAT = 0x40, SIMULATION = 0x50;
        static final byte[] LABEL = "PJZ-CALL/1".getBytes(StandardCharsets.UTF_8);
        static final byte[] SIMULATION_LABEL = "PJZ-SIMULATION/1".getBytes(StandardCharsets.UTF_8);
        static Frame read(DataInputStream input, long expectedSequence) throws IOException {
            return readAfterType(input, expectedSequence, input.readUnsignedByte());
        }
        static Frame readAfterType(DataInputStream input, long expectedSequence, int type) throws IOException {
            int reserved = input.readUnsignedByte();
            int length = input.readUnsignedShort();
            long sequence = Integer.toUnsignedLong(input.readInt());
            if (reserved != 0 || expectedSequence < 0 || expectedSequence > 0xffffffffL || sequence != expectedSequence)
                throw new IOException("frame_header_or_sequence_invalid");
            validateLength(type, length);
            byte[] payload = new byte[length];
            boolean valid = false;
            try {
                input.readFully(payload);
                validatePayload(type, payload);
                valid = true;
                return new Frame(type, sequence, payload);
            } finally { if (!valid) Arrays.fill(payload, (byte) 0); }
        }
        static void write(DataOutputStream output, Frame frame) throws IOException {
            if (frame.sequence < 0 || frame.sequence > 0xffffffffL || frame.payload == null)
                throw new IOException("frame_sequence_or_payload_invalid");
            validateLength(frame.type, frame.payload.length);
            validatePayload(frame.type, frame.payload);
            output.writeByte(frame.type); output.writeByte(0); output.writeShort(frame.payload.length);
            output.writeInt((int) frame.sequence); output.write(frame.payload); output.flush();
        }
        static void validateLength(int type, int length) throws IOException {
            if (length > 1024 || !((type == CHALLENGE || type == AUTH || type == SESSION || type == RESUME || type == HANGUP) && length == 32
                    || (type == DOWN_PCM || type == UP_PCM) && length == PCM_BYTES
                    || (type == STATE || type == ANSWER) && length == 1 || type == HEARTBEAT && length == 0
                    || type == JOIN && length == 36 || type == SIMULATION && length == SIMULATION_LABEL.length))
                throw new IOException("frame_type_or_length_invalid");
        }
        static void validatePayload(int type, byte[] payload) throws IOException {
            if (type == JOIN) {
                try { canonicalId(new String(payload, StandardCharsets.US_ASCII)); }
                catch (IllegalArgumentException invalid) { throw new IOException("canonical_call_uuid_required"); }
            }
            if (type == STATE && (payload[0] < 0 || payload[0] > 2) || type == ANSWER && payload[0] != 1)
                throw new IOException("control_payload_invalid");
            if (type == SIMULATION && !MessageDigest.isEqual(payload, SIMULATION_LABEL))
                throw new IOException("simulation_marker_invalid");
        }
        static byte[] decodeKey(String value) {
            if (value == null || !value.matches("[a-fA-F0-9]{64}")) throw new IllegalArgumentException("pairing_key_256bit_hex_required");
            byte[] result = new byte[32];
            for (int i = 0; i < result.length; i++) result[i] = (byte) Integer.parseInt(value.substring(i * 2, i * 2 + 2), 16);
            return result;
        }
        static byte[] auth(byte[] key, byte[] challenge) throws Exception {
            if (key.length != 32 || challenge.length != 32) throw new IllegalArgumentException("auth_size_invalid");
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(key, "HmacSHA256"));
            mac.update(LABEL);
            return mac.doFinal(challenge);
        }
        static void verifyResume(Socket socket, byte[] key, byte[] token) throws Exception {
            DataInputStream input = new DataInputStream(socket.getInputStream());
            DataOutputStream output = new DataOutputStream(socket.getOutputStream());
            byte[] challenge = new byte[32];
            new SecureRandom().nextBytes(challenge);
            Frame authentication = null, resume = null;
            byte[] expected = null;
            try {
                write(output, new Frame(CHALLENGE, 0, challenge));
                authentication = read(input, 0);
                expected = auth(key, challenge);
                if (authentication.type != AUTH || !MessageDigest.isEqual(expected, authentication.payload))
                    throw new SecurityException("resume_authentication_failed");
                resume = read(input, 1);
                if (resume.type != RESUME || !MessageDigest.isEqual(token, resume.payload))
                    throw new SecurityException("same_session_token_required");
            } finally {
                Arrays.fill(challenge, (byte) 0);
                if (authentication != null) authentication.clear();
                if (resume != null) resume.clear();
                if (expected != null) Arrays.fill(expected, (byte) 0);
            }
        }
        static byte[] pcmBytes(short[] values) {
            byte[] bytes = new byte[PCM_BYTES];
            for (int i = 0; i < SAMPLES; i++) { bytes[2 * i] = (byte) values[i]; bytes[2 * i + 1] = (byte) (values[i] >>> 8); }
            return bytes;
        }
        static void pcmShorts(byte[] bytes, short[] values) {
            for (int i = 0; i < SAMPLES; i++) values[i] = (short) ((bytes[2 * i] & 255) | ((bytes[2 * i + 1] & 255) << 8));
        }
        static void selfTest() throws Exception {
            byte[] key = new byte[32]; byte[] challenge = new byte[32];
            for (int i = 0; i < 32; i++) { key[i] = (byte) i; challenge[i] = (byte) (31 - i); }
            byte[] digest = auth(key, challenge);
            StringBuilder hex = new StringBuilder();
            for (byte value : digest) hex.append(String.format(java.util.Locale.ROOT, "%02x", value & 255));
            if (!"0d72196d414a07b3be02b55ea133f15c6a1962e7db7278289f07867382555100".contentEquals(hex))
                throw new AssertionError("auth_vector");
            byte[] wrong = digest.clone(); wrong[0] ^= 1;
            if (MessageDigest.isEqual(digest, wrong)) throw new AssertionError("bad_auth_accepted");
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            DataOutputStream output = new DataOutputStream(bytes);
            write(output, new Frame(AUTH, 0, digest));
            write(output, new Frame(HEARTBEAT, 1, new byte[0]));
            byte[] stream = bytes.toByteArray();
            // DataInputStream.readFully must work with headers/payload split into single bytes.
            InputStream fragmented = new ByteArrayInputStream(stream) {
                @Override public synchronized int read(byte[] target, int offset, int length) { return super.read(target, offset, Math.min(length, 1)); }
            };
            DataInputStream input = new DataInputStream(fragmented);
            Frame first = read(input, 0), second = read(input, 1);
            if (first.type != AUTH || !MessageDigest.isEqual(first.payload, digest) || second.type != HEARTBEAT || input.read() != -1)
                throw new AssertionError("fragmented_roundtrip");
            first.clear(); second.clear();
            reject(stream, 1); // replay/wrong sequence
            byte[] altered = stream.clone(); altered[1] = 1; reject(altered, 0);
            altered = stream.clone(); altered[2] = 4; altered[3] = 1; reject(altered, 0); // payload > 1024
            altered = stream.clone(); altered[0] = 0x7f; reject(altered, 0);
            reject(Arrays.copyOf(stream, 9), 0); // truncated payload
            reject(new byte[]{0x30, 0, 0, 1, 0, 0, 0, 0, 0}, 0); // invalid answer value
            reject(new byte[]{0x20, 0, 0, 1, 0, 0, 0, 0, 3}, 0); // invalid state value
            short[] samples = new short[SAMPLES]; samples[0] = Short.MIN_VALUE; samples[1] = Short.MAX_VALUE; samples[2] = -1;
            byte[] pcm = pcmBytes(samples); short[] restored = new short[SAMPLES]; pcmShorts(pcm, restored);
            if (!Arrays.equals(samples, restored)) throw new AssertionError("pcm_le_roundtrip");
            PcmQueue queue = new PcmQueue();
            byte[] evicted = new byte[PCM_BYTES]; Arrays.fill(evicted, (byte) 7); queue.offer(evicted);
            for (int i = 0; i < MAX_PCM_QUEUE; i++) queue.offer(new byte[PCM_BYTES]);
            if (queue.dropped != 1 || evicted[0] != 0) throw new AssertionError("bounded_queue_zeroization");
            queue.close();
            Arrays.fill(key, (byte) 0); Arrays.fill(challenge, (byte) 0); Arrays.fill(digest, (byte) 0);
            Arrays.fill(wrong, (byte) 0); Arrays.fill(stream, (byte) 0); Arrays.fill(altered, (byte) 0);
            Arrays.fill(pcm, (byte) 0); Arrays.fill(samples, (short) 0); Arrays.fill(restored, (short) 0);
        }
        static void reject(byte[] stream, long expected) throws Exception {
            try { read(new DataInputStream(new ByteArrayInputStream(stream)), expected).clear(); }
            catch (IOException wanted) { return; }
            throw new AssertionError("malformed_frame_accepted");
        }
    }

    private static final class Levels {
        long samples, nonzero, power;
        int peak;
        void add(short sample) { samples++; if (sample != 0) nonzero++; peak = Math.max(peak, Math.abs((int) sample)); power += (long) sample * sample; }
        long rms() { return samples == 0 ? 0 : Math.round(Math.sqrt(power / (double) samples)); }
    }

    private static final class Settings {
        final int ringMode, ringVolume, callVolume;
        final boolean ringMuted, callMuted;
        Settings(AudioManager audio) {
            ringMode = audio.getRingerMode(); ringVolume = audio.getStreamVolume(AudioManager.STREAM_RING);
            callVolume = audio.getStreamVolume(AudioManager.STREAM_VOICE_CALL);
            ringMuted = audio.isStreamMute(AudioManager.STREAM_RING); callMuted = audio.isStreamMute(AudioManager.STREAM_VOICE_CALL);
        }
        void compare(AudioManager audio) {
            Settings after = new Settings(audio);
            emit("settings_comparison", "ringer_same", ringMode == after.ringMode && ringVolume == after.ringVolume && ringMuted == after.ringMuted,
                    "call_volume_same", callVolume == after.callVolume && callMuted == after.callMuted,
                    "settings_written", false);
        }
    }

    private static Thread daemon(String name, Runnable runnable) {
        Thread thread = new Thread(runnable, name); thread.setDaemon(true); thread.start(); return thread;
    }
    private static void join(Thread thread) {
        if (thread == null) return;
        try { thread.join(1000); } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
    }
    private static long now() { return SystemClock.elapsedRealtime(); }
    private static String ioReason(Throwable error) {
        for (int depth = 0; error != null && depth < 8; depth++, error = error.getCause()) {
            String message = error.getMessage();
            if (message == null) continue;
            for (String code : new String[]{"ECONNREFUSED", "ENOENT", "EACCES", "EPERM", "ECONNRESET", "ETIMEDOUT", "EINTR", "ENOTCONN"})
                if (message.contains(code)) return code;
            if (message.contains("Connection refused")) return "ECONNREFUSED";
            if (message.contains("No such file or directory")) return "ENOENT";
            if (message.contains("Permission denied")) return "EACCES";
            if (message.contains("Operation not permitted")) return "EPERM";
        }
        return "unknown";
    }
    private static void failure(String stage, Throwable error) {
        while (error instanceof InvocationTargetException && error.getCause() != null) error = error.getCause();
        // No exception messages, addresses, pairing material, raw dumps, phone numbers or PCM.
        if (error instanceof OwnedCallFailure) {
            OwnedCallFailure failed = (OwnedCallFailure) error;
            emit(stage, "error_class", IOException.class.getName(), "reason", failed.reason,
                    "cause_class", failed.getCause() == null ? "none" : failed.getCause().getClass().getName(),
                    "io_reason", ioReason(failed));
        } else emit(stage, "error_class", error.getClass().getName());
    }
    private static void emit(String stage, Object... fields) {
        try {
            JSONObject event = new JSONObject().put("stage", stage).put("elapsed_ms", (System.nanoTime() - STARTED_NS) / 1000000L);
            for (int i = 0; i < fields.length; i += 2) event.put((String) fields[i], fields[i + 1]);
            System.out.println("PJZ_BRIDGE " + event);
        } catch (org.json.JSONException invalid) { throw new AssertionError(invalid); }
    }
}
