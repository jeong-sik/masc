from pathlib import Path
import subprocess,json,tempfile,hashlib,sys
wd=Path(sys.argv[1]).resolve();root=Path(sys.argv[2]).resolve();out=Path(tempfile.mkdtemp(prefix='masc-dated-metrics-native-'));Path('/tmp/masc-dated-metrics-native-dir').write_text(str(out));print(out,flush=True)
paths=list((root/'_build/default/lib').glob('**/*.cmx'))+list((root/'_build/default/packages').glob('**/*.cmx'))
index={p.stem[0].upper()+p.stem[1:]:p for p in paths if '/native/' in str(p)}
objects=[];visited=set();external=set();objinfo=['opam','exec','--switch=5.5.1','--','ocamlobjinfo']
def visit(name):
 if name in visited:return
 visited.add(name)
 if name not in index:
  if not name.startswith(('Stdlib','Camlinternal')):external.add(name)
  return
 p=index[name];raw=subprocess.check_output(objinfo+[str(p)],text=True)
 imported=raw.split('Implementations imported:\n',1)[1].split('Clambda approximation:',1)[0]
 for line in imported.splitlines():
  words=line.split()
  if len(words)==2:visit(words[1])
 objects.append(p)
visit('Dated_jsonl')
incs=sorted({str(p.parent.parent/'byte') for p in paths if '/native/' in str(p)})
packages='alcotest,yojson,uuidm,eio_main,mcp_protocol.eio,digestif.c,ptime,re,mirage-crypto-rng.unix,ipaddr,uri'
cmd=['opam','exec','--switch=5.5.1','--','ocamlfind','ocamlopt','-opaque','-thread','-w','+8+32+69','-warn-error','+8+32+69','-package',packages,'-I',str(out)]+[v for d in incs for v in ['-I',d]]+[v for p in objects for v in ['-I',str(p.parent)]]
def run(args):
 p=subprocess.run(args,cwd=out,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 if p.returncode:(out/'failure.txt').write_text(p.stdout);raise RuntimeError(p.stdout[-3500:])
 return p.stdout
# Compile the complete actual date store as well as the new owner, retaining
# cached lower filesystem/time dependencies; no replacement storage behavior.
for unit,rel in [('dated_jsonl','lib/dated_jsonl/dated_jsonl'),('keeper_metrics_storage','lib/keeper/keeper_metrics_storage')]:
 for ext in ['mli','ml']:
  path=out/(unit+'.'+ext);path.write_bytes((wd/(rel+'.'+ext)).read_bytes());run(cmd+['-c',str(path)])
suite=(wd/'test/test_keeper_metrics_storage.ml').read_text()
(out/'test_keeper_metrics_storage.ml').write_text('module Masc = struct module Keeper_metrics_storage = Keeper_metrics_storage end\n'+suite)
linked=[out/p.name if p.stem=='dated_jsonl' else p for p in objects]
stubs=list((root/'_build/default/lib').glob('**/lib*stubs.a'))
run(cmd+['-linkpkg']+list(map(str,linked))+['keeper_metrics_storage.cmx','test_keeper_metrics_storage.ml','-o','test_keeper_metrics_storage.exe']+[v for p in stubs for v in ['-cclib',str(p)]])
report=run([str(out/'test_keeper_metrics_storage.exe'),'--color=never']);(out/'results.txt').write_text(report);print(report[-2400:])
files=['lib/dated_jsonl/dated_jsonl.mli','lib/dated_jsonl/dated_jsonl.ml','lib/keeper/keeper_metrics_storage.mli','lib/keeper/keeper_metrics_storage.ml','test/test_keeper_metrics_storage.ml']
(out/'manifest.json').write_text(json.dumps({'scope':'complete current Dated_jsonl and Keeper_metrics_storage, unmodified full registered storage suite under a module alias, cached lower dependencies; real temporary files in Stdlib/Eio modes; no full server build','source_sha256':{p:hashlib.sha256((wd/p).read_bytes()).hexdigest() for p in files},'cached_objects':list(map(str,objects))},indent=2)+'\n')
