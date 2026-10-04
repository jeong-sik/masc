from pathlib import Path
import subprocess,tempfile,json,sys,hashlib,os,argparse
parser=argparse.ArgumentParser()
parser.add_argument('checkout',type=Path);parser.add_argument('cache',type=Path)
parser.add_argument('--typecheck-consumers',action='store_true');parser.add_argument('--suite',action='append',choices=['test_goal_suspension','test_goal_phase_all','test_goal_suspension_projection','test_goal_drop_delivery'])
args=parser.parse_args();wd=args.checkout.resolve();cache=args.cache.resolve()
out=Path(tempfile.mkdtemp(prefix='masc-goal-suspension-'))
print(f'Evidence directory: {out}',flush=True)
paths=list((cache/'_build/default/lib').glob('**/*.cmx'))+list((cache/'_build/default/packages').glob('**/*.cmx'))+list((cache/'_build/default/test/deps').glob('**/*.cmx'))
index={p.stem[0].upper()+p.stem[1:]:p for p in paths if '/native/' in str(p)}
incs=sorted({str(p.parent.parent/'byte') for p in paths if '/native/' in str(p)})
packages='checkseum.c,alcotest,yojson,uuidm,eio_main,mcp_protocol.eio,digestif.c,ptime,re,mirage-crypto-rng.unix,ipaddr,uri,cstruct,fmt,fpath,otoml,ppx_inline_test.config,ppx_inline_test.runtime-lib,ppx_deriving.show,ppx_deriving_yojson,str,uucp,uutf,zstd,ca-certs,opentelemetry,opentelemetry.client,opentelemetry.proto,cohttp-eio,http,tls-eio,sqlite3,ambient-context-eio,httpun,httpun-eio,httpun-ws,grpc-direct,eio.mock,piaf,piaf.stream,uunf.string,decompress.zl,ws-direct-core,ws-direct-eio,ocaml-dos.core-identity,ocaml-dos.cpu86core,ocaml-dos.dosmachine,atdgen-runtime,markup,yaml,ocaml-msx.msx'
cmd=['opam','exec','--switch=5.5.1','--','ocamlfind','ocamlopt','-opaque','-thread','-package',packages,'-I',str(out)]+[v for d in incs for v in ['-I',d]]
def run(args):
 env=os.environ.copy()
 r=subprocess.run(args,cwd=out,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 if r.returncode:(out/'failure.txt').write_text(r.stdout);raise RuntimeError(r.stdout[-5000:])
 return r.stdout
def compile_unit(path, unit):
 for ext in ['mli','ml']:
  (out/(unit+'.'+ext)).write_bytes((wd/(path+'.'+ext)).read_bytes())
 opened=['-open','Masc'] if unit.startswith(('masc__', 'dashboard_')) else []
 if unit in ['workspace_broadcast', 'masc__Fusion_request_context']:
  if (wd/(path+'.mli')).read_bytes() != (cache/('_build/default/'+path+'.mli')).read_bytes():
   raise RuntimeError('Cached public interface source mismatch: '+path)
  (out/(unit+'.cmi')).write_bytes(index[unit[0].upper()+unit[1:]].parent.parent.joinpath('byte',unit+'.cmi').read_bytes())
 else:run(cmd+opened+['-c',unit+'.mli'])
 run(cmd+opened+['-w','+8+11+32','-warn-error','+8+11+32','-c',unit+'.ml'])
 index[unit[0].upper()+unit[1:]]=out/(unit+'.cmx')
for path,unit in [
 ('lib/workspace/workspace_request_id','workspace_request_id'),
 ('lib/workspace/workspace_broadcast','workspace_broadcast'),
 ('lib/goal/goal_phase','goal_phase'),
 ('lib/goal/goal_store','goal_store'),
 ('lib/goal/goal_verification','goal_verification'),
 ('lib/goal/goal_delivery','goal_delivery'),
 ('lib/goal/goal_measurement','goal_measurement'),
 ('lib/goal/goal_unavailable_envelope','goal_unavailable_envelope'),
 (str(next(wd.glob('lib/**/fusion_request_context.ml')).relative_to(wd).with_suffix('')),'masc__Fusion_request_context'),
 ('lib/workspace_goals','masc__Workspace_goals')]:
 print('compile',unit,flush=True);compile_unit(path,unit)

if args.typecheck_consumers or 'test_goal_suspension_projection' in (args.suite or []):
 for source_name in ['keeper_world_observation', 'keeper_unified_prompt', 'goal_verification_run_registry']:
  source_path=next(wd.glob('lib/**/'+source_name+'.mli'))
  unit='masc__'+source_name[0].upper()+source_name[1:]
  (out/(unit+'.mli')).write_bytes(source_path.read_bytes())
  run(cmd+['-open','Masc','-c',unit+'.mli'])
 for path, unit in [
  ('lib/dashboard/dashboard_goals_types_accessor','dashboard_goals_types_accessor'),
  ('lib/dashboard/dashboard_goals_types_health','dashboard_goals_types_health'),
  ('lib/dashboard/dashboard_goals_types_timeline','dashboard_goals_types_timeline'),
  ('lib/keeper/keeper_turn_task_context','masc__Keeper_turn_task_context'),
  ('lib/tui_decode','masc__Tui_decode'),
 ]:
  print('consumer typecheck',unit,flush=True);compile_unit(path,unit)

info={}
def deps(p):
 if p not in info:
  raw=run(['opam','exec','--switch=5.5.1','--','ocamlobjinfo',str(p)])
  raw=raw.split('Implementations imported:\n',1)[1].split('Clambda approximation:',1)[0]
  info[p]=[w[1] for l in raw.splitlines() if len(w:=l.split())==2]
 return info[p]
results={}
for name in (args.suite or ['test_goal_suspension']):
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
(out/'manifest.json').write_text(json.dumps({'results':results,'scope':'candidate Goal phase/store/ledger/admission/delivery/measurement/envelope and Workspace_goals compiled in full; candidate workspace identity/broadcast and Fusion request context; optional complete dashboard accessor/health/timeline, Keeper task context and TUI decoder typechecks; other dependencies cached; three additional Keeper/verifier interfaces refreshed without compiling their implementations; no full server or TUI executable','cache':str(cache),'source_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in out.glob('*.ml*')}},indent=2)+'\n')

sys.exit(1 if any(results.values()) else 0)
