"""Actual Android publisher on localhost: HTTP outcome diagnostics without device or APNs."""
import os
from pathlib import Path
import subprocess
import sys
root=Path(__file__).resolve().parents[3];build=Path(sys.argv[1]);build.mkdir(parents=True,exist_ok=True)
source=(root/'scripts/diagnostics/TelephonyNetworkBridge.java').read_text()
a=source.index('    private static final class PushEvents');b=source.index('    /** Local-only fake original Call',a)
publisher=source[a:b]
identity=source[source.index('    static final class CallerIdentity'):source.index('    /** Actual Call state')]
prefix=r"""
import java.io.*;import java.net.*;import java.nio.charset.*;import java.util.*;import com.sun.net.httpserver.*;
public class AndroidIngressFixture {
 static String canonicalId(String value){return UUID.fromString(value).toString();}
 static Thread daemon(String name,Runnable action){Thread thread=new Thread(action,name);thread.setDaemon(true);thread.start();return thread;}
 static class Config {final String providerUrl,providerToken="private_sentinel",pairingId="00000000-0000-4000-8000-000000000010";final InetAddress bindAddress;
  Config(String url)throws Exception{providerUrl=url;bindAddress=InetAddress.getByAddress(new byte[]{100,64,0,1});}}
 static final List<String>logs=Collections.synchronizedList(new ArrayList<>());
 static final List<String>bodies=Collections.synchronizedList(new ArrayList<>());
 static void emit(String stage,Object...fields){logs.add(stage+" "+Arrays.toString(fields));}
 static void check(boolean value,String label){if(!value)throw new AssertionError(label);}
"""
tests=r"""
 static void push(String url,boolean accepted,int status,int attempts,String error)throws Exception{
  int before=logs.size();PushEvents publisher=new PushEvents(new Config(url));publisher.publish("00000000-0000-4000-8000-000000000001",1,"ringing");publisher.close();publisher.worker.join(15000);
  check(!publisher.worker.isAlive()&&logs.size()==before+1,"one_terminal_result");String log=logs.get(before);
  check(log.contains("accepted, "+accepted)&&log.contains("http_status, "+status)&&log.contains("attempts, "+attempts)&&log.contains("error_class, "+error),"publisher_terminal_fields");
  check(!log.contains("private_sentinel")&&!log.contains("http://")&&!log.contains("pairing_id"),"publisher_redacted");
 }
 public static void main(String[]args)throws Exception{
  HttpServer server=HttpServer.create(new InetSocketAddress("127.0.0.1",0),0);int[]status={200},requests={0};
  server.createContext("/v1/calls",exchange->{requests[0]++;ByteArrayOutputStream received=new ByteArrayOutputStream();int value;while((value=exchange.getRequestBody().read())!=-1)received.write(value);bodies.add(new String(received.toByteArray(),StandardCharsets.UTF_8));int code=status[0]==-1&&requests[0]==1?503:status[0]==-1?200:status[0];byte[]body="private_sentinel".getBytes(StandardCharsets.US_ASCII);exchange.sendResponseHeaders(code,body.length);exchange.getResponseBody().write(body);exchange.close();});server.start();
  try{String url="http://127.0.0.1:"+server.getAddress().getPort();push(url,true,200,1,"none");status[0]=403;push(url,false,403,1,"none");status[0]=-1;requests[0]=0;push(url,true,200,2,"none");
   status[0]=200;CallerIdentity caller=new CallerIdentity(" 合成\"private_name_sentinel\\x\n\u007f "," +15550000001 ");PushEvents publisher=new PushEvents(new Config(url));
   publisher.publish("00000000-0000-4000-8000-000000000001",1,"ringing",caller);publisher.publish("00000000-0000-4000-8000-000000000001",2,"ended",caller);publisher.close();publisher.worker.join(15000);
   String ring=bodies.get(bodies.size()-2),ended=bodies.get(bodies.size()-1);
   check(ring.endsWith(",\"caller_name\":\"合成\\\"private_name_sentinel\\\\x\",\"caller_number\":\"+15550000001\"}"),"unicode_escape_clean_caller_payload");
   check(!ended.contains("caller_name")&&!ended.contains("caller_number"),"ended_omits_identity");
   for(String log:logs)check(!log.contains("private_name_sentinel")&&!log.contains("+15550000001"),"identity_never_logged");
  }finally{server.stop(0);}
  int unavailable;try(ServerSocket reserved=new ServerSocket(0)){unavailable=reserved.getLocalPort();}push("http://127.0.0.1:"+unavailable,false,0,3,"java.net.ConnectException");
  System.out.println("PASS actual_android_publisher optional_current_caller unicode_JSON_control_cleaning ended_omits_identity HTTP_status_retry_exception identity_redacted no_device_or_calls");
 }
}
"""
java=build/'AndroidIngressFixture.java';java.write_text(prefix+identity+publisher+tests);jdk=Path(os.environ['JAVA_HOME'])/'bin'
for phase,arguments in [('build',[str(jdk/'javac'),'--release','8',str(java)]),('result',[str(jdk/'java'),'-cp',str(build),'AndroidIngressFixture'])]:
 result=subprocess.run(arguments,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30);(build/('android-ingress-'+phase+'.log')).write_text(result.stdout)
 if result.returncode:raise RuntimeError(phase+': '+result.stdout[-5000:])
 if phase=='result':print(result.stdout.strip())
