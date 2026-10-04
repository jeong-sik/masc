from pathlib import Path
import subprocess,tempfile,json,sys,hashlib,os
wd=Path(sys.argv[1]).resolve();cache=Path(sys.argv[2]).resolve();out=Path(tempfile.mkdtemp(prefix='masc-config-consolidation-'))
print(f'Evidence directory: {out}',flush=True)
paths=list((cache/'_build/default/lib').glob('**/*.cmx'))+list((cache/'_build/default/packages').glob('**/*.cmx'))
index={p.stem[0].upper()+p.stem[1:]:p for p in paths if '/native/' in str(p)}
incs=sorted({str(p.parent.parent/'byte') for p in paths if '/native/' in str(p)})
packages='alcotest,yojson,uuidm,eio_main,mcp_protocol.eio,digestif.c,ptime,re,mirage-crypto-rng.unix,ipaddr,uri,cstruct,fmt,fpath,otoml,ppx_inline_test.config,ppx_inline_test.runtime-lib,ppx_deriving.show,str,uucp,uutf,zstd,ca-certs,opentelemetry,opentelemetry.client,opentelemetry.proto,cohttp-eio,http,tls-eio,sqlite3,ambient-context-eio'
cmd=['opam','exec','--switch=5.5.1','--','ocamlfind','ocamlopt','-opaque','-thread','-package',packages,'-I',str(out)]+[v for d in incs for v in ['-I',d]]
def run(args):
 env=os.environ.copy();env['MASC_TEST_RUNTIME_SEED']=str(wd/'config/runtime.toml')
 r=subprocess.run(args,cwd=out,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 if r.returncode:(out/'failure.txt').write_text(r.stdout);raise RuntimeError(r.stdout[-5000:])
 return r.stdout
mode=sys.argv[3]
if mode=='provider':
 unit='runtime_toml'
 for ext in ['mli','ml']:
  p=out/(unit+'.'+ext);p.write_bytes((wd/'lib/runtime'/p.name).read_bytes())
 # The public signature is unchanged (documentation-only); reuse its cached
 # compiled interface so cached consumers retain the same interface identity.
 (out/'runtime_toml.cmi').write_bytes(index['Runtime_toml'].parent.parent.joinpath('byte/runtime_toml.cmi').read_bytes())
 run(cmd+['-c','runtime_toml.ml'])
 index['Runtime_toml']=out/'runtime_toml.cmx'

info={}
def deps(p):
 if p not in info:
  raw=run(['opam','exec','--switch=5.5.1','--','ocamlobjinfo',str(p)])
  raw=raw.split('Implementations imported:\n',1)[1].split('Clambda approximation:',1)[0]
  info[p]=[w[1] for l in raw.splitlines() if len(w:=l.split())==2]
 return info[p]
for name in (['test_runtime_toml_overrides'] if mode=='boot' else ['test_runtime_toml_namespace','test_runtime_account_declaration']):
 p=out/(name+'.ml');p.write_bytes((wd/'test'/p.name).read_bytes());run(cmd+['-c',p.name]);objects=[];visited=set()
 def visit(name):
  if name in visited or name not in index:return
  visited.add(name);obj=index[name]
  for dep in deps(obj):visit(dep)
  objects.append(obj)
 for dep in deps(p.with_suffix('.cmx')):visit(dep)
 print(name, len(objects), 'cached/direct dependency objects',flush=True)
 stubs=list((cache/'_build/default/lib').glob('**/lib*stubs.a'))
 if mode=='boot':stubs.append(cache/'_build/default/test/deps/libmasc_test_deps_stubs.a')
 build_data=next((cache/'_build/default').glob('**/build_info__Build_info_data.cmx'))
 build_lib=run(['opam','exec','--switch=5.5.1','--','ocamlfind','query','dune-build-info']).strip()
 run(cmd+['-linkpkg',str(build_data),str(Path(build_lib)/'build_info.cmxa')]+list(map(str,objects))+[p.with_suffix('.cmx').name,'-o',name+'.exe']+[v for q in stubs for v in ['-cclib',str(q)]])
 result=run([str(out/(name+'.exe')),'--color=never']);(out/(name+'.txt')).write_text(result);print(result,flush=True)
(out/'manifest.json').write_text(json.dumps({'mode':mode,'scope':'complete registered suites; provider mode compiles candidate Runtime_toml against its unchanged cached public interface; boot mode uses cached product modules with matching owner/consumer source; no full server or production','cache':str(cache),'sources':{p:hashlib.sha256((wd/p).read_bytes()).hexdigest() for p in (['test/test_runtime_toml_overrides.ml'] if mode=='boot' else ['lib/runtime/runtime_toml.ml','lib/runtime/runtime_toml.mli','lib/runtime/runtime.ml','lib/runtime/runtime.mli','test/test_runtime_toml_namespace.ml','test/test_runtime_account_declaration.ml','config/runtime.toml'])}},indent=2)+'\n')
