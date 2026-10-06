import hashlib,json,os,pathlib,shutil,subprocess,tempfile,sys
from datetime import datetime,timezone
root=pathlib.Path(sys.argv[1]).resolve()
out=pathlib.Path(tempfile.mkdtemp(prefix='masc-browser-activity-audit-'))
report=pathlib.Path(__file__).resolve().parent
sources={}; commands=[]
for directory in ['lib/browser_lane','lib/browser_configuration','lib/runtime_toml_namespace','lib/time_compat','lib/monotonic_deadline','lib/watched_work']:
 for source in sorted((root/directory).iterdir()):
  if source.suffix not in ['.ml','.mli']:continue
  dest=out/source.name
  if dest.exists():raise RuntimeError('source collision '+source.name)
  shutil.copyfile(source,dest)
  sources[str(source.relative_to(root))]=hashlib.sha256(source.read_bytes()).hexdigest()
source=root/'test/test_browser_activity.ml'
shutil.copyfile(source,out/source.name); sources[str(source.relative_to(root))]=hashlib.sha256(source.read_bytes()).hexdigest()
packages='alcotest,eio,eio_main,yojson,uuidm,unix,mtime.clock.os,mcp_protocol.eio,otoml,ppx_enumerate,ppx_deriving.show,ppx_deriving.eq'
def run(args):
 print('+ '+' '.join(args),flush=True)
 p=subprocess.run(args,cwd=out,text=True,capture_output=True)
 commands.append({'command':args,'exit_code':p.returncode})
 print(p.stdout,end='',flush=True); print(p.stderr,end='',flush=True)
 if p.returncode:raise subprocess.CalledProcessError(p.returncode,args)
 return p.stdout
passed=False
try:
 run(['ocamlc','-version'])
 files=sorted(p.name for p in out.iterdir() if p.suffix in ['.ml','.mli'])
 order=run(['ocamlfind','ocamldep','-package',packages,'-sort',*files]).split()
 for name in order:run(['ocamlfind','ocamlc','-w','+32+69','-warn-error','+a','-package',packages,'-c',name])
 objects=[str(pathlib.Path(name).with_suffix('.cmo')) for name in order if name.endswith('.ml')]
 run(['ocamlfind','ocamlc','-package',packages,'-linkpkg',*objects,'-o','test.exe'])
 run(['./test.exe']);passed=True
finally:
 (report/'leaf-provenance.json').write_text(json.dumps({'checked_at':datetime.now(timezone.utc).isoformat(),'passed':passed,'source_root':str(root),'base':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'scope':'Browser parser and actual admission leaf sources compiled/linked/executed; injected activity/executors. No full Runtime publication, server startup, real browser sessions, TUI, CI or deployment. No stub product modules.','scratch':str(out),'sources':sources,'commands':commands},indent=2)+'\n')
