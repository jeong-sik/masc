#!/usr/bin/env python3
"""Prepared owned PTY request/state experiment. No screen/layout/paint assertions.

--preflight-only hashes local inputs and exits before any binary/API/PTY activity.
Without that flag this starts owned children and makes synthetic canonical writes.
"""
import argparse
import collections
import ctypes
import math
import sys
import fcntl
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pty
import select
import signal
import socket
import struct
import subprocess
import termios
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

SOURCE = 'a3950a189b9cc5a7ce82cb725699455d79923f42'
SERVER_SHA = '1622a35d1082da4fe24d9effb05aec11918d9444288441049c8d6d30cedb415c'
TUI_SHA = 'b0a45e199a808f1968265056b78bc755021a4b1a475093cb7c51356a295ee6ca'
ARCHIVE_SHA = 'a9e1eff4b3ddc6b43c14fa2fc48b7f468634d902ff487d9337b57bc4f5cb5927'
WORKFLOW_SHA = '9377c7f3025d68e3856d2afd3762468dabc77813'
RUN = 40396800146
ARTIFACT = 12687003191
QQUALIFY_SHA = '6799826b1d8843e93993a283f98059efd9f9c93787bfae29d823bdcc557b608f'
FIXTURE_SHA = 'ccbe65e399f47a3abddbf4299e15dd0fd55001dd785b2e0d75948ad86acf7cfd'
AUTHORITY_SOURCE_BINDINGS = {'bin/main_eio.ml': {'bytes': 220221, 'sha256': '107443640cec4d076a9c67d33c8ef4207fd94ab95b024fb27a60a0952e6d6ae3'}, 'lib/server/server_runtime_bootstrap.ml': {'bytes': 95871, 'sha256': '70b89b1637c5a57425626d89746279ad6bb9c6c1905ca3bada6efbe6813ddcd1'}, 'lib/server/server_bootstrap_http.ml': {'bytes': 16029, 'sha256': '003594554846ddd2c7f293aaff6531c8512ea910ad27f99ed2d96b6b71056057'}, 'lib/server/server_request_authority.ml': {'bytes': 16197, 'sha256': '46644bc6bf21f338c5a0585b01432c13e5037b990a35ffbbf507892d020eecfb'}, 'lib/config/env_config_core.ml': {'bytes': 29711, 'sha256': '550081ed2f0279101b53faf2740afd2435f5b333c556bccda9dd3a51dfa28026'}, 'lib/config/config_boot_overrides.ml': {'bytes': 1297, 'sha256': 'ae3c03ea7dd01e9273d0f89d50c6dd2ac6277465b73698636c4947ef917996df'}, 'lib/config/keeper_runtime_setting_registry.ml': {'bytes': 42929, 'sha256': 'b55309eb63365d9ab20b34588037e94f8593e3c1411ebada8eb092024c82062e'}, 'lib/keeper_runtime/keeper_runtime_config.ml': {'bytes': 23229, 'sha256': '5f7f7da0bec077867674d6824cb7b621e91485897e39b7098bdcab4b3bd4d884'}, 'docs/KEEPER-IDENTITY-MANUAL.md': {'bytes': 9394, 'sha256': '5bac70fe374820f52a4dab4dcaf226ef9c11a9aa0156186f33400716083f06b0'}}
AUTHORITY_SOURCE_BINDINGS['lib/server/server_routes_http_runtime.ml'] = {'bytes': 72498, 'sha256': '0019203a8e2ccf44768aed74fe65bcf56c9728a299b3e631cf715bec206d9d74'}
MAX_CAPTURE = 8 * 1024 * 1024  # existing qualify.py measurement envelope, not a runtime gate
DROP = {'authorization','cookie','set-cookie','token','access_token','refresh_token',
        'chat_control_token','interrupt_token','mcp_session_id','bearer_token'}

class Incomplete(RuntimeError): pass
class BehaviorFailure(RuntimeError): pass

def clean(value):
    if isinstance(value, dict): return {k:clean(v) for k,v in value.items() if k.lower() not in DROP}
    if isinstance(value, list): return [clean(v) for v in value]
    if isinstance(value, str):
        try: decoded=json.loads(value)
        except ValueError: return value
        if isinstance(decoded,(dict,list)): return json.dumps(clean(decoded),ensure_ascii=False)
    return value

def sha(path):
    with path.open('rb') as stream: return hashlib.file_digest(stream,'sha256').hexdigest()

def file_identity(path): return {'path':str(path),'sha256':sha(path),'bytes':path.stat().st_size}

def selected_json(path, raw):
    data=json.loads(raw)
    if urllib.parse.urlsplit(path).path=='/health':
        # Health rejection codes are safe prerequisite evidence; no arbitrary
        # response body, credentials, instructions or full health are retained.
        return {k:clean(data[k]) for k in ['build','paths','startup','error_code','error'] if k in data}
    return clean(data)

# macOS process identity uses kernel argv boundaries, not a parsed ps command
# string. Local SDK libproc.h/proc_info.h/sysctl.h define these interfaces.
class BSDInfo(ctypes.Structure):
    _fields_ = [(name,ctypes.c_uint32) for name in
        ['flags','status','xstatus','pid','ppid','uid','gid','ruid','rgid','svuid','svgid','reserved']] + [
        ('comm',ctypes.c_char*16),('name',ctypes.c_char*32)] + [(name,ctypes.c_uint32) for name in
        ['nfiles','pgid','pjobc','ttydev','ttypgid']] + [
        ('nice',ctypes.c_int32),('start_sec',ctypes.c_uint64),('start_usec',ctypes.c_uint64)]


