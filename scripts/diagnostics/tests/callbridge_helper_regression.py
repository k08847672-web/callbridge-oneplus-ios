"""Run actual Provider/Binder/Claim/client code with JVM Android doubles, no device access."""
from pathlib import Path
import os, subprocess, sys
root=Path(__file__).resolve().parents[3];build=Path(sys.argv[1]);build.mkdir(parents=True,exist_ok=True)
bridge=(root/'scripts/diagnostics/TelephonyNetworkBridge.java').read_text()
a=bridge.index('    private static final class OwnedCallFailure');b=bridge.index('    private static final class Session',a)
owned=bridge[a:b].replace('Class.forName("android.app.IActivityManager")','Class.forName("FakeActivityManagerApi")').replace('Class.forName("android.app.ActivityManager")','Class.forName("FakeActivityManager")').replace('Class.forName("android.content.IContentProvider")','Class.forName("FakeProviderApi")')
helper=root/'android/callbridgehelper/src/main/java/com/doitio/callbridgehelper'
sources=[]
for name in ['CallBridgeControl.java','BridgeInCallService.java','BridgeControlProvider.java']:
 text=(helper/name).read_text();text='\n'.join(line for line in text.splitlines() if not line.startswith(('package ','import ')))
 text=text.replace('public final class ','class ');sources.append(text)
