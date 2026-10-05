from pathlib import Path
import subprocess,tempfile,json,sys,hashlib,os,argparse
parser=argparse.ArgumentParser()
parser.add_argument('checkout',type=Path);parser.add_argument('cache',type=Path)
parser.add_argument('--source-ref');parser.add_argument('--suite',action='append',choices=['test_goal_drop_delivery','test_goal_tools'])
args=parser.parse_args();wd=args.checkout.resolve();cache=args.cache.resolve()
out=Path(tempfile.mkdtemp(prefix='masc-goal-drop-'))
print(f'Evidence directory: {out}',flush=True)
paths=list((cache/'_build/default/lib').glob('**/*.cmx'))+list((cache/'_build/default/packages').glob('**/*.cmx'))+list((cache/'_build/default/test/deps').glob('**/*.cmx'))
index={p.stem[0].upper()+p.stem[1:]:p for p in paths if '/native/' in str(p)}
incs=sorted({str(p.parent.parent/'byte') for p in paths if '/native/' in str(p)})
packages='checkseum.c,alcotest,yojson,uuidm,eio_main,mcp_protocol.eio,digestif.c,ptime,re,mirage-crypto-rng.unix,ipaddr,uri,cstruct,fmt,fpath,otoml,ppx_inline_test.config,ppx_inline_test.runtime-lib,ppx_deriving.show,str,uucp,uutf,zstd,ca-certs,opentelemetry,opentelemetry.client,opentelemetry.proto,cohttp-eio,http,tls-eio,sqlite3,ambient-context-eio,httpun,httpun-eio,httpun-ws,grpc-direct,eio.mock,piaf,piaf.stream,uunf.string,decompress.zl,ws-direct-core,ws-direct-eio,ocaml-dos.core-identity,ocaml-dos.cpu86core,ocaml-dos.dosmachine,atdgen-runtime,markup,yaml,ocaml-msx.msx'
cmd=['opam','exec','--switch=5.5.1','--','ocamlfind','ocamlopt','-opaque','-thread','-package',packages,'-I',str(out)]+[v for d in incs for v in ['-I',d]]
def run(args):
 env=os.environ.copy()
 r=subprocess.run(args,cwd=out,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 if r.returncode:(out/'failure.txt').write_text(r.stdout);raise RuntimeError(r.stdout[-5000:])
 return r.stdout
source_ref=args.source_ref
unit='masc__Workspace_goals'
for ext in ['mli','ml']:
 name='lib/workspace_goals.'+ext
 source=subprocess.check_output(['git','-C',str(wd),'show',source_ref+':'+name]) if source_ref else (wd/name).read_bytes()
 (out/(unit+'.'+ext)).write_bytes(source)
(out/(unit+'.cmi')).write_bytes(index['Masc__Workspace_goals'].parent.parent.joinpath('byte',unit+'.cmi').read_bytes())
run(cmd+['-open','Masc','-c',unit+'.ml'])
index['Masc__Workspace_goals']=out/(unit+'.cmx')

info={}
def deps(p):
 if p not in info:
  raw=run(['opam','exec','--switch=5.5.1','--','ocamlobjinfo',str(p)])
  raw=raw.split('Implementations imported:\n',1)[1].split('Clambda approximation:',1)[0]
  info[p]=[w[1] for l in raw.splitlines() if len(w:=l.split())==2]
 return info[p]
results={}
for name in (args.suite or ['test_goal_drop_delivery']):
 p=out/(name+'.ml');p.write_text((wd/'test'/p.name).read_text().replace('Masc.Workspace_goals','Masc__Workspace_goals'));run(cmd+['-c',p.name]);objects=[];visited=set()
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
(out/'manifest.json').write_text(json.dumps({'source_ref':source_ref,'results':results,'scope':'complete Workspace_goals implementation against unchanged cached public interface; registered cancellation suite with a direct module alias; real temporary filesystem and fresh child process; cached lower dependencies; not full product/server','cache':str(cache),'source_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in out.glob('*.ml*')}},indent=2)+'\n')

sys.exit(1 if any(results.values()) else 0)