class MacProcessIdentity:
    def __init__(self):
        if sys.platform!='darwin':raise Incomplete('this pinned native experiment requires macOS')
        self.proc=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
        self.libc=ctypes.CDLL('/usr/lib/libSystem.B.dylib',use_errno=True)
        self.proc.proc_pidinfo.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_uint64,ctypes.c_void_p,ctypes.c_int]
        self.proc.proc_pidinfo.restype=ctypes.c_int
        self.proc.proc_pidpath.argtypes=[ctypes.c_int,ctypes.c_void_p,ctypes.c_uint32]
        self.proc.proc_pidpath.restype=ctypes.c_int
        self.libc.sysctl.argtypes=[ctypes.POINTER(ctypes.c_int),ctypes.c_uint,ctypes.c_void_p,ctypes.POINTER(ctypes.c_size_t),ctypes.c_void_p,ctypes.c_size_t]
        self.libc.sysctl.restype=ctypes.c_int
    def bsd(self,pid):
        info=BSDInfo()
        if self.proc.proc_pidinfo(pid,3,0,ctypes.byref(info),ctypes.sizeof(info))!=ctypes.sizeof(info):return None
        return info
    def read(self,pid,expected_executable):
        before=self.bsd(pid)
        if before is None:return None
        path=ctypes.create_string_buffer(4096) # PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN
        if self.proc.proc_pidpath(pid,path,len(path))<=0:return None
        executable=os.fsdecode(path.value)
        if Path(executable).resolve()!=expected_executable.resolve():return None
        argmax=ctypes.c_int();size=ctypes.c_size_t(ctypes.sizeof(argmax))
        key=(ctypes.c_int*2)(1,8) # CTL_KERN, KERN_ARGMAX
        if self.libc.sysctl(key,2,ctypes.byref(argmax),ctypes.byref(size),None,0)!=0 or argmax.value<=0:
            raise Incomplete('kernel argv envelope unavailable')
        buffer=ctypes.create_string_buffer(argmax.value);size=ctypes.c_size_t(len(buffer))
        key=(ctypes.c_int*3)(1,49,pid) # CTL_KERN, KERN_PROCARGS2, pid
        if self.libc.sysctl(key,3,buffer,ctypes.byref(size),None,0)!=0:return None
        raw=buffer.raw[:size.value]
        if len(raw)<4:return None
        argc=struct.unpack_from('i',raw)[0]
        if argc<1:return None
        end=raw.find(b'\0',4)
        if end<0:return None
        cursor=end+1
        while cursor<len(raw) and raw[cursor]==0:cursor+=1
        argv=[]
        for _ in range(argc):
            end=raw.find(b'\0',cursor)
            if end<0:return None
            argv.append(os.fsdecode(raw[cursor:end]));cursor=end+1
        # Do not parse, emit or persist the environment following argc arguments.
        after=self.bsd(pid)
        if after is None or (before.pid,before.start_sec,before.start_usec)!=(after.pid,after.start_sec,after.start_usec):return None
        return {'pid':pid,'ppid':after.ppid,'uid':after.uid,'start_sec':after.start_sec,
                'start_usec':after.start_usec,'executable':executable,'argv':argv}


def refuse_primary_port(port):
    if port==8935:raise Incomplete('refusing shared-primary port 8935; no automatic port retry')

class HTTPFrames:
    """Passive HTTP/1 framing only. Original socket bytes never come from here.

    Unsupported/malformed capture disables observation for that connection; the
    byte relay continues. No identity/header/body rewrite or guessed response.
    """
    def __init__(self, direction, conversation):
        self.direction=direction;self.c=conversation;self.buf=b'';self.mode='headers';self.disabled=False
        self.remaining=0;self.body=bytearray();self.capture=False;self.meta=None
    def fail(self):
        self.disabled=True;self.buf=b'';self.body.clear()
        self.c.relay.error('http_capture_unavailable',self.direction)
    def finish(self):
        if self.direction=='request':
            self.meta['body']=bytes(self.body) if self.capture else None
        else:
            self.c.response(self.meta,bytes(self.body) if self.capture else None)
        self.mode='headers';self.body=bytearray();self.meta=None
    def consume(self, data):
        if self.disabled:return
        self.buf+=data
        try:
            while True:
                if self.mode=='headers':
                    end=self.buf.find(b'\r\n\r\n')
                    if end<0:
                        if len(self.buf)>65536:self.fail() # HTTP parser envelope, no forwarded limit
                        return
                    lines=self.buf[:end].decode('iso-8859-1').split('\r\n');self.buf=self.buf[end+4:]
                    headers={}
                    for line in lines[1:]:
                        key,value=line.split(':',1);key=key.lower()
                        if key in headers and key in {'content-length','transfer-encoding','content-encoding','x-masc-agent'}: raise ValueError('ambiguous capture header')
                        headers[key]=value.strip()
                    if self.direction=='request':
                        method,path,version=lines[0].split(' ',2)
                        self.meta={'method':method,'path':path,'agent':headers.get('x-masc-agent'),
                                   'started_at':time.time(),'body':None}
                        self.capture=self.c.relay.whitelist(method,path)
                        self.meta['selected']=self.capture
                        with self.c.lock:self.c.pending.append(self.meta)
                        no_body='content-length' not in headers and 'transfer-encoding' not in headers
                    else:
                        _,status,_=lines[0].split(' ',2);status=int(status)
                        if 100<=status<200:
                            if status==101:self.fail();return
                            continue
                        with self.c.lock:
                            if not self.c.pending:raise ValueError('unmatched response')
                            request=self.c.pending.popleft()
                        self.meta={'request':request,'status':status,'encoding':headers.get('content-encoding')}
                        self.capture=request['selected']
                        no_body=request['method']=='HEAD' or status in [204,304]
                    if no_body:self.finish();continue
                    if headers.get('transfer-encoding','').lower()=='chunked':self.mode='chunk-size'
                    elif 'content-length' in headers:
                        self.remaining=int(headers['content-length']);self.mode='fixed'
                        if self.remaining<0:raise ValueError('negative length')
                    elif self.direction=='response':self.mode='until-close'
                    else:raise ValueError('unsupported request framing')
                elif self.mode=='chunk-size':
                    end=self.buf.find(b'\r\n')
                    if end<0:return
                    self.remaining=int(self.buf[:end].split(b';',1)[0],16);self.buf=self.buf[end+2:]
                    self.mode='trailers' if self.remaining==0 else 'chunk-body'
                elif self.mode=='trailers':
                    if self.buf.startswith(b'\r\n'):self.buf=self.buf[2:];self.finish();continue
                    end=self.buf.find(b'\r\n\r\n')
                    if end<0:return
                    self.buf=self.buf[end+4:];self.finish()
                elif self.mode=='chunk-end':
                    if len(self.buf)<2:return
                    if self.buf[:2]!=b'\r\n':raise ValueError('invalid chunk separator')
                    self.buf=self.buf[2:];self.mode='chunk-size'
                else:
                    count=len(self.buf) if self.mode=='until-close' else min(self.remaining,len(self.buf))
                    if self.capture:
                        self.body.extend(self.buf[:count])
                        if len(self.body)>MAX_CAPTURE:raise ValueError('capture envelope exceeded')
                    self.buf=self.buf[count:]
                    if self.mode=='until-close':return
                    self.remaining-=count
                    if self.remaining:return
                    if self.mode=='fixed':self.finish()
                    else:self.mode='chunk-end'
        except (ValueError,KeyError,UnicodeError):self.fail()
    def eof(self):
        if self.mode=='until-close' and not self.disabled:self.finish()
        elif self.mode!='headers' and not self.disabled:self.fail()

