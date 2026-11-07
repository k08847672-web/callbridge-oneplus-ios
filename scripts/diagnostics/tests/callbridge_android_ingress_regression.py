"""Exercise production helper handshake and publisher failures without Android or calls."""
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[3]
build = pathlib.Path(sys.argv[1])
build.mkdir(parents=True, exist_ok=True)
source = (root / 'scripts/diagnostics/TelephonyNetworkBridge.java').read_text()

def section(start, end):
    return source[source.index(start):source.index(end, source.index(start))]

owned = section('    private static final class OwnedCallFailure', '    private static final class Session')
owned = owned.replace('android.net.', '')
publisher = section('    private static final class PushEvents', '    /** Local-only fake original Call')
failure = section('    private static void failure(', '    private static void emit(')
prefix = r'''
import java.io.*;import java.net.*;import java.nio.charset.*;import java.util.*;import java.util.concurrent.*;import java.lang.reflect.*;import com.sun.net.httpserver.*;
public class AndroidIngressFixture {
 static long clock;
 static long now(){return clock;}
 static class SystemClock {static void sleep(long ms){clock+=ms;}}
 static class Context {Context getPackageManager(){return this;}Context getApplicationInfo(String name,int flags){return this;}int uid=10001;int getUid(){return uid;}}
 static class LocalSocketAddress {enum Namespace{ABSTRACT}LocalSocketAddress(String name,Namespace namespace){}}
 static class LocalSocket implements AutoCloseable {
  static String mode;static int opened,closed;
  boolean didClose;final ByteArrayOutputStream sent=new ByteArrayOutputStream();PipedInputStream input;PipedOutputStream writer;
  LocalSocket(){opened++;}
  void connect(LocalSocketAddress address)throws IOException{if("connect".equals(mode))throw new IOException("private_sentinel");}
  Context getPeerCredentials(){return new Context();}
  OutputStream getOutputStream(){return sent;}
  void setSoTimeout(int timeout){}
  InputStream getInputStream()throws IOException{
   if("identity_timeout".equals(mode))throw new SocketTimeoutException("private_sentinel");
   if("identity_eof".equals(mode))return new ByteArrayInputStream(new byte[0]);
   ByteArrayOutputStream data=new ByteArrayOutputStream();
   data.write("00000000-0000-4000-8000-000000000001".getBytes(StandardCharsets.US_ASCII));
   if(!"state_eof".equals(mode))data.write("ended".equals(mode)?0:"invalid_state".equals(mode)?7:1);
   if(!"ringing".equals(mode))return new ByteArrayInputStream(data.toByteArray());
   input=new PipedInputStream();writer=new PipedOutputStream(input);writer.write(data.toByteArray());writer.flush();return input;
  }
  public void close()throws IOException{if(!didClose){didClose=true;closed++;if(writer!=null)writer.close();if(input!=null)input.close();}}
 }
 static String canonicalId(String value){return UUID.fromString(value).toString();}
 static Thread daemon(String name,Runnable action){Thread thread=new Thread(action,name);thread.setDaemon(true);thread.start();return thread;}
 static void join(Thread thread){if(thread!=null)try{thread.join(1000);}catch(InterruptedException e){throw new AssertionError(e);}}
 static class Config {
  final String providerUrl,providerToken="private_sentinel",pairingId="00000000-0000-4000-8000-000000000010";
  final InetAddress bindAddress;
  Config(String url)throws Exception{providerUrl=url;bindAddress=InetAddress.getByAddress(new byte[]{100,64,0,1});}
 }
 static final List<String> logs=Collections.synchronizedList(new ArrayList<>());
 static void emit(String stage,Object...fields){logs.add(stage+" "+Arrays.toString(fields));}
 static void check(boolean value,String label){if(!value)throw new AssertionError(label);}
'''
tests = r'''
 static void failedHelper(String mode,String reason,String cause)throws Exception{
  LocalSocket.mode=mode;int opened=LocalSocket.opened,closed=LocalSocket.closed;OwnedCall call=null;
  try{call=new OwnedCall(new Context(),new byte[32]);call.observeBeforeAnswer();throw new AssertionError("helper_failure_required");}
  catch(OwnedCallFailure error){check(reason.equals(error.reason),mode+"_reason");failure("wait_new_call_failed",error);String log=logs.get(logs.size()-1);check(log.contains(reason)&&log.contains(cause)&&!log.contains("private_sentinel"),mode+"_redacted_diagnostic");}
  finally{if(call!=null)call.close();}
  check(LocalSocket.opened-opened==LocalSocket.closed-closed,mode+"_socket_closed");
 }
 static void push(String url,boolean accepted,int status,int attempts,String error)throws Exception{
  int before=logs.size();PushEvents publisher=new PushEvents(new Config(url));
  publisher.publish("00000000-0000-4000-8000-000000000001",1,"ringing");publisher.close();publisher.worker.join(15000);
  check(!publisher.worker.isAlive(),"publisher_completed");check(logs.size()==before+1,"one_terminal_result");String log=logs.get(before);
  check(log.contains("accepted, "+accepted)&&log.contains("http_status, "+status)&&log.contains("attempts, "+attempts)&&log.contains("error_class, "+error),"publisher_terminal_fields_"+log);
  check(!log.contains("private_sentinel")&&!log.contains("http://")&&!log.contains("pairing_id"),"publisher_redacted");
 }
 public static void main(String[]args)throws Exception{
  failedHelper("connect","helper_connect_unavailable","java.io.IOException");
  failedHelper("identity_eof","helper_identity_exchange_failed","java.io.EOFException");
  failedHelper("identity_timeout","helper_identity_exchange_failed","java.net.SocketTimeoutException");
  failedHelper("state_eof","helper_initial_state_failed","java.io.EOFException");
  failedHelper("ended","helper_call_not_ringing","none");
  failedHelper("invalid_state","helper_initial_state_failed","java.io.IOException");
  LocalSocket.mode="ringing";try(OwnedCall call=new OwnedCall(new Context(),new byte[32])){call.observeBeforeAnswer();check(call.state==1,"real_handshake_ringing");check(call.channel.sent.size()==36,"header_and_token");check(new DataInputStream(new ByteArrayInputStream(call.channel.sent.toByteArray())).readInt()==0x50435a32,"PCZ2_helper_header");}
  HttpServer server=HttpServer.create(new InetSocketAddress("127.0.0.1",0),0);int[]status={200},requests={0};
  server.createContext("/v1/calls",exchange->{requests[0]++;while(exchange.getRequestBody().read()!=-1){};int code=status[0]==-1&&requests[0]==1?503:status[0]==-1?200:status[0];byte[]body="private_sentinel".getBytes(StandardCharsets.US_ASCII);exchange.sendResponseHeaders(code,body.length);exchange.getResponseBody().write(body);exchange.close();});server.start();
  try{String url="http://127.0.0.1:"+server.getAddress().getPort();push(url,true,200,1,"none");status[0]=403;push(url,false,403,1,"none");status[0]=-1;requests[0]=0;push(url,true,200,2,"none");}finally{server.stop(0);}
  int unavailable;try(ServerSocket reserved=new ServerSocket(0)){unavailable=reserved.getLocalPort();}push("http://127.0.0.1:"+unavailable,false,0,3,"java.net.ConnectException");
  check(LocalSocket.opened==LocalSocket.closed,"all_local_sockets_closed");
  System.out.println("PASS actual_android_ingress helper_connect_handshake_initial_state fixed_redacted_reasons failed_socket_cleanup publisher_HTTP_status_retry_exception redacted_terminal_result no_device_or_calls");
 }
}
'''
fixture = build / 'AndroidIngressFixture.java'
fixture.write_text(prefix + owned + publisher + failure + tests)
jdk = pathlib.Path(os.environ['JAVA_HOME']) / 'bin'
for name, arguments in [
    ('android-ingress-build', [str(jdk/'javac'), '--release', '8', str(fixture)]),
    ('android-ingress-result', [str(jdk/'java'), '-cp', str(build), 'AndroidIngressFixture']),
]:
    result = subprocess.run(arguments, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
    (build / (name + '.log')).write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(name + ': ' + result.stdout[-4000:])
    if name.endswith('result'):
        print(result.stdout.strip())
