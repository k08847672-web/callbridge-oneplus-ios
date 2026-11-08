"""Actual wait loop and helper lifecycle with fake Telecom/local sockets; no device access."""
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
build = Path(sys.argv[1])
build.mkdir(parents=True, exist_ok=True)
source = (root/'scripts/diagnostics/TelephonyNetworkBridge.java').read_text()

def section(start, end, offset=0):
    begin = source.index(start, offset)
    return source[begin:source.index(end, begin)]

session_at = source.index('    private static final class Session')
run = section('        void run() throws Exception {', '        String joinableCall()', session_at)
close = section('        @Override public void close() {', '    private static final class Outbound', session_at)
diagnostic = section('    private static String ioReason(', '    private static void emit(')
prefix = r'''
import java.io.*;import java.net.*;import java.util.*;import java.util.concurrent.*;import java.util.concurrent.atomic.*;import java.lang.reflect.*;
public class WaitFixture {
 static int tick,attempts,audioStarts,answers;static boolean available=true;static Runnable advance;
 static class SystemClock{static void sleep(long ms){tick++;if(tick>2000)throw new AssertionError("wait_loop_stuck");advance.run();}}
 static long now(){return tick*20L;}static void join(Thread thread){}
 static Thread daemon(String name,Runnable job){return null;}
 static final List<String> logs=new ArrayList<>();static void emit(String stage,Object...fields){logs.add(stage+Arrays.toString(fields));}
 static class OwnedCallFailure extends IOException{final String reason;OwnedCallFailure(String reason,Throwable cause){super(reason,cause);this.reason=reason;}}
 static class OwnedCall{int state=1;final String callId="00000000-0000-4000-8000-000000000001";boolean closed;
  OwnedCall(Object context)throws OwnedCallFailure{attempts++;if(!available)throw new OwnedCallFailure("helper_connect_unavailable",new IOException("connect failed ECONNREFUSED private_sentinel"));}
  void observeBeforeAnswer(){}void close(){closed=true;state=0;}boolean active(){return state==2;}void answer(){answers++;}}
 static class AudioManager{static final int MODE_NORMAL=0,MODE_IN_CALL=2;int mode;int getMode(){return mode;}}
 static class TelecomManager{boolean ring,inCall;boolean isInCall(){return inCall;}}
 static boolean ringing(TelecomManager telecom){return telecom.ring;}static boolean active(AudioManager audio,TelecomManager telecom){return audio.mode==2&&telecom.inCall;}
 static class Config{boolean allowAnswer=true;}
 static class Frame{Frame(int type,int sequence,byte[]payload){}}
 static class Protocol{static final int HEARTBEAT=64,JOIN=51,STATE=32;}
 static class Incoming{boolean answered;String callId;void ring(String id){callId=id;}byte[]idBytes(){return new byte[36];}boolean answer(){if(answered)return false;answered=true;return true;}boolean end(){return callId!=null;}}
 static class Pushes{int ringing,ended;void publish(String id,int revision,String state){if(revision==1)ringing++;else ended++;}void close(){}}
 static class Queue{void control(Frame frame){}void close(){}}
 static class Settings{void compare(AudioManager audio){}}
 static class Recovery{boolean ended;}
 static class Session implements AutoCloseable{
 final Config config=new Config();final Object context=new Object();final AudioManager audio=new AudioManager();final TelecomManager telecom=new TelecomManager();
 final AtomicBoolean stopped=new AtomicBoolean(),answerRequested=new AtomicBoolean(),transportLost=new AtomicBoolean();final AtomicInteger state=new AtomicInteger();
 final Object transportLock=new Object();final byte[]sessionToken=new byte[32];final Incoming incoming=new Incoming();final Pushes pushes=new Pushes();final Queue outbound=new Queue(),inbound=new Queue();final Recovery recovery=new Recovery();final Settings initialSettings=new Settings();
 final ServerSocket listener;OwnedCall ownedCall;Socket socket,authenticatingResume,pendingResume;FutureTask<Boolean>flagCheck;Thread reader,writer,flagThread,resumeAcceptor;boolean ringSeen,answerAttempted;String phase,stopReason="not_started";
 Session(ServerSocket listener){this.listener=listener;}void acceptResumes(){}void live(){audioStarts++;}void releaseAudio(){}void levels(String stage){}
 void stop(String reason){stopReason=reason;stopped.set(true);}void finishRemoteCall(String reason){if(ringSeen)pushes.publish(incoming.callId,2,"ended");stop(reason);}
'''
tests = r'''
 static void check(boolean value,String label){if(!value)throw new AssertionError(label);}
 static void reset(){tick=attempts=audioStarts=answers=0;available=true;logs.clear();}
 static Session session(ServerSocket listener){return new Session(listener);}
 static void finish(Session session){if(session.ownedCall!=null)session.ownedCall.state=0;session.telecom.ring=false;session.telecom.inCall=false;session.audio.mode=0;}
 public static void main(String[]args)throws Exception{
  try(ServerSocket listener=new ServerSocket(0,2,InetAddress.getLoopbackAddress())){
   reset();Session late=session(listener);late.telecom.ring=true;available=false;
   advance=()->{if(tick==200)available=true;if(late.ringSeen)finish(late);};late.run();
   check(attempts==201&&late.pushes.ringing==1&&late.pushes.ended==1,"helper_late_beyond_old_3s_then_publishes_once");
   check(logs.stream().filter(log->log.startsWith("helper_waiting")).count()==1,"bounded_wait_diagnostic");
   check(logs.stream().anyMatch(log->log.contains("ECONNREFUSED"))&&logs.stream().noneMatch(log->log.contains("private_sentinel")),"errno_redacted");
   late.close();check(!listener.isClosed(),"session_close_keeps_process_listener");
   reset();Session next=session(listener);next.telecom.ring=true;available=false;
   advance=()->{if(tick==5){next.telecom.ring=false;next.telecom.inCall=true;next.audio.mode=2;}if(tick==10){next.telecom.ring=true;next.telecom.inCall=false;next.audio.mode=0;available=true;}if(next.ringSeen)finish(next);};next.run();
   check(next.pushes.ringing==1&&audioStarts==0&&answers==0,"unavailable_call_local_answer_then_next_call");next.close();
   reset();Session local=session(listener);local.telecom.ring=true;
   advance=()->{local.telecom.ring=false;local.telecom.inCall=true;local.audio.mode=2;if(local.ownedCall!=null)local.ownedCall.state=0;};local.run();
   check("answered_on_phone".equals(local.stopReason)&&audioStarts==0&&answers==0,"local_answer_no_adoption");local.close();
   reset();Session outgoing=session(listener);outgoing.telecom.inCall=true;outgoing.audio.mode=2;
   advance=()->{if(tick==5){outgoing.telecom.inCall=false;outgoing.audio.mode=1;}if(tick==10){outgoing.audio.mode=0;outgoing.telecom.ring=true;}if(outgoing.ringSeen)finish(outgoing);};outgoing.run();
   check(outgoing.pushes.ringing==1&&audioStarts==0&&answers==0,"ordinary_outgoing_and_ringtone_race_do_not_exit");outgoing.close();
   check(!listener.isClosed(),"same_listener_survives_all_sessions");
  }
  System.out.println("PASS actual_wait_loop helper_late_ready_no_deadline unavailable_then_local_answer_next_call local_calls_not_adopted ringtone_transition shared_listener errno_redacted");
 }
}
'''
(build/'WaitFixture.java').write_text(prefix+run+close+diagnostic+tests)

jdk = Path(os.environ['JAVA_HOME'])/'bin'
for fixture in ['WaitFixture']:
    for phase, arguments in [
        ('build', [str(jdk/'javac'), '--release', '8', str(build/(fixture+'.java'))]),
        ('result', [str(jdk/'java'), '-cp', str(build), fixture]),
    ]:
        result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
        (build/(fixture+'-'+phase+'.log')).write_text(result.stdout)
        if result.returncode:
            raise RuntimeError(fixture+' '+phase+': '+result.stdout[-5000:])
        if phase == 'result': print(result.stdout.strip())