stubs=r"""
import java.io.*;import java.util.*;import java.util.concurrent.*;import java.util.concurrent.atomic.*;import java.lang.reflect.*;
class RemoteException extends Exception{RemoteException(String message){super(message);}}
interface IBinder{int FIRST_CALL_TRANSACTION=1,INTERFACE_TRANSACTION=1598968902;interface DeathRecipient{void binderDied();}boolean transact(int code,Parcel data,Parcel reply,int flags)throws RemoteException;String getInterfaceDescriptor()throws RemoteException;void linkToDeath(DeathRecipient recipient,int flags)throws RemoteException;boolean unlinkToDeath(DeathRecipient recipient,int flags);}
class Binder implements IBinder{
 static final ThreadLocal<Integer>uid=ThreadLocal.withInitial(()->2000);static int getCallingUid(){return uid.get();}
 final List<DeathRecipient>deaths=new CopyOnWriteArrayList<>();boolean dead;
 protected boolean onTransact(int code,Parcel data,Parcel reply,int flags)throws RemoteException{return false;}
 public boolean transact(int code,Parcel data,Parcel reply,int flags)throws RemoteException{return onTransact(code,data,reply,flags);}
 public String getInterfaceDescriptor()throws RemoteException{Parcel request=Parcel.obtain(),reply=Parcel.obtain();transact(INTERFACE_TRANSACTION,request,reply,0);return reply.readString();}
 public void linkToDeath(DeathRecipient recipient,int flags){deaths.add(recipient);}public boolean unlinkToDeath(DeathRecipient recipient,int flags){if(dead)throw new NoSuchElementException();return deaths.remove(recipient);}void die(){dead=true;for(DeathRecipient death:deaths)death.binderDied();deaths.clear();}
}
class Parcel{final List<Object>values=new ArrayList<>();int cursor;static Parcel obtain(){return new Parcel();}void recycle(){}void writeInterfaceToken(String value){writeString(value);}void enforceInterface(String expected){if(!expected.equals(readString()))throw new SecurityException("descriptor");}void writeStrongBinder(IBinder value){values.add(value);}IBinder readStrongBinder(){return(IBinder)values.get(cursor++);}void writeString(String value){values.add(value);}String readString(){return(String)values.get(cursor++);}void writeInt(int value){values.add(value);}int readInt(){return(Integer)values.get(cursor++);}void writeNoException(){writeInt(0);}void readException(){if(readInt()!=0)throw new IllegalStateException();}}
class Bundle{final Map<String,Object>values=new HashMap<>();void putBinder(String key,IBinder binder){values.put(key,binder);}IBinder getBinder(String key){return(IBinder)values.get(key);}void putInt(String key,int value){values.put(key,value);}int getInt(String key){return(Integer)values.get(key);}void putBoolean(String key,boolean value){values.put(key,value);}}
class Intent{}class Uri{}class ContentValues{}interface Cursor{}
class Context{void enforceCallingPermission(String permission,String reason){if(Binder.getCallingUid()!=2000)throw new SecurityException(reason);}}
class ContentProvider{final Context context=new Context();Context getContext(){return context;}public boolean onCreate(){return true;}public Bundle call(String authority,String method,String argument,Bundle extras){return null;}public Cursor query(Uri uri,String[]projection,String selection,String[]args,String order){return null;}public String getType(Uri uri){return null;}public Uri insert(Uri uri,ContentValues values){return null;}public int delete(Uri uri,String selection,String[]args){return 0;}public int update(Uri uri,ContentValues values,String selection,String[]args){return 0;}}
class Looper{static Looper getMainLooper(){return new Looper();}}
class Handler{static final ExecutorService jobs=Executors.newSingleThreadExecutor(job->{Thread thread=new Thread(job);thread.setDaemon(true);return thread;});Handler(Looper looper){}boolean post(Runnable job){jobs.execute(job);return true;}}
class SystemClock{static void sleep(long ms){try{Thread.sleep(ms);}catch(InterruptedException error){Thread.currentThread().interrupt();}}}
class Process{static int myUid(){return 2000;}static int myPid(){return 1;}}
class AttributionSource{final int uid;final String pkg;AttributionSource(int uid,String pkg){this.uid=uid;this.pkg=pkg;}static class Builder{final int uid;String pkg;Builder(int uid){this.uid=uid;}Builder setPid(int pid){return this;}Builder setPackageName(String name){pkg=name;return this;}AttributionSource build(){return new AttributionSource(uid,pkg);}}}
class VideoProfile{static final int STATE_AUDIO_ONLY=0;}
class Call{static final int STATE_RINGING=2,STATE_ACTIVE=4;volatile int state=2;int answers,ends;static class Details{static final int DIRECTION_INCOMING=0,PROPERTY_SELF_MANAGED=1,PROPERTY_IS_EXTERNAL_CALL=2;int getCallDirection(){return 0;}boolean hasProperty(int property){return false;}}int getState(){return state;}Details getDetails(){return new Details();}void answer(int video){answers++;}void disconnect(){ends++;}}
class InCallService{final List<Call>calls=new CopyOnWriteArrayList<>();List<Call>getCalls(){return calls;}public void onCreate(){}public boolean onUnbind(Intent intent){calls.clear();return false;}public void onDestroy(){}public void onCallAdded(Call call){}public void onCallRemoved(Call call){}}
interface FakeProviderApi{Bundle call(AttributionSource source,String authority,String method,String argument,Bundle extras);}
class FakeHolder{public final FakeProviderApi provider;FakeHolder(FakeProviderApi provider){this.provider=provider;}}
interface FakeActivityManagerApi{FakeHolder getContentProviderExternal(String authority,int user,IBinder token,String tag);void removeContentProviderExternalAsUser(String authority,IBinder token,int user);}
class FakeActivityManager{static final FakeManager manager=new FakeManager();public static FakeActivityManagerApi getService(){return manager;}}
class FakeManager implements FakeActivityManagerApi{int acquires,releases;boolean unavailable;final Set<IBinder>tokens=Collections.newSetFromMap(new IdentityHashMap<>());final BridgeControlProvider helper=new BridgeControlProvider();
 public FakeHolder getContentProviderExternal(String authority,int user,IBinder token,String tag){if(unavailable)return null;if(!CallBridgeControl.AUTHORITY.equals(authority)||user!=0)throw new AssertionError();acquires++;tokens.add(token);return new FakeHolder((source,name,method,argument,extras)->{if(source.uid!=2000||!"com.android.shell".equals(source.pkg))throw new AssertionError("attribution");return helper.call(name,method,argument,extras);});}
 public void removeContentProviderExternalAsUser(String authority,IBinder token,int user){if(!tokens.remove(token))throw new AssertionError("external_token_released_once");releases++;}}
"""
fixture=r"""
public class BinderOwnershipFixture{
 static Thread daemon(String name,Runnable job){Thread thread=new Thread(job,name);thread.setDaemon(true);thread.start();return thread;}
 static void join(Thread thread){if(thread!=null)try{thread.join(5000);}catch(InterruptedException error){throw new AssertionError(error);}}
 static String canonicalId(String id){return UUID.fromString(id).toString();}static void failure(String stage,Throwable error){}
"""
tests=r"""
 static void check(boolean value,String label){if(!value)throw new AssertionError(label);}
 static void until(java.util.function.BooleanSupplier condition)throws Exception{long end=System.currentTimeMillis()+5000;while(!condition.getAsBoolean()&&System.currentTimeMillis()<end)Thread.sleep(5);check(condition.getAsBoolean(),"async_state");}
 static void mainTask(Runnable job)throws Exception{FutureTask<Void>task=new FutureTask<>(job,null);Handler.jobs.execute(task);task.get(5,TimeUnit.SECONDS);}
 static int ping(IBinder control)throws Exception{Parcel data=Parcel.obtain(),reply=Parcel.obtain();data.writeInterfaceToken(CallBridgeControl.DESCRIPTOR);check(control.transact(CallBridgeControl.PING,data,reply,0),"ping_transaction");reply.readException();check(reply.readInt()==1,"protocol_version");return reply.readInt();}
 public static void main(String[]args)throws Exception{
  FakeManager manager=FakeActivityManager.manager;Bundle bootstrap=manager.helper.call(CallBridgeControl.AUTHORITY,"control",null,null);IBinder binder=bootstrap.getBinder("control");check(ping(binder)==0,"ping_without_telecom_no_call");
  Binder.uid.set(10001);try{ping(binder);throw new AssertionError("non_shell_allowed");}catch(SecurityException expected){}try{manager.helper.call(CallBridgeControl.AUTHORITY,"control",null,null);throw new AssertionError("non_shell_bootstrap_allowed");}catch(SecurityException expected){}finally{Binder.uid.set(2000);}
  try{binder.transact(CallBridgeControl.PING,Parcel.obtain(),Parcel.obtain(),0);throw new AssertionError("descriptor_not_enforced");}catch(RuntimeException expected){}
  manager.unavailable=true;try{new OwnedCall(new Context());throw new AssertionError("provider_failure_required");}catch(OwnedCallFailure expected){check(expected.reason.equals("helper_provider_unavailable"),"provider_failure_reason");}manager.unavailable=false;
  try{new OwnedCall(new Context());throw new AssertionError("no_call_required");}catch(OwnedCallFailure expected){check(expected.reason.equals("helper_no_ringing_call"),"no_call_reason");}check(manager.acquires==manager.releases,"no_call_releases_external");
  BridgeInCallService service=new BridgeInCallService();mainTask(service::onCreate);Call original=new Call();mainTask(()->{service.calls.add(original);service.onCallAdded(original);});check(ping(binder)==1&&original.answers==0&&original.ends==0,"ping_is_read_only");
  String stable;
  try(OwnedCall owned=new OwnedCall(new Context())){
   owned.observeBeforeAnswer();stable=owned.callId;owned.disconnect();check(original.ends==0,"ringing_not_disconnected");owned.answer();owned.answer();check(original.answers==1,"answer_original_once");check(owned.state==1,"answer_pending_still_ringing");
   original.state=Call.STATE_ACTIVE;until(owned::active);Call other=new Call();other.state=Call.STATE_ACTIVE;service.calls.add(other);owned.disconnect();owned.disconnect();check(original.ends==1&&other.ends==0,"only_exact_original_disconnected_once");service.calls.remove(other);
  }
  original.state=Call.STATE_RINGING;original.answers=original.ends=0;
  OwnedCall dead=new OwnedCall(new Context());dead.observeBeforeAnswer();check(stable.equals(dead.callId),"same_original_uuid");((Binder)dead.owner).die();until(()->dead.state==0);check(original.ends==0,"client_death_no_hangup");
  try(OwnedCall replacement=new OwnedCall(new Context())){dead.close();replacement.observeBeforeAnswer();check(replacement.state==1,"old_release_does_not_release_new_owner");original.state=Call.STATE_ACTIVE;until(()->replacement.state==0);check(original.ends==0&&original.answers==0,"manual_answer_not_adopted");}
  original.state=Call.STATE_RINGING;try(OwnedCall removed=new OwnedCall(new Context())){removed.answer();original.state=Call.STATE_ACTIVE;until(removed::active);Call other=new Call();other.state=Call.STATE_ACTIVE;mainTask(()->{service.calls.remove(original);service.calls.add(other);service.onCallRemoved(original);});until(()->removed.state==0);removed.disconnect();check(original.ends==0&&other.ends==0,"removed_original_no_replacement_fallback");}
  mainTask(()->{service.calls.clear();original.state=Call.STATE_RINGING;service.calls.add(original);service.onCallAdded(original);});
  try(OwnedCall unbound=new OwnedCall(new Context())){mainTask(()->service.onUnbind(new Intent()));until(()->unbound.state==0);check(original.ends==0,"telecom_unbind_releases_without_hangup");}
  mainTask(()->{service.calls.add(original);service.onCallAdded(original);});try(OwnedCall rebound=new OwnedCall(new Context())){rebound.observeBeforeAnswer();}
  mainTask(service::onDestroy);check(manager.tokens.isEmpty()&&manager.acquires==manager.releases,"single_external_token_balanced_all_paths");
  System.out.println("PASS actual_provider_binder_client UID_and_descriptor_enforced explicit_shell_attribution no_call_cleanup pending_answer original_UUID answer_once exact_disconnect_once owner_death_release manual_call_untouched no_replacement balanced_external_tokens");
 }
}
"""
java=build/'BinderOwnershipFixture.java';java.write_text(stubs+'\n'.join(sources)+fixture+owned+tests)
jdk=Path(os.environ['JAVA_HOME'])/'bin'
for phase,arguments in [('build',[str(jdk/'javac'),'--release','8',str(java)]),('result',[str(jdk/'java'),'-cp',str(build),'BinderOwnershipFixture'])]:
 result=subprocess.run(arguments,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30);(build/('binder-'+phase+'.log')).write_text(result.stdout)
 if result.returncode:raise RuntimeError(phase+': '+result.stdout[-5000:])
 if phase=='result':print(result.stdout.strip())
