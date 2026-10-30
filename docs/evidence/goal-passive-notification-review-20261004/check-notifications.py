from pathlib import Path
import subprocess,tempfile,json,sys,hashlib,os,argparse
parser=argparse.ArgumentParser()
parser.add_argument('checkout',type=Path);parser.add_argument('cache',type=Path)
parser.add_argument('--source-ref');parser.add_argument('--suite',action='append',choices=['test_goal_notification_contract','test_keeper_chat_store_append_result','test_keeper_chat_store_approval_summary','test_broadcast_stores_raw_text'])
args=parser.parse_args();wd=args.checkout.resolve();cache=args.cache.resolve()
out=Path(tempfile.mkdtemp(prefix='masc-notification-contract-'))
print(f'Evidence directory: {out}',flush=True)
paths=list((cache/'_build/default/lib').glob('**/*.cmx'))+list((cache/'_build/default/packages').glob('**/*.cmx'))+list((cache/'_build/default/test/deps').glob('**/*.cmx'))
index={p.stem[0].upper()+p.stem[1:]:p for p in paths if '/native/' in str(p)}
incs=sorted({str(p.parent.parent/'byte') for p in paths if '/native/' in str(p)})
packages='checkseum.c,alcotest,yojson,uuidm,eio_main,mcp_protocol.eio,digestif.c,ptime,re,mirage-crypto-rng.unix,ipaddr,uri,cstruct,fmt,fpath,otoml,ppx_inline_test.config,ppx_inline_test.runtime-lib,ppx_deriving.show,ppx_deriving.eq,ppx_deriving_yojson,str,uucp,uutf,zstd,ca-certs,opentelemetry,opentelemetry.client,opentelemetry.proto,cohttp-eio,http,tls-eio,sqlite3,ambient-context-eio,httpun,httpun-eio,httpun-ws,grpc-direct,eio.mock,piaf,piaf.stream,uunf.string,decompress.zl,ws-direct-core,ws-direct-eio,ocaml-dos.core-identity,ocaml-dos.cpu86core,ocaml-dos.dosmachine,atdgen-runtime,markup,yaml,ocaml-msx.msx'
cmd=['opam','exec','--switch=5.5.1','--','ocamlfind','ocamlopt','-opaque','-thread','-package',packages,'-I',str(out)]+[v for d in incs for v in ['-I',d]]
def run(args):
 env=os.environ.copy()
 r=subprocess.run(args,cwd=out,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 if r.returncode:(out/'failure.txt').write_text(r.stdout);raise RuntimeError(r.stdout[-5000:])
 return r.stdout
source_ref=args.source_ref
def source(path):
 return subprocess.check_output(['git','-C',str(wd),'show',source_ref+':'+path]) if source_ref else (wd/path).read_bytes()
def compile_unit(path,unit,keep_interface=True):
 for ext in ['mli','ml']:
  (out/(unit+'.'+ext)).write_bytes((wd/(path+'.'+ext)).read_bytes() if unit=='workspace_request_id' else source(path+'.'+ext))
 name=unit[0].upper()+unit[1:]
 opened=['-open','Masc'] if unit.startswith('masc__') else []
 if keep_interface:
  (out/(unit+'.cmi')).write_bytes(index[name].parent.parent.joinpath('byte',unit+'.cmi').read_bytes())
 else:run(cmd+opened+['-c',unit+'.mli'])
 run(cmd+opened+['-c',unit+'.ml'])
 index[name]=out/(unit+'.cmx')
compile_unit('lib/workspace/workspace_request_id','workspace_request_id',False)
compile_unit('lib/workspace/workspace_broadcast','workspace_broadcast')
compile_unit('lib/goal/goal_store','goal_store')
compile_unit('lib/keeper/keeper_chat_store','masc__Keeper_chat_store',bool(source_ref))
server=source('lib/server/server_bootstrap_loops.ml').decode()
projection=server.split('let append_workspace_message_to_recipient',1)[1].split('\nlet goal_notification_backend',1)[0]
(out/'projection.ml').write_text('open Masc\nlet workspace_message_chat_source = Surface_ref.lane_label Surface_ref.Agent\nlet append_workspace_message_to_recipient'+projection)
run(cmd+['-c','projection.ml']);index['Projection']=out/'projection.cmx'

info={}
def deps(p):
 if p not in info:
  raw=run(['opam','exec','--switch=5.5.1','--','ocamlobjinfo',str(p)])
  raw=raw.split('Implementations imported:\n',1)[1].split('Clambda approximation:',1)[0]
  info[p]=[w[1] for l in raw.splitlines() if len(w:=l.split())==2]
 return info[p]
results={}
for name in (args.suite or ['test_goal_notification_contract']):
 p=out/(name+'.ml');p.write_text((wd/'test'/p.name).read_text().replace('Masc.Keeper_chat_store','Masc__Keeper_chat_store').replace('Masc.Server_bootstrap_loops.For_testing','Projection'));run(cmd+['-c',p.name]);objects=[];visited=set()
 def visit(name):
  if name in visited or name not in index:return
  visited.add(name);obj=index[name]
  for dep in deps(obj):visit(dep)
  objects.append(obj)
 for dep in deps(p.with_suffix('.cmx')):visit(dep)
 print(name, len(objects), 'cached/direct dependency objects',flush=True)
 stubs=list((cache/'_build/default/lib').glob('**/lib*stubs.a'))
 stubs.append(cache/'_build/default/test/deps/libmasc_test_deps_stubs.a')
 build_data=next((cache/'_build/default').glob('**/build_info__Build_info_data.cmx'))
 build_lib=run(['opam','exec','--switch=5.5.1','--','ocamlfind','query','dune-build-info']).strip()
 frameworks=['-cclib','-framework Security','-cclib','-framework CoreFoundation'] if sys.platform=='darwin' else []
 run(cmd+frameworks+['-linkpkg',str(build_data),str(Path(build_lib)/'build_info.cmxa')]+list(map(str,objects))+[p.with_suffix('.cmx').name,'-o',name+'.exe']+[v for q in stubs for v in ['-cclib',str(q)]])
 result=subprocess.run([str(out/(name+'.exe')),'--color=never'],cwd=out,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (out/(name+'.txt')).write_text(result.stdout);print(result.stdout,flush=True);results[name]=result.returncode
(out/'manifest.json').write_text(json.dumps({'source_ref':source_ref,'results':results,'scope':'complete current workspace ID, broadcast, Goal store and chat store; exact server projection function; registered suite with aliases; cached lower dependencies; not whole server or reactive Keeper runtime','cache':str(cache),'source_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in out.glob('*.ml*')}},indent=2)+'\n')

sys.exit(1 if any(results.values()) else 0)