class Conversation:
    def __init__(self, relay):self.relay=relay;self.pending=collections.deque();self.lock=threading.Lock()
    def response(self, metadata, raw):
        request=metadata['request']
        if not request['selected']:return
        try:
            body=raw or b''
            decoded=gzip.decompress(body) if metadata['encoding']=='gzip' else body
            if metadata['encoding'] not in [None,'identity','gzip']:raise ValueError('encoding')
            response=selected_json(request['path'],decoded) if decoded else None
            submitted=json.loads(request['body']) if request['body'] else None
            self.relay.record({'method':request['method'],'path':request['path'],'agent':request['agent'],
                'request_started_at':request['started_at'],'response_completed_at':time.time(),
                'request_body':clean(submitted),'status':metadata['status'],'response':response,
                'response_entity_sha256':hashlib.sha256(body).hexdigest(),'response_entity_bytes':len(body),
                'scope':'Selected decoded entity; auth/cookie/session headers never retained; raw forwarding unchanged.'})
        except Exception:self.relay.error('selected_json_unavailable','response')

class Relay:
    def __init__(self, upstream, names, operations, output):
        self.upstream=upstream;self.names=names;self.operations=operations;self.output=output
        self.lock=threading.Lock();self.events=[];self.errors=[];self.sockets=[];self.stopped=threading.Event()
        self.listener=socket.socket();self.listener.bind(('127.0.0.1',0));self.listener.listen()
        self.port=self.listener.getsockname()[1]
        try:
            refuse_primary_port(self.port)
            if self.port==upstream:raise Incomplete('relay and upstream ports must be distinct')
        except BaseException:self.listener.close();raise
    def whitelist(self, method, path):
        parsed=urllib.parse.urlsplit(path);query=urllib.parse.parse_qs(parsed.query)
        if method=='GET' and parsed.path=='/health':return query in [{}, {'full':['1']}]
        if method=='GET' and parsed.path=='/api/v1/dashboard/scheduled-automation':
            return not query or query in [{'payload_target':['keeper:'+name]} for name in self.names]
        return any(parsed.path in [f'/api/v1/keepers/{name}/chat/operations/{operation}',
                                   f'/api/v1/keepers/{name}/chat/operations/{operation}/edit']
                   and method in ['GET','POST'] and not parsed.query
                   for name,operation in self.operations.items())
    def record(self,event):
        with self.lock:
            self.events.append(event);self.flush()
    def error(self,kind,direction):
        with self.lock:self.errors.append({'kind':kind,'direction':direction,'at':time.time()});self.flush()
    def flush(self):
        try:(self.output/'tui-http-selected.json').write_text(json.dumps({'events':self.events,'capture_errors':self.errors},indent=2)+'\n')
        except OSError:self.errors.append({'kind':'capture_write_failed','at':time.time()})
    def forward(self, source, destination, parser):
        try:
            while True:
                data=source.recv(65536)
                if not data:parser.eof();break
                try:parser.consume(data) # passive copy; forwarding never uses parser output
                except Exception:parser.fail()
                destination.sendall(data)
        except OSError:pass
        finally:
            try:destination.shutdown(socket.SHUT_WR)
            except OSError:pass
    def serve(self):
        while not self.stopped.is_set():
            try:client,_=self.listener.accept()
            except OSError:return
            try:upstream=socket.create_connection(('127.0.0.1',self.upstream),timeout=15);upstream.settimeout(None)
            except OSError:client.close();self.error('upstream_unavailable','connect');continue
            self.sockets.extend([client,upstream]);conversation=Conversation(self)
            for source,dest,direction in [(client,upstream,'request'),(upstream,client,'response')]:
                threading.Thread(target=self.forward,args=(source,dest,HTTPFrames(direction,conversation)),daemon=True).start()
    def start(self):threading.Thread(target=self.serve,daemon=True).start()
    def close(self):
        self.stopped.set();self.listener.close()
        for sock in self.sockets:
            try:sock.shutdown(socket.SHUT_RDWR)
            except OSError:pass
            sock.close()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root',type=Path,required=True)
    parser.add_argument('--native-dir',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--image-reference',required=True)
    parser.add_argument('--observation-deadline-unix',type=float,required=True)
    parser.add_argument('--preflight-only',action='store_true')
    args=parser.parse_args();repo=args.source_root.resolve(strict=True);native=args.native_dir.resolve(strict=True)
    server_bin=native/'artifact/masc';tui_bin=native/'artifact/masc-tui';verification=json.loads((native/'identity-verification.json').read_text())
    if (sha(server_bin)!=SERVER_SHA or sha(tui_bin)!=TUI_SHA or sha(native/'artifact.zip')!=ARCHIVE_SHA
        or verification['source_input']!=SOURCE or verification['workflow_execution_head']!=WORKFLOW_SHA
        or verification['run_id']!=RUN or verification['artifact_id']!=ARTIFACT):raise Incomplete('native identity mismatch')
    for executable,digest,command in [('masc',SERVER_SHA,'build-commit'),('masc-tui',TUI_SHA,'--build-commit')]:
        matches=[row for row in verification['observations'] if row['executable']==executable]
        if len(matches)!=1 or matches[0]['sha256']!=digest or matches[0]['args']!=[command] or matches[0]['exit_code']!=0 or matches[0]['stdout_utf8']!=SOURCE+'\n':raise Incomplete('native prior CLI observation mismatch')
    receipt=json.loads((native/'artifact/receipt.json').read_text())
    if receipt['source_sha']!=SOURCE or receipt['workflow_sha']!=WORKFLOW_SHA or receipt['server_sha256']!=SERVER_SHA or receipt['sha256']!=TUI_SHA:raise Incomplete('artifact receipt mismatch')
    output=args.output.resolve()
    if output.exists() or not output.is_relative_to(repo/'artifacts'):raise Incomplete('new owned artifact output required')
    if not math.isfinite(args.observation_deadline_unix) or args.observation_deadline_unix<=time.time():raise Incomplete('finite future observation deadline required')
    inputs=[server_bin,tui_bin,native/'artifact.zip',native/'artifact/receipt.json',native/'identity-verification.json',repo/'scripts/lane-addons/qualify.py',repo/'scripts/fixtures/release-evidence/runtime.toml']
    for relative,bound in AUTHORITY_SOURCE_BINDINGS.items():
        path=repo/relative
        if path.stat().st_size!=bound['bytes'] or sha(path)!=bound['sha256']:
            raise Incomplete('frozen request-identity source binding mismatch: '+relative)
        inputs.append(path)
    bindings=[file_identity(p) for p in inputs]
    if sha(repo/'scripts/lane-addons/qualify.py')!=QQUALIFY_SHA or sha(repo/'scripts/fixtures/release-evidence/runtime.toml')!=FIXTURE_SHA:raise Incomplete('canonical helper or boot fixture changed')
    if args.preflight_only:
        print(json.dumps({'scope':'file-only preflight; no binary/API/PTY/model execution','source':SOURCE,'inputs':bindings}));return
    # Import the existing guarded collector only after native/local preflight.
    spec=importlib.util.spec_from_file_location('qqualify',repo/'scripts/lane-addons/qualify.py')
    q=importlib.util.module_from_spec(spec);spec.loader.exec_module(q)
    output.mkdir(mode=0o700,parents=True);base=output/'workspace';base.mkdir();(base/'.masc/config').mkdir(parents=True)
    env={k:v for k,v in os.environ.items() if k in ['PATH','HOME','LANG','LC_ALL','TMPDIR']}
    env.update(MASC_BASE_PATH=str(base),MASC_CONFIG_DIR=str(base/'.masc/config'),XDG_CONFIG_HOME=str(output/'.xdg-config'),
               MASC_KEEPER_AUTONOMOUS_ENABLED='false',MASC_SCHEDULE_RUNNER_INTERVAL_SEC='1',TERM='xterm-256color')
    setup_handles=[];utility_handles=[];lifecycle=[];observed_fallbacks={};lifecycle_incomplete=False
    identity_reader=None;startup_output_path=None;startup_baseline=None;port=None;token=None;api=None;evidence=None
    actor='tui-probe-admin'
    def remaining():
        left=args.observation_deadline_unix-time.time()
        if not math.isfinite(left) or left<=0:raise Incomplete('observer deadline reached before owned CLI start')
        return left
    def command(argv,stage):
        remaining()
        child=subprocess.Popen(argv,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
        receipt={'stage':stage,'pid':child.pid,'argv':argv,'started_at':time.time(),
                 'observation_deadline_unix':args.observation_deadline_unix,'returncode':None,'timed_out':False,
                 'stdout_stderr_retained':False,'scope':'Owned canonical setup CLI; output withheld including login output.'}
        setup_handles.append((child,receipt));save('setup-cli-handles.json',[row for _,row in setup_handles])
        try:child.wait(timeout=max(0,args.observation_deadline_unix-time.time()))
        except subprocess.TimeoutExpired:
            receipt.update(timed_out=True,observed_at=time.time(),returncode=child.poll())
            save('setup-cli-handles.json',[row for _,row in setup_handles])
            raise Incomplete('setup CLI observation expired; child handle retained, no kill or automatic retry')
        receipt.update(returncode=child.returncode,observed_at=time.time());save('setup-cli-handles.json',[row for _,row in setup_handles])
        if child.returncode:raise Incomplete('owned canonical setup CLI failed; output withheld')
    class SelectedEvidence(q.Evidence):
        def record(self,event,raw=b''):
            event=clean(event);event['original_body_sha256']=hashlib.sha256(raw).hexdigest();event['original_body_bytes']=len(raw)
            selected=selected_json(event.get('path',''),raw) if raw else None
            event['is_derivative']=True
            return super().record(event,json.dumps(selected,ensure_ascii=False).encode())
    checks=[];inputs_trace=[];server=None;relay=None;tui_pid=None;master=None;drain_stop=threading.Event();drain_thread=None;tui_exit=None
    def save(name,value):(output/name).write_text(json.dumps(clean(value),indent=2)+'\n')
    def check(name,condition,detail=None):
        try:checks.append({'name':name,'passed':bool(condition),'detail':clean(detail)});save('checks.json',checks)
        finally:
            if not condition:raise BehaviorFailure(name)
    def process_inventory(stage,cleanup=False):
        if identity_reader is None:return {'stage':stage,'available':False,'reason':'identity reader not initialized'}
        # ps supplies numeric PID/UID columns only. Executable/argv/start cookie
        # come independently from libproc/sysctl, not command-line text matching.
        timeout=15 if cleanup else remaining()
        child=subprocess.Popen(['/bin/ps','-axo','pid=,uid='],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
        handle={'pid':child.pid,'stage':stage,'argv':['/bin/ps','-axo','pid=,uid='],'returncode':None}
        utility_handles.append((child,handle))
        try:raw,_=child.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            handle.update(timed_out=True,returncode=child.poll());save('inventory-cli-handles.json',[row for _,row in utility_handles])
            raise Incomplete('process inventory command unfinished; no hidden kill')
        handle['returncode']=child.returncode
        if child.returncode:raise Incomplete('numeric process inventory unavailable')
        selected=[]
        for line in raw.splitlines():
            pid_text,uid_text=line.split();pid=int(pid_text)
            if int(uid_text)!=os.getuid():continue
            before=identity_reader.bsd(pid)
            if before is None:continue # process vanished before inspection
            candidate=identity_reader.read(pid,server_bin)
            if candidate is None or candidate['uid']!=os.getuid():continue
            argv=candidate['argv']
            if len(argv)<2 or argv[1]!='start':continue
            fields=[i for i,value in enumerate(argv) if value=='--base-path']
            if len(fields)!=1 or fields[0]+1>=len(argv) or argv[fields[0]+1]!=str(base):continue
            allowed=[server_argv(port),server_argv(relay.port)] if relay is not None else [server_argv(port)]
            if argv not in allowed:
                selected.append({k:candidate[k] for k in ['pid','ppid','uid','start_sec','start_usec','executable']}|{
                    'canonical_argv_verified':False,'argv_sha256':hashlib.sha256(json.dumps(argv).encode()).hexdigest(),
                    'owned_base_field_verified':True})
            else:selected.append({**candidate,'canonical_argv_verified':True,'owned_base_field_verified':True})
        return {'stage':stage,'observed_at':time.time(),'available':True,'servers':selected,
                'scope':'Current readable same-user exact native executable + exact owned base + argv/start cookie. No historical all-process/no-ever-spawn claim.'}
    def server_argv(selected_port):
        return [str(server_bin),'start','--base-path',str(base),'--host','127.0.0.1','--port',str(selected_port)]
    def startup_output_observation():
        if startup_output_path is None:return None
        try:
            with startup_output_path.open('rb') as stream:
                before=os.fstat(stream.fileno());raw=stream.read();after=os.fstat(stream.fileno())
            return {'path':str(startup_output_path),'exists':True,'bytes_read':len(raw),'sha256':hashlib.sha256(raw).hexdigest(),
                    'device':after.st_dev,'inode':after.st_ino,'mtime_ns':after.st_mtime_ns,
                    'changed_during_read':(before.st_size,before.st_mtime_ns)!=(after.st_size,after.st_mtime_ns),
                    'content_retained':False,'meaning':'Canonical startup-output file is opened before spawn; existence proves an attempt, not a live/successful child.'}
        except FileNotFoundError:return {'path':str(startup_output_path),'exists':False}
    def lifecycle_boundary(stage,cleanup=False):
        nonlocal lifecycle_incomplete
        inventory=process_inventory(stage,cleanup=cleanup);log_observation=startup_output_observation()
        unexpected=[]
        for row in inventory.get('servers',[]):
            if server is None or row['pid']!=server.pid:
                unexpected.append(row)
                if row.get('canonical_argv_verified'):
                    observed_fallbacks[(row['pid'],row['start_sec'],row['start_usec'])]=row
        attempt=bool(startup_baseline is not None and not startup_baseline['exists'] and log_observation and log_observation['exists'])
        if unexpected or attempt:lifecycle_incomplete=True
        event={'stage':stage,'inventory':inventory,'startup_output':log_observation,'unexpected_servers':unexpected,
               'new_startup_attempt_file':attempt,'no_unobserved_spawn_claim':False}
        lifecycle.append(event);save('owned-lifecycle.json',lifecycle)
        if not cleanup and (unexpected or attempt):raise Incomplete('unexpected owned-base server/start attempt observed; no attach-only or clean-trial PASS')
        return inventory
    def signal_reverified_server(record):
        if sha(server_bin)!=SERVER_SHA:raise Incomplete('pinned server executable changed; no signal')
        current=identity_reader.read(record['pid'],server_bin)
        if current is None:return {'pid':record['pid'],'signal_sent':False,'state':'not reverified; no signal','exit_status':None}
        stable=all(current[key]==record[key] for key in ['pid','uid','start_sec','start_usec','executable','argv'])
        if not stable:return {'pid':record['pid'],'signal_sent':False,'state':'identity changed; no signal','exit_status':None}
        # Exact argv already belongs to this fresh base and one of the two
        # verified owned ports. Never kill by substring, process name or group.
        try:os.kill(current['pid'],signal.SIGTERM)
        except OSError as error:
            return {'identity':current,'signal_sent':False,'error_type':type(error).__name__,'exit_status':None}
        return {'identity':current,'signal_sent':True,'signal':'SIGTERM','exit_status':None,
                'scope':'Non-child disappearance cannot establish exit status.'}
    def open_observation():
        nonlocal tui_exit
        if tui_pid is not None and tui_exit is None:
            done,status=os.waitpid(tui_pid,os.WNOHANG)
            if done:tui_exit=os.waitstatus_to_exitcode(status)
        if tui_exit is not None:raise Incomplete('owned TUI exited before request/state observation completed')
        if time.time()>=args.observation_deadline_unix:raise Incomplete('observer deadline; not producer completion')
        if server is not None and server.poll() is not None:raise Incomplete('owned server exited')
    def wait_for(fn):
        while True:
            open_observation();value=fn()
            if value:return value
            time.sleep(.2)
    def get(path,stage):return api.request('GET',path,stage=stage)
    session=None;request_id=0
    def rpc(payload):
        nonlocal session
        headers={**api.headers,'Content-Type':'application/json','Accept':'application/json, text/event-stream','Mcp-Protocol-Version':'2025-11-25'}
        if session:headers['Mcp-Session-Id']=session
        req=urllib.request.Request(api.base+'/mcp',data=json.dumps(payload).encode(),headers=headers,method='POST')
        with api.opener.open(req,timeout=15) as response:
            raw=response.read(MAX_CAPTURE+1);status=response.status
            received=response.headers.get('Mcp-Session-Id');session=received or session
        if len(raw)>MAX_CAPTURE:raise Incomplete('MCP capture envelope exceeded')
        try:data=json.loads(raw)
        except ValueError:data=next(json.loads(line[5:]) for line in raw.decode().splitlines() if line.startswith('data:'))
        evidence.record({'stage':'canonical-fixture','method':'POST','path':'/mcp','request_body':payload,'status':status},json.dumps(data).encode())
        return data
    def tool(name,body):
        nonlocal request_id
        if session is None:
            request_id+=1;rpc({'jsonrpc':'2.0','id':request_id,'method':'initialize','params':{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'owned-tui-probe','version':'1'}}})
        request_id+=1;reply=rpc({'jsonrpc':'2.0','id':request_id,'method':'tools/call','params':{'name':name,'arguments':body}})
        if 'error' in reply or reply['result'].get('isError'):raise Incomplete('canonical fixture tool refused: '+name)
        result=reply['result'];value=result.get('structuredContent')
        if value is None:value=json.loads(next(c['text'] for c in result['content'] if c.get('type')=='text'))
        if isinstance(value,dict) and isinstance(value.get('data'),dict):value=value['data']
        if isinstance(value,dict) and isinstance(value.get('message'),str):
            try:decoded=json.loads(value['message'])
            except ValueError:decoded=None
            if isinstance(decoded,dict):value=decoded
        return value
    names=['audit-tui-a','audit-tui-b'];operations={name:'tui-draft-'+uuid.uuid4().hex for name in names}
    seeds={name:'TUI_SEED_'+uuid.uuid4().hex for name in names};marker='TUI_DRAFT_'+uuid.uuid4().hex
    def paused(name):
        inventory=get('/api/v1/keepers/'+name+'/waiting-inventory','pause-proof')
        entries=inventory.get('keepers',[])
        check('owned owner is paused with no current execution '+name,
              len(entries)==1 and entries[0].get('keeper_name')==name and entries[0].get('paused') is True
              and 'current_execution' in entries[0] and entries[0]['current_execution'] is None)
        status=tool('masc_keeper_status',{'name':name,'fast':True});meta=status.get('meta',{})
        check('owned owner remains manual paused and zero-turn '+name,
              status.get('activation_mode')=='manual' and meta.get('paused') is True
              and meta.get('total_turns')==0 and meta.get('last_turn_ts')==0
              and 'last_runtime_attempt' in meta and meta['last_runtime_attempt'] is None)
    def op_path(name):return '/api/v1/keepers/'+name+'/chat/operations/'+operations[name]
    def operation(name,stage):
        result=get(op_path(name),stage)
        required={'operation_id','state','input','source','sequence','admission_digest','execution_digest'}
        check('exact operation is queued and has not started '+name,required<=result.keys()
              and result['operation_id']==operations[name] and result['state']=='Queued'
              and 'started_at' not in result and 'completed_at' not in result and 'batch_execution_id' not in result)
        return result
    def queue_only(name,workspace):
        paused(name)
        body={'request_id':operations[name],'name':name,'message':seeds[name],'expected_workspace':workspace}
        req=urllib.request.Request(api.base+'/api/v1/keepers/chat/stream',data=json.dumps(body).encode(),
            headers={**api.headers,'Content-Type':'application/json','Accept':'text/event-stream'},method='POST')
        accepted=None;data=[]
        with api.opener.open(req,timeout=15) as response:
            if response.status!=200:raise Incomplete('queue-only stream not accepted')
            while accepted is None:
                open_observation();line=response.readline()
                if not line:raise Incomplete('queue-only stream ended before acceptance')
                if line.startswith(b'data:'):data.append(line[5:].strip())
                elif line in [b'\n',b'\r\n'] and data:
                    event=json.loads(b'\n'.join(data));data=[]
                    if event.get('type')=='RUN_ERROR':raise Incomplete('queue-only admission returned RUN_ERROR')
                    if event.get('type')=='CUSTOM' and event.get('name')=='KEEPER_CHAT_OPERATION_ACCEPTED':accepted=event['value']
        check('durable Queue_only admission accepted '+name,accepted.get('operation_id')==operations[name] and accepted.get('state')=='Queued',accepted)
        save('queue-accepted-'+name+'.json',{'request':body,'accepted':accepted,'scope':'client stream closed only after accepted Queued; no cancel/resume'})
        original=operation(name,'queue-original');paused(name);return original
    def input_bytes(label,data):
        stamp=time.time();written=os.write(master,data);inputs_trace.append({'label':label,'at':stamp,'bytes_hex':data[:written].hex(),'requested_bytes':len(data),'written_bytes':written});save('pty-input-trace.json',inputs_trace)
        if written!=len(data):raise Incomplete('partial PTY input write; no automatic replay')
        return stamp
    def resize(cols,rows):
        fcntl.ioctl(master,termios.TIOCSWINSZ,struct.pack('HHHH',rows,cols,0,0))
        actual_rows,actual_cols,_,_=struct.unpack('HHHH',fcntl.ioctl(master,termios.TIOCGWINSZ,b'\0'*8))
        if (actual_rows,actual_cols)!=(rows,cols):raise Incomplete('kernel PTY size readback mismatch')
        os.kill(tui_pid,signal.SIGWINCH);stamp=time.time()
        inputs_trace.append({'label':'owned-pty-resize','at':stamp,'cols':cols,'rows':rows,'signal':'SIGWINCH','pid':tui_pid,'kernel_readback':True,'ui_processing_ack':False});save('pty-input-trace.json',inputs_trace)
        return stamp
    def received(predicate,after):
        with relay.lock:
            matches=[row for row in relay.events if row['agent']=='masc-tui' and row['request_started_at']>=after and predicate(row)]
        return matches[-1] if matches else None
    def owned_health_identity(value):
        return (isinstance(value,dict) and value.get('build',{}).get('binary_commit')==SOURCE
                and value.get('build',{}).get('executable_sha256')==SERVER_SHA
                and value.get('paths',{}).get('effective_base_path')==str(base)
                and value.get('paths',{}).get('effective_masc_root')==str(base/'.masc')
                and value.get('startup',{}).get('state_ready') is True)
    def relay_health_prerequisite():
        remaining()
        actor='tui-probe-prerequisite' # root observer, explicitly NOT masc-tui
        endpoint=f'http://127.0.0.1:{relay.port}/health'
        req=urllib.request.Request(endpoint,headers={'Accept':'application/json','X-MASC-Agent':actor},method='GET')
        opener=urllib.request.build_opener(q.NoRedirect())
        try:response=opener.open(req,timeout=min(15,remaining()))
        except urllib.error.HTTPError as error:response=error
        with response:
            status=response.status;raw=response.read(MAX_CAPTURE+1)
        if len(raw)>MAX_CAPTURE:raise Incomplete('relay health prerequisite capture envelope exceeded')
        try:projected=selected_json('/health',raw)
        except (ValueError,TypeError):projected={'decode_error':'health response is not a JSON object'}
        receipt={'actor':actor,'is_actual_TUI':False,'bearer_sent':False,'method':'GET','url':endpoint,
                 'observed_at':time.time(),'status':status,'original_body_bytes':len(raw),
                 'original_body_sha256':hashlib.sha256(raw).hexdigest(),'selected_response':projected,
                 'scope':'One root observer prerequisite through unchanged relay; canonical Host, no identity/header/health rewriting.'}
        save('root-relay-health-prerequisite.json',receipt)
        if status!=200:raise Incomplete('owned relay health prerequisite HTTP '+str(status)+'; safe response recorded, no TUI started')
        if not owned_health_identity(projected):raise Incomplete('owned relay prerequisite did not confirm exact ready workspace/source/binary identity')
        return receipt
    def initial_tui_health():
        with relay.lock:
            candidates=[row for row in relay.events if row['agent']=='masc-tui' and row['method']=='GET'
                        and urllib.parse.urlsplit(row['path']).path=='/health']
        if not candidates:return None
        refusal=next((row for row in candidates if row['status']!=200),None)
        if refusal is not None:
            save('tui-initial-health-refusal.json',refusal)
            raise Incomplete('actual TUI initial health HTTP '+str(refusal['status'])+'; safe response preserved')
        receipt=candidates[-1]
        if not owned_health_identity(receipt.get('response')):
            save('tui-initial-health-identity-mismatch.json',receipt)
            raise Incomplete('actual TUI health did not confirm the pinned owned ready identity')
        return receipt
    def target(name,after):
        receipt=wait_for(lambda:received(lambda row:row['method']=='GET' and row['status']==200 and
            urllib.parse.parse_qs(urllib.parse.urlsplit(row['path']).query).get('payload_target')==['keeper:'+name],after))
        rows=receipt['response']['requests']
        check('TUI target response contains only selected owner schedules '+name,
              bool(rows) and all(row.get('payload_target')=='keeper:'+name for row in rows)
              and any(row['schedule_id']==schedule_ids[name] for row in rows))
        lifecycle_boundary('TUI-target-receipt-'+name)
        return receipt
    try:
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
        refuse_primary_port(port)
        relay=Relay(port,names,operations,output) # both ports rejected before any CLI/server/TUI child
        identity_reader=MacProcessIdentity()
        startup_output_path=base/'.masc/logs'/('masc-server-'+str(relay.port)+'.log')
        startup_baseline=startup_output_observation();save('startup-output-before.json',startup_baseline)
        if startup_baseline['exists']:raise Incomplete('fresh owned startup-output baseline already exists')
        lifecycle_boundary('before-setup')
        command([str(server_bin),'init','--base-path',str(base)],'init')
        (base/'.masc/config/runtime.toml').write_bytes((repo/'scripts/fixtures/release-evidence/runtime.toml').read_bytes())
        command([str(server_bin),'sandbox-image','promote','--base-path',str(base),'--runtime','apple_container','base',args.image_reference],'promote-owned-image')
        command([str(server_bin),'login','--base-path',str(base),'--host','127.0.0.1','--port',str(port),'--agent',actor,'--role','admin','--client-env','TUI_PROBE_ADMIN_TOKEN','--no-expiry','--json'],'mint-owned-admin')
        token=(base/'.masc/auth'/f'{actor}.token').read_text().strip() # never retained/logged
        evidence=SelectedEvidence(output/'http')
        api=q.API(f'http://127.0.0.1:{port}',evidence,token=token,timeout=15,max_response_bytes=MAX_CAPTURE)
        api.headers['X-MASC-Agent']=actor
        log=(output/'server.log').open('xb');os.chmod(output/'server.log',0o600)
        remaining()
        server_env={**env,'MASC_HTTP_BASE_URL':f'http://127.0.0.1:{relay.port}'}
        # Existing documented public identity, applied only to this owned
        # server. Bind authority remains trusted; no TOML key is invented.
        save('owned-request-identity-config.json',{'source':SOURCE,'setting':'MASC_HTTP_BASE_URL',
            'value':server_env['MASC_HTTP_BASE_URL'],'scope':'owned server child environment only',
            'configured_bind_url':f'http://127.0.0.1:{port}','authority_source_bindings':AUTHORITY_SOURCE_BINDINGS,
            'runtime_toml':'unchanged canonical boot fixture; no TOML mapping found in inspected registry',
            'upstream_bind_remains_trusted':True,'Host_or_response_rewriting':False})
        server=subprocess.Popen([str(server_bin),'start','--base-path',str(base),'--host','127.0.0.1','--port',str(port)],env=server_env,stdout=log,stderr=log,cwd=base,start_new_session=True)
        save('provenance.json',{'source':SOURCE,'native_inputs':bindings,'controller':file_identity(Path(__file__).resolve()),'base_path':str(base),'server_pid':server.pid,'port':port,'owners':names,'operations':operations,'scope':'Request/state only. No paint/screenshot/F9 visible-state proof. No real provider credentials inherited; canonical dead-loopback fixture has public synthetic auth only.'})
        def health_ready():
            try:health=get('/health?full=1','startup')
            except q.QualificationError:return None
            return health if health.get('startup',{}).get('state_ready') else None
        health=wait_for(health_ready)
        check('exact owned server identity',health['paths']['effective_base_path']==str(base) and health['build']['binary_commit']==SOURCE and health['build']['executable_sha256']==SERVER_SHA)
        workspace={'base_path':health['paths']['effective_base_path'],'masc_root':health['paths']['effective_masc_root']}
        for name in names:
            tool('masc_keeper_up',{'name':name,'create_only':True,'sandbox_profile':'microvm','sandbox_image':'base','microvm_backend':'apple_container','network_mode':'none','activation_mode':'manual','runtime_id':'ollama_cloud.deepseek-v4.1-flash','skills':{'names':[]},'instructions':'Owned paused TUI request/state fixture. Do not start model work.'})
            api.request('POST','/api/v1/keepers/'+name+'/directive',{'action':'pause'},stage='pause');paused(name)
        schedule_ids={name:'tui-schedule-'+uuid.uuid4().hex for name in names}
        for name in names:tool('masc_schedule_create',{'schedule_id':schedule_ids[name],'keeper_name':name,'due_in_sec':86400,'message':'Owned future schedule '+name})
        pending_id='tui-pending-'+uuid.uuid4().hex
        tool('masc_schedule_create',{'schedule_id':pending_id,'keeper_name':names[0],'due_in_sec':1,'message':'Owned due work held by paused owner; do not execute.'})
        def pending():
            row=get('/api/v1/dashboard/scheduled-automation?schedule_id='+pending_id,'pending-source').get('request',{})
            return row if (row.get('keeper_queue_evidence') or {}).get('projection_status')=='matched_pending' else None
        save('pending-accepted.json',wait_for(pending))
        originals={name:queue_only(name,workspace) for name in names}
        save('operations-before.json',originals)
        relay.start()
        relay_health_prerequisite()
        lifecycle_boundary('before-TUI')
        tui_args=[str(tui_bin),'--base-path',str(base),'--port',str(relay.port),'--workspace','owned-tui-'+uuid.uuid4().hex,'--refresh','2','--reasoning','hidden']
        remaining()
        tui_pid,master=pty.fork()
        if tui_pid==0:
            try:os.chdir(base);os.execve(str(tui_bin),tui_args,env)
            except BaseException:os._exit(127) # child cannot enter parent cleanup
        resize(120,40)
        drained={'bytes':0};hasher=hashlib.sha256()
        def drain():
            while not drain_stop.is_set():
                try:
                    ready,_,_=select.select([master],[],[],.2)
                    if not ready:continue
                    data=os.read(master,65536)
                    if not data:return
                    hasher.update(data);drained['bytes']+=len(data)
                except OSError:return
        drain_thread=threading.Thread(target=drain,daemon=True);drain_thread.start()
        save('tui-process.json',{'pid':tui_pid,'argv':tui_args,'relay_port':relay.port,'pty_output':'drained without storing/parsing text; byte/hash diagnostic only'})
        wait_for(initial_tui_health)
        first_input=input_bytes('palette-select-A',(':keeper '+names[0]+'\r').encode());first_page=target(names[0],first_input)
        check('TUI received accepted one-shot whose exact occurrence remains pending',
              any(row['schedule_id']==pending_id and (row.get('keeper_queue_evidence') or {}).get('projection_status')=='matched_pending'
                  for row in first_page['response']['requests']))
        stamp=input_bytes('leave-A-select-B',('\x11:keeper '+names[1]+'\r').encode());target(names[1],stamp)
        stamp=input_bytes('open-Schedules',b'\x11:go Schedules\r')
        wait_for(lambda:received(lambda row:row['method']=='GET' and row['status']==200 and row['path']=='/api/v1/dashboard/scheduled-automation',stamp))
        extra_id='tui-refresh-'+uuid.uuid4().hex
        tool('masc_schedule_create',{'schedule_id':extra_id,'keeper_name':names[1],'due_in_sec':86400,'message':'Owned explicit refresh state marker'})
        stamp=input_bytes('Schedules-refresh',b'r')
        refreshed=wait_for(lambda:received(lambda row:row['method']=='GET' and row['status']==200 and row['path']=='/api/v1/dashboard/scheduled-automation' and any(item['schedule_id']==extra_id for item in row['response'].get('requests',[])),stamp))
        save('refresh-observation.json',{'receipt':refreshed,'scope':'Fresh request/response after refresh input; cadence may share demand. No exact request-count or painted-row claim.'})
        stamp=input_bytes('palette-return-A',(':keeper '+names[0]+'\r').encode());target(names[0],stamp)
        input_bytes('draft-owned-queue-edit',('/queue edit '+operations[names[0]]+' '+marker+'_WIDE_TYPE').encode())
        stamp=input_bytes('normal-size-bracketed-paste',b'\x1b[200~_WIDE_PASTE\x1b[201~');target(names[0],stamp)
        input_bytes('F9-intended-toggle-1',b'\x1b[20~');stamp=input_bytes('F9-intended-toggle-2',b'\x1b[20~');target(names[0],stamp)
        stamp=resize(20,40);target(names[0],stamp)
        input_bytes('narrow-ordinary-text',b'_NARROW_TYPE');stamp=input_bytes('narrow-bracketed-paste',b'\x1b[200~_NARROW_PASTE\x1b[201~');target(names[0],stamp)
        stamp=resize(120,40);target(names[0],stamp)
        # These are HTTP cadence witnesses, not a claimed UI resize/paint ack.
        stamp=input_bytes('submit-preserved-queue-edit',b'\r')
        edit=wait_for(lambda:received(lambda row:row['method']=='POST' and row['path'].endswith('/edit'),stamp))
        check('actual TUI queued edit accepted',edit['status']==200,{'status':edit['status'],'agent':edit['agent']})
        check('actual TUI edit targets the exact selected A operation',edit['path']==op_path(names[0])+'/edit')
        expected_message=marker+'_WIDE_TYPE_WIDE_PASTE'
        expected_input={**originals[names[0]]['input'],'message':expected_message,'user_blocks':[{'type':'text','text':expected_message}]}
        if edit['request_body']!={'input':expected_input}:
            try:save('draft-request-mismatch.json',{'expected':expected_input,'actual_request':edit['request_body'],
                'scope':'Accepted actual TUI request differs from the bounded scenario expectation. Resize/focus cause and paint remain unproved.'})
            finally:check('actual TUI edit request preserves original typed input and exact draft',False)
        check('actual TUI edit request preserves original typed input and exact draft',True)
        after={names[0]:operation(names[0],'queue-after-A')}
        a_decisions=[('F9/narrow input preserved exact queued draft bytes',after[names[0]]['input']==expected_input)]
        a_decisions += [('original A operation identity retained '+key,after[names[0]][key]==originals[names[0]][key])
                        for key in ['operation_id','source','sequence','admission_digest']]
        failed=next((decision for decision in a_decisions if not decision[1]),None)
        if failed is not None:
            try:save('draft-state-mismatch.json',{'expected_input':expected_input,'actual_operation':after[names[0]],
                'scope':'Canonical accepted-edit state violates a declared scenario expectation; this does not establish UI resize/focus root cause.'})
            finally:check(*failed)
        for decision in a_decisions:check(*decision)
        after[names[1]]=operation(names[1],'queue-after-B')
        check('other owner operation unchanged',after[names[1]]==originals[names[1]])
        save('operations-after.json',after)
        for name in names:
            paused(name)
            queued=get('/api/v1/keepers/'+name+'/chat/operations?state=queued','queued-membership-after')
            check('only original queued operation remains '+name,
                  [row['operation_id'] for row in queued['operations']]==[operations[name]])
        lifecycle_boundary('after-request-state-checks')
        if relay.errors:raise Incomplete('relay capture unavailable; inspect capture_errors, no UI verdict inferred')
        outcome={'verdict':'PASS','scope':'Owned actual TUI HTTP requests and canonical queued-state observations only','not_proven':['visible UI/paint/screenshot','F9 expanded/folded state','canonical UI resize-processing acknowledgement or causal narrow-guard proof','late-response UI generation handling','draft survives process restart','model execution','whole audit rows 52-57']}
    except BaseException as error:
        outcome={'verdict':'FAIL' if isinstance(error,BehaviorFailure) else 'INCOMPLETE','error_type':type(error).__name__,'detail':str(error),'scope':'Observation ended; no automatic retry/resume or producer-terminal inference'}
    finally:
        cleanup={'normal_signals_only':True,'forced_kill':False,'errors':[]}
        try:lifecycle_boundary('cleanup-before',cleanup=True)
        except Exception as error:
            lifecycle_incomplete=True;cleanup['errors'].append({'stage':'inventory-before','error_type':type(error).__name__})
        try:
            if tui_pid is not None and tui_exit is None:
                try:os.kill(tui_pid,signal.SIGTERM)
                except ProcessLookupError:pass
                deadline=time.time()+15
                while time.time()<deadline:
                    done,status=os.waitpid(tui_pid,os.WNOHANG)
                    if done:tui_exit=os.waitstatus_to_exitcode(status);break
                    time.sleep(.1)
                cleanup.update(tui_pid=tui_pid,tui_exit_status=tui_exit)
        except Exception as error:cleanup['errors'].append({'stage':'tui-stop','error_type':type(error).__name__})
        if tui_pid is not None:cleanup.update(tui_pid=tui_pid,tui_exit_status=tui_exit)
        drain_stop.set()
        if drain_thread is not None:drain_thread.join(timeout=1)
        try:
            if master is not None:os.close(master)
            if relay is not None:relay.close()
        except Exception as error:cleanup['errors'].append({'stage':'relay-close','error_type':type(error).__name__})
        try:
            inventory=lifecycle_boundary('after-TUI-stop',cleanup=True)
            direct=next((row for row in inventory.get('servers',[]) if server is not None and row['pid']==server.pid and row.get('canonical_argv_verified')),None)
            cleanup['server_signals']=[]
            if direct is not None:cleanup['server_signals'].append(signal_reverified_server(direct))
            elif server is not None and server.poll() is None:
                lifecycle_incomplete=True;cleanup['errors'].append({'stage':'direct-server-identity','error_type':'not_reverified_no_signal'})
            for record in observed_fallbacks.values():cleanup['server_signals'].append(signal_reverified_server(record))
            if server is not None:
                try:server.wait(timeout=15)
                except subprocess.TimeoutExpired:pass
                cleanup.update(server_pid=server.pid,server_exit_status=server.poll())
            after_inventory=lifecycle_boundary('cleanup-after',cleanup=True)
            cleanup['remaining_owned_servers']=after_inventory.get('servers',[])
            if cleanup['remaining_owned_servers']:lifecycle_incomplete=True
        except Exception as error:
            lifecycle_incomplete=True;cleanup['errors'].append({'stage':'server-stop','error_type':type(error).__name__})
        cleanup['setup_cli_handles']=[{**row,'current_returncode':child.poll()} for child,row in setup_handles]
        cleanup['inventory_cli_handles']=[{**row,'current_returncode':child.poll()} for child,row in utility_handles]
        cleanup['lingering_setup_or_inventory_cli']=any(child.poll() is None for child,_ in setup_handles+utility_handles)
        try:
            if 'hasher' in locals():save('pty-output-drain.json',{'bytes':drained['bytes'],'sha256':hasher.hexdigest(),'raw_output_retained':False,'text_or_screen_assertions':False})
            save('cleanup.json',cleanup)
        except Exception as error:cleanup['errors'].append({'stage':'cleanup-receipt','error_type':type(error).__name__})
    if (lifecycle_incomplete or cleanup['lingering_setup_or_inventory_cli'] or cleanup['errors'] or (tui_pid is not None and tui_exit is None) or (server is not None and server.poll() is None)):
        outcome['cleanup_or_lifecycle_incomplete']=True;outcome['cleanup']=cleanup;outcome['unexpected_start_or_inventory_limit']=lifecycle_incomplete
        if outcome['verdict']=='PASS':outcome['behavior_verdict']='PASS';outcome['verdict']='INCOMPLETE'
    try:save('result.json',outcome)
    except Exception as error:
        if outcome['verdict']=='PASS':outcome['verdict']='INCOMPLETE'
        print(json.dumps({'verdict':outcome['verdict'],'result_write_error':type(error).__name__}),flush=True)
    finally:
        if outcome['verdict']!='PASS':raise SystemExit(1 if outcome['verdict']=='FAIL' else 2)

if __name__=='__main__':main()
