import pathlib,subprocess,json,os,sys
root=pathlib.Path(__file__).resolve().parents[3];b=pathlib.Path(sys.argv[1]);b.mkdir(parents=True,exist_ok=True)
s=(root/'android/callbridgehelper/src/main/java/com/doitio/callbridgehelper/BridgeInCallService.java').read_text()
a=s.index('    private final class Claim {');claim=s[a:s.rfind('\n}')]
pre='''import java.util.*;import java.io.*;import java.nio.charset.StandardCharsets;
public class HelperClaimFixture {
 static class Call {static final int STATE_RINGING=2,STATE_ACTIVE=4;int state=STATE_RINGING,answers,ends;int getState(){return state;}void answer(int v){answers++;}void disconnect(){ends++;}}
 static class LocalSocket {ByteArrayOutputStream bytes=new ByteArrayOutputStream();OutputStream getOutputStream()throws IOException{return bytes;}void close()throws IOException{}}
 static class VideoProfile {static final int STATE_AUDIO_ONLY=0;}
 final IdentityHashMap<Call,String> identities=new IdentityHashMap<>();
 final List<Call> calls=new ArrayList<>();List<Call>getCalls(){return calls;}
'''
post='''
 static void check(boolean ok,String label){if(!ok)throw new AssertionError(label);}
 public static void main(String[]args)throws Exception{
 HelperClaimFixture f=new HelperClaimFixture();Call original=new Call(),other=new Call();f.calls.add(original);Claim claim=f.new Claim(original,new LocalSocket(),new byte[32]);
 claim.initialize();check(claim.socket.bytes.size()==37,"uuid_before_initial_state");String id=claim.callId;Claim same=f.new Claim(original,new LocalSocket(),new byte[32]);check(id.equals(same.callId),"same_exact_call_stable_uuid");
 claim.disconnect();check(original.ends==0,"ringing_not_hung_up");claim.answer();claim.answer();check(original.answers==1,"answer_original_once");original.state=Call.STATE_ACTIVE;f.calls.add(other);claim.disconnect();claim.disconnect();check(original.ends==1&&other.ends==0,"only_original_once_with_other_call_present");
 HelperClaimFixture g=new HelperClaimFixture();Call ended=new Call(),replacement=new Call();g.calls.add(ended);Claim stale=g.new Claim(ended,new LocalSocket(),new byte[32]);stale.answer();ended.state=Call.STATE_ACTIVE;g.calls.remove(ended);g.calls.add(replacement);stale.disconnect();check(ended.ends==0&&replacement.ends==0,"removed_original_does_not_hang_replacement");
 System.out.println("PASS actual_helper_claim no_ringing_hangup exact_original_answer_once exact_original_disconnect_once other_call_untouched removed_original_no_fallback");
 }
}
'''
(b/'HelperClaimFixture.java').write_text(pre+claim+post)
jdk=str(pathlib.Path(os.environ['JAVA_HOME'])/'bin')+'/'
for name,args in [('helper-fixture-build',[jdk+'javac','--release','8',str(b/'HelperClaimFixture.java')]),('helper-fixture-result',[jdk+'java','-cp',str(b),'HelperClaimFixture'])]:
 p=subprocess.run(args,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);(b/(name+'.log')).write_text(p.stdout)
 if p.returncode:raise RuntimeError(name+': '+p.stdout)
 if name.endswith('result'):
  print(p.stdout.strip());v=json.loads((b/'targeted-verification.json').read_text());v['helper']=p.stdout.strip();(b/'targeted-verification.json').write_text(json.dumps(v,indent=2)+'\n')
