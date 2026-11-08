import pathlib,subprocess,json,os,sys
root=pathlib.Path(__file__).resolve().parents[3];b=pathlib.Path(sys.argv[1]);b.mkdir(parents=True,exist_ok=True)
s=(root/'scripts/diagnostics/TelephonyNetworkBridge.java').read_text()
def section(start,end):return s[s.index(start):s.index(end,s.index(start))]
methods=''.join(section(a,z) for a,z in [
('        void attachAuthenticated(', '        void acceptResumes('),
('        void acceptResumes(', '        boolean ownedActive('),
('        void sendCallerIdentity()', '        void authenticate('),
('        void endOwnedCall(', '        void openAudio('),
('        void readLoop(DataInputStream input, Socket transport','        void releaseAudio(')])
# The only Android dependency in these production transport methods is substituted by a fake owned Call.
prefix=r'''
import java.io.*;import java.net.*;import java.security.*;import java.nio.charset.*;import java.util.*;import java.util.function.*;import java.util.concurrent.*;import java.util.concurrent.atomic.*;import javax.crypto.*;import javax.crypto.spec.*;
public class RecoveryServerFixture {
 static final int PCM_BYTES=640,SAMPLES=320,MAX_PCM_QUEUE=10;static volatile long clock=1000;
 static class SystemClock {static void sleep(long ms){try{Thread.sleep(Math.min(5,ms));}catch(InterruptedException e){Thread.currentThread().interrupt();}}}
 static long now(){return clock;} static void failure(String x,Throwable e){} static void emit(String x,Object...v){}
 static Thread daemon(String n,Runnable r){Thread t=new Thread(r,n);t.setDaemon(true);t.start();return t;}
 static void join(Thread t){if(t!=null&&t!=Thread.currentThread())try{t.join(1000);}catch(InterruptedException e){throw new RuntimeException(e);}}
 static boolean isTailscale(InetAddress x){return true;} static void requireIdle(Object a,Object t){}
 static class Config{byte[]key=new byte[32];boolean allowAnswer=true;}
 static class OwnedCall{boolean active=true;int ends;final String callId="00000000-0000-4000-8000-000000000001";CallerIdentity caller=new CallerIdentity("合成来电","+15550000001");final Object original=new Object();Object ended;boolean active(){return active;}void disconnect(){ends++;ended=original;active=false;}}
 static class Lifecycle {String callId;boolean end(){return false;}}
 static class Pushes {void publish(String id,int revision,String state){}}
 static class Session{
 final Object transportLock=new Object();final Lifecycle incoming=new Lifecycle();final Pushes pushes=new Pushes();boolean ringSeen;
 void attachInitial(Socket candidate)throws Exception{throw new AssertionError("legacy_active_test_only");}
 final Config config=new Config();final Recovery recovery=new Recovery();final byte[]sessionToken=new byte[32];final AtomicBoolean stopped=new AtomicBoolean(),transportLost=new AtomicBoolean(),answerRequested=new AtomicBoolean(),hangupRequested=new AtomicBoolean();final AtomicInteger state=new AtomicInteger();final AtomicLong upReceived=new AtomicLong(),downSent=new AtomicLong();final Outbound outbound=new Outbound();final PcmQueue inbound=new PcmQueue();final Object audio=new Object(),telecom=new Object();final OwnedCall ownedCall=new OwnedCall();boolean answerAttempted=true,gate=true;volatile boolean callerIdentitySupported,pendingResumeCallerIdentity;CallerIdentity sentCaller;volatile Socket socket,pendingResume,authenticatingResume;ServerSocket listener;Thread reader,writer,resumeAcceptor,coordinator;volatile long lastPeerFrame;volatile String phase,endingReason,stopReason="not_started";
 boolean ownedActive(){return answerAttempted&&ownedCall.active();}
'''
lifecycle=section('    static String canonicalId(', '    /** Shared by the Android listener')
admission=section('    /** Shared by the Android listener', '    static URL validateProvider(')
protocol=section('    static final class Frame {','    private static final class Levels')
queues=section('    private static final class Outbound {','    private static AudioDeviceInfo telephonyDevice')
recovery=section('    static final class Recovery {','    /** Shell-only Binder control')
tests=r'''
 void cleanup()throws Exception{stop("test_end");listener.close();if(authenticatingResume!=null)authenticatingResume.close();if(pendingResume!=null)pendingResume.close();join(reader);join(writer);join(resumeAcceptor);join(coordinator);}
 }
 static void check(boolean ok,String label){if(!ok)throw new AssertionError(label);}
 static void until(java.util.function.BooleanSupplier condition)throws Exception{long end=System.currentTimeMillis()+3000;while(!condition.getAsBoolean()&&System.currentTimeMillis()<end)Thread.sleep(2);check(condition.getAsBoolean(),"async_condition");}
 static class Pair{Session s;Socket old;DataInputStream input;Pair()throws Exception{this(false);}Pair(boolean identity)throws Exception{clock=1000;s=new Session();Arrays.fill(s.config.key,(byte)7);Arrays.fill(s.sessionToken,(byte)9);s.listener=new ServerSocket(0,2,InetAddress.getLoopbackAddress());old=new Socket(InetAddress.getLoopbackAddress(),s.listener.getLocalPort());old.setSoTimeout(3000);s.socket=s.listener.accept();s.attachAuthenticated(s.socket,false,identity);input=new DataInputStream(old.getInputStream());check(Protocol.read(input,1).type==Protocol.SESSION,"initial_session1");check(Protocol.read(input,2).payload[0]==0,"initial_idle2");s.state.set(2);s.resumeAcceptor=daemon("test-resumes",s::acceptResumes);s.coordinator=daemon("test-main",()->{try{while(!s.stopped.get()){if(s.hangupRequested.get()){s.endOwnedCall("explicit_hangup");break;}if(s.transportLost.get()&&!s.recoverTransport())break;Thread.sleep(1);}}catch(Exception e){throw new RuntimeException(e);}});}
 Socket resume(boolean correct)throws Exception{return resume(correct,false);}Socket resume(boolean correct,boolean identity)throws Exception{Socket next=new Socket(InetAddress.getLoopbackAddress(),s.listener.getLocalPort());next.setSoTimeout(3000);DataInputStream input=new DataInputStream(next.getInputStream());DataOutputStream output=new DataOutputStream(next.getOutputStream());Frame challenge=Protocol.read(input,0);check(challenge.type==Protocol.CHALLENGE,"resume_challenge0");Protocol.write(output,new Frame(Protocol.AUTH,0,Protocol.auth(s.config.key,challenge.payload,identity)));byte[]token=s.sessionToken.clone();if(!correct)token[0]^=1;Protocol.write(output,new Frame(Protocol.RESUME,1,token));return next;}
 void close()throws Exception{s.cleanup();old.close();}}
 static void wake(boolean identity,boolean foreground)throws Exception{
  byte[]key=new byte[32],token=new byte[32];String id="00000000-0000-4000-8000-000000000001";CallerIdentity caller=new CallerIdentity("合成来电","+15550000001");
  try(ServerSocket listener=new ServerSocket(0,1,InetAddress.getLoopbackAddress());Socket client=new Socket(InetAddress.getLoopbackAddress(),listener.getLocalPort())){
   client.setSoTimeout(3000);FutureTask<Admission> server=new FutureTask<>(()->{Socket accepted=listener.accept();return Admission.initial(accepted,key,token,()->id,()->caller.payload(id));});new Thread(server).start();
   DataInputStream input=new DataInputStream(client.getInputStream());DataOutputStream output=new DataOutputStream(client.getOutputStream());Frame challenge=Protocol.read(input,0);Protocol.write(output,new Frame(Protocol.AUTH,0,Protocol.auth(key,challenge.payload,identity)));
   if(!foreground)Protocol.write(output,new Frame(Protocol.JOIN,1,id.getBytes(StandardCharsets.US_ASCII)));
   long next=1;if(!foreground)check(Protocol.read(input,next++).type==Protocol.JOIN,"wake_join_echo");check(Protocol.read(input,next++).type==Protocol.SESSION,"admission_session");
   if(identity&&!foreground){Frame frame=Protocol.read(input,next++);check(frame.type==Protocol.CALLER&&new String(frame.payload,StandardCharsets.UTF_8).contains("合成来电"),"new_auth_identity_before_ringing");}
   Frame state=Protocol.read(input,next++);check(state.type==Protocol.STATE&&state.payload[0]==(foreground?0:1),"legacy_or_new_admission_state");Admission admitted=server.get(3,TimeUnit.SECONDS);check(admitted.callerIdentitySupported==identity&&admitted.nextOutput==next,"capability_and_sequences");admitted.input.close();
  }
 }
 public static void main(String[]args)throws Exception{
 Protocol.selfTest();Recovery.selfTest();
  wake(false,false);wake(true,false);wake(false,true);wake(true,true);
  Pair legacy=new Pair();legacy.s.sendCallerIdentity();check(legacy.s.outbound.controls.isEmpty(),"legacy_auth32_never_enqueues_identity");legacy.close();
  Pair metadata=new Pair(true);metadata.s.sendCallerIdentity();Frame initial=Protocol.read(metadata.input,3);check(initial.type==Protocol.CALLER,"negotiated_initial_identity");metadata.s.ownedCall.caller=new CallerIdentity("迟到姓名","+15550000001");metadata.s.sendCallerIdentity();Frame late=Protocol.read(metadata.input,4);String identityText=new String(late.payload,StandardCharsets.UTF_8);check(late.type==Protocol.CALLER&&identityText.contains("迟到姓名")&&identityText.contains(metadata.s.ownedCall.callId),"late_name_same_call_identity_frame");metadata.s.sendCallerIdentity();check(metadata.s.outbound.controls.isEmpty(),"unchanged_identity_not_requeued");
  Socket enhanced=metadata.resume(true,true);DataInputStream enhancedInput=new DataInputStream(enhanced.getInputStream());check(Protocol.read(enhancedInput,1).type==Protocol.SESSION,"new_resume_session");check(Protocol.read(enhancedInput,2).type==Protocol.CALLER,"new_resume_latest_identity");check(Protocol.read(enhancedInput,3).payload[0]==2,"new_resume_active3");enhanced.close();metadata.close();
 Pair good=new Pair();check(!good.s.transportLost.get()&&!good.s.socket.isClosed(),"old_tcp_established_before_takeover");Socket next=good.resume(true);DataInputStream input=new DataInputStream(next.getInputStream());check(Protocol.read(input,1).type==Protocol.SESSION,"resume_session1");check(Protocol.read(input,2).payload[0]==2,"resume_active2");check(good.input.read()==-1,"authenticated_takeover_closes_established_old_socket");check(good.s.answerAttempted&&!good.s.answerRequested.get(),"resume_no_answer");
 DataOutputStream output=new DataOutputStream(next.getOutputStream());Protocol.write(output,new Frame(Protocol.HANGUP,2,good.s.sessionToken.clone()));Protocol.write(output,new Frame(Protocol.HANGUP,3,good.s.sessionToken.clone()));Frame end=Protocol.read(input,3);check(end.type==Protocol.STATE&&end.payload[0]==0,"hangup_idle_confirmation");until(()->good.s.stopped.get());check(good.s.ownedCall.ends==1&&good.s.ownedCall.ended==good.s.ownedCall.original,"hangup_original_once");next.close();good.close();
 Pair bad=new Pair();Socket rejected=bad.resume(false);check(rejected.getInputStream().read()==-1,"wrong_token_rejected");check(!bad.s.transportLost.get()&&!bad.s.socket.isClosed()&&bad.s.ownedCall.ends==0,"bad_token_preserves_original_transport");rejected.close();bad.close();
 Pair expiry=new Pair();expiry.s.recovery.lost(clock);clock=31000;expiry.s.loseTransport(expiry.s.socket,"fixture_blackhole",new IOException());until(()->expiry.s.stopped.get());check(expiry.s.ownedCall.ends==1&&"recovery_expired".equals(expiry.s.stopReason),"30s_failure_ends_owned_call_once");expiry.close();
 Pair replacement=new Pair();replacement.s.recovery.lost(clock);replacement.s.ownedCall.active=false;replacement.s.transportLost.set(true);replacement.s.socket.close();clock=31000;until(()->replacement.s.stopped.get());check(replacement.s.ownedCall.ends==0,"replacement_call_never_disconnected");replacement.close();
  System.out.println("PASS java_actual_transport legacy_AUTH32_unchanged new_AUTH33_wake_foreground_resume authenticated_capability late_identity_same_call actual_socket_takeover no_repeat_answer hangup_idle_ack exact_original_once fixed30s_recovery replacement_untouched unlimited_normal_clock");
 }
}
'''
(b/'RecoveryServerFixture.java').write_text(prefix+methods+tests[:tests.index(' static void check')]+protocol+queues+recovery+lifecycle+admission+tests[tests.index(' static void check'):])
jdk=str(pathlib.Path(os.environ['JAVA_HOME'])/'bin')+'/'
def run(name,args,timeout=20):
 p=subprocess.run(args,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout);(b/(name+'.log')).write_text(p.stdout)
 if p.returncode:raise RuntimeError(name+': '+p.stdout[-4000:])
 return p.stdout.strip()
run('java-fixture-build',[jdk+'javac','--release','8',str(b/'RecoveryServerFixture.java')])
r=run('java-fixture-result',[jdk+'java','-cp',str(b),'RecoveryServerFixture'])
p=b/'targeted-verification.json';d=json.loads(p.read_text()) if p.exists() else {};d['java']=r;d['scope']='Actual Swift protocol/recovery state with fake clock; actual extracted Java transport methods with loopback sockets and fake owned Call. No hardware audio/cellular acceptance.';p.write_text(json.dumps(d,indent=2)+'\n');print(r)
