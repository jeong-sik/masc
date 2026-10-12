#!/usr/bin/env python3
"""Verify a generated machine image using isolated synthetic state."""
import argparse, base64, hashlib, json, os, selectors, subprocess, time, uuid
from pathlib import Path

def run(*args):
    return subprocess.check_output(args, text=True, timeout=60).strip()

class Worker:
    def __init__(self, image, arch, volume, name, artifact):
        self.name = name
        self.stderr_path = artifact / (name + '.stderr.log')
        self.stderr = self.stderr_path.open('wb')
        self.proc = None
        try:
            self.proc = subprocess.Popen(['docker','run','--rm','-i','--name',name,
                '--platform','linux/'+arch,'--network','none','--read-only','--cap-drop','ALL',
                '--security-opt','no-new-privileges','--mount','type=volume,source='+volume+',target=/state',
                image], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr)
            self.buffer=b''; self.seq=0
            self.rpc('initialize', {'protocolVersion':'2025-11-25','capabilities':{},
                'clientInfo':{'name':'isolated-machine-proof','version':'1'}})
            self.send({'jsonrpc':'2.0','method':'notifications/initialized'})
        except BaseException:
            self.close()
            raise
    def send(self, value):
        self.proc.stdin.write((json.dumps(value)+'\n').encode()); self.proc.stdin.flush()
    def rpc(self, method, params):
        self.seq+=1; ident=self.seq
        self.send({'jsonrpc':'2.0','id':ident,'method':method,'params':params})
        deadline=time.monotonic()+60
        with selectors.DefaultSelector() as sel:
            sel.register(self.proc.stdout,selectors.EVENT_READ)
            while True:
                if time.monotonic() >= deadline: raise TimeoutError(method)
                while b'\n' in self.buffer:
                    line,self.buffer=self.buffer.split(b'\n',1)
                    value=json.loads(line)
                    if value.get('id')==ident:
                        if 'error' in value: raise RuntimeError(value['error'])
                        return value['result']
                if not sel.select(max(0,deadline-time.monotonic())): raise TimeoutError(method)
                data=os.read(self.proc.stdout.fileno(),65536)
                if not data: raise RuntimeError('worker ended; stderr: '+str(self.stderr_path))
                self.buffer+=data
    def call(self, machine, operation, args=None, holder=None, controlled=False):
        context={'tool':'masc_'+machine+'_'+operation,'arguments':args or {},
                 'caller':{'kind':'keeper','name':'fixture'}}
        if controlled: context['controller']={'observed_holder':holder,'release':None,'handoff_target':None}
        return self.rpc('tools/call',{'name':'lane_call','arguments':context})
    def close(self):
        try:
            subprocess.run(['docker','rm','--force',self.name],timeout=30,
                stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=False)
        finally:
            try:
                if self.proc is not None:
                    try:
                        self.proc.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        self.proc.kill()
                        self.proc.wait(timeout=10)
                    finally:
                        self.proc.stdin.close()
                        self.proc.stdout.close()
            finally:
                self.stderr.close()

def main():
    ap=argparse.ArgumentParser();ap.add_argument('artifact');a=ap.parse_args()
    root=Path(a.artifact);receipt=json.loads((root/'receipt.json').read_text())
    with (root/'image.tar.gz').open('rb') as f: digest=hashlib.file_digest(f,'sha256').hexdigest()
    assert digest==receipt['archive_sha256']
    subprocess.run(['docker','load','-i',str(root/'image.tar.gz')],check=True,stdout=subprocess.DEVNULL,timeout=180)
    image=receipt['image_id']; meta=json.loads(run('docker','image','inspect',image))[0]
    assert meta['Architecture']==receipt['architecture']
    assert meta['Config']['Labels']['org.opencontainers.image.revision']==receipt['source_commit']
    machine=receipt['package'].split('-')[0]; name='masc-proof-'+uuid.uuid4().hex
    volume=name+'-state'
    try:
        run('docker','volume','create','--label','masc.proof.run='+os.environ.get('GITHUB_RUN_ID','local'),volume)
        result={'source_commit':receipt['source_commit'],'image_id':image,'architecture':receipt['architecture'],
                'volume':volume,'checks':[]}
        result['workflow_run_id']=os.environ.get('GITHUB_RUN_ID')
        if machine=='dos':
            # This fresh volume contains only a generated program, never user media.
            program=bytes.fromhex('b409ba1101cd21b400cd1609c074f8cd20')+b'HI$'
            subprocess.run(['docker','run','--rm','-i','--name',name+'-seed','--network','none','--mount',
                'type=volume,source='+volume+',target=/state',image,'sh','-c',
                'mkdir -p /state/.masc/dos/programs && cat > /state/.masc/dos/programs/hello.com'],input=program,check=True,timeout=60)
        def success(value):
            assert value.get('isError') is not True, value
            return value.get('structuredContent')
        worker=Worker(image,receipt['architecture'],volume,name,root)
        try:
            tools=worker.rpc('tools/list',{})['tools']
            assert any(t['name']=='masc_'+machine+'_screen' for t in tools)
            empty=worker.call(machine,'screen');assert empty.get('isError') is True
            direct=worker.rpc('tools/call',{'name':'masc_'+machine+'_load','arguments':{}})
            assert direct.get('isError') is True
            success(worker.call(machine,'load',{'program':'hello.com'} if machine=='dos' else {'roms_dir':''},controlled=machine=='dos'))
            screen=worker.call(machine,'screen');before=success(screen)
            png=next(c for c in screen['content'] if c['type']=='image')
            assert base64.b64decode(png['data']).startswith(bytes.fromhex('89504e470d0a1a0a'))
            (root/'screen.png').write_bytes(base64.b64decode(png['data']))
            success(worker.call(machine,'save',{'slot':'proof'}))
            result['checks'] += ['stdio_initialize','tool_discovery','empty_refusal','direct_call_refusal','host_context_load','png','checkpoint_save']
        finally: worker.close()
        worker=Worker(image,receipt['architecture'],volume,name+'-replacement',root)
        try:
            assert worker.call(machine,'screen').get('isError') is True
            success(worker.call(machine,'restore',{'slot':'proof'},controlled=machine=='dos'))
            screen=success(worker.call(machine,'screen'))
            key='steps' if machine=='dos' else 'frame'
            assert screen[key]==before[key], (screen[key],before[key])
            if machine=='dos': assert screen['controller']=='fixture'
            result['checks'] += ['replacement_starts_unloaded','volume_checkpoint_restore','restored_clock_unchanged']
        finally: worker.close()
        (root/'runtime-proof.json').write_text(json.dumps(result,indent=2)+'\n')
    finally:
        # Cover seed failures and initialization failures, as well as normal exits.
        # Remove all uniquely named containers before removing their shared volume.
        try:
            subprocess.run(['docker','rm','--force',name+'-seed',name,name+'-replacement'],
                stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=False,timeout=30)
        finally:
            run('docker','volume','rm',volume)
    print(json.dumps(result))
if __name__=='__main__': main()
