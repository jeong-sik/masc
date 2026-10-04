from pathlib import Path
import subprocess,json,tempfile,hashlib,sys
wd=Path(sys.argv[1]).resolve(); root=Path(sys.argv[2]).resolve()
out=Path(tempfile.mkdtemp(prefix='masc-sampling-review-'))
print(f'Evidence directory: {out}', flush=True)
source_ref=sys.argv[3] if len(sys.argv)>3 else None
def source(path):
 return subprocess.check_output(['git','-C',str(wd),'show',source_ref+':'+path],text=True) if source_ref else (wd/path).read_text()
paths=list((root/'_build/default/lib').glob('**/*.cmx'))+list((root/'_build/default/packages').glob('**/*.cmx'))
index={p.stem[0].upper()+p.stem[1:]:p for p in paths if '/native/' in str(p)}
objects=[]; visited=set()
def visit(name):
 if name in visited:return
 visited.add(name)
 if name not in index:return
 p=index[name]; raw=subprocess.check_output(['opam','exec','--switch=5.5.1','--','ocamlobjinfo',str(p)],text=True)
 imported=raw.split('Implementations imported:\n',1)[1].split('Clambda approximation:',1)[0]
 for line in imported.splitlines():
  w=line.split()
  if len(w)==2:visit(w[1])
 objects.append(p)
visit('Masc__Lane_addon_store')
incs=sorted({str(p.parent.parent/'byte') for p in paths if '/native/' in str(p)})
cmd=['opam','exec','--switch=5.5.1','--','ocamlfind','ocamlopt','-opaque','-thread','-package','alcotest,yojson,uuidm,eio_main,mcp_protocol.eio,digestif.c,ptime,re,mirage-crypto-rng.unix,ipaddr,uri','-I',str(out)]+[v for d in incs for v in ['-I',d]]+[v for p in objects for v in ['-I',str(p.parent)]]
def run(args):
 r=subprocess.run(args,cwd=out,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 if r.returncode: (out/'failure.txt').write_text(r.stdout); raise RuntimeError(r.stdout[-4500:])
 return r.stdout
for ext in ['mli','ml']:
 src=source('lib/lane_addon/lane_addon_store.'+ext)
 (out/('masc__Lane_addon_store.'+ext)).write_text(src)
 run(cmd+['-open','Masc','-c','masc__Lane_addon_store.'+ext])
projection=source('lib/lane_addon/lane_addon_sampling.ml').split('let retained_receipts ',1)[1]
(out/'receipt_projection.ml').write_text('module Store = Masc__Lane_addon_store\nmodule Types = Masc__Lane_addon_types\nlet ( let* ) = Result.bind\nlet retained_receipts '+projection)
run(cmd+['-c','receipt_projection.ml'])
suite=(wd/'test/test_lane_sampling_receipt_recovery.ml').read_text().replace('module Sampling = Masc.Lane_addon_sampling','module Sampling = Receipt_projection').replace('Masc.Lane_addon_store','Masc__Lane_addon_store').replace('Masc.Lane_addon_types','Masc__Lane_addon_types')
(out/'probe.ml').write_text(suite)

linked=[out/p.name if p.stem=='masc__Lane_addon_store' else p for p in objects]
stubs=list((root/'_build/default/lib').glob('**/lib*stubs.a'))
run(cmd+['-linkpkg']+list(map(str,linked))+['receipt_projection.cmx','probe.ml','-o','probe.exe']+[v for p in stubs for v in ['-cclib',str(p)]])
execution=subprocess.run([str(out/'probe.exe'),'--color=never'],cwd=out,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
result=execution.stdout;print(result);(out/'results.txt').write_text(result)
(out/'manifest.json').write_text(json.dumps({'checkout':str(wd),'source_ref':source_ref,'exit_code':execution.returncode,'scope':'complete current Lane_addon_store and exact retained_receipts function, full registered regression suite with consumer alias; cached lower dependencies; actual filesystem','source_sha256':{f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in out.glob('*.ml*')}},indent=2))

for ext in ['mli','ml']:
 (out/('masc__Lane_addon_sampling.'+ext)).write_text(source('lib/lane_addon/lane_addon_sampling.'+ext))
 run(cmd+['-open','Masc','-c','masc__Lane_addon_sampling.'+ext])
(out/'full-consumer-typecheck.txt').write_text('Complete current Lane_addon_sampling.mli/ml typecheck passed against candidate Store and cached interfaces. Not a full product build.\n')

sys.exit(execution.returncode)
