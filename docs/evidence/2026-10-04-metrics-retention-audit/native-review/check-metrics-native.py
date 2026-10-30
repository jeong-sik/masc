from pathlib import Path
import subprocess,json,tempfile,hashlib,sys
wd=Path(sys.argv[1]).resolve();root=Path(sys.argv[2]).resolve();baseline='2b230357cb72586fe0c20d5a07490a43cb93ecab'
out=Path(tempfile.mkdtemp(prefix='masc-metrics-retention-native-'));Path('/tmp/masc-metrics-retention-native-dir').write_text(str(out));print(out,flush=True)
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
for name in ['Fs_compat_internal','Fs_compat','Env_config_keeper']:visit(name)
# These full production modules are compiled under isolated names below.
objects=[p for p in objects if p.stem not in ['env_config_keeper']]
(out/'graph.json').write_text(json.dumps({'objects':list(map(str,objects)),'external':sorted(external)},indent=2)+'\n')
print('cached dependency objects',len(objects),'external',sorted(external),flush=True)
incs=sorted({str(p.parent.parent/'byte') for p in paths if '/native/' in str(p)})
packages='alcotest,yojson,uuidm,eio_main,mcp_protocol.eio,digestif.c,ptime,re,mirage-crypto-rng.unix,ipaddr,uri'
basecmd=['opam','exec','--switch=5.5.1','--','ocamlfind','ocamlopt','-opaque','-thread','-package',packages]
results={}
for variant in ['baseline','candidate']:
 dest=out/variant;dest.mkdir()
 def source(rel):return (wd/rel).read_text() if variant=='candidate' else subprocess.check_output(['git','show',baseline+':'+rel],cwd=root,text=True)
 def run(args):
  p=subprocess.run(args,cwd=dest,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
  if p.returncode:
   (dest/'failure.txt').write_text(p.stdout);raise RuntimeError(p.stdout[-3500:])
  return p.stdout
 cmd=basecmd+['-I',str(dest)]+[v for d in incs for v in ['-I',d]]+[v for p in objects for v in ['-I',str(p.parent)]]
 for unit,rel in [('rotation_fs_compat','lib/fs_compat/fs_compat'),('rotation_env_config_keeper','lib/config/env_config_keeper')]:
  for ext in ['mli','ml']:
   path=dest/(unit+'.'+ext);path.write_text(source(rel+'.'+ext));run(cmd+['-c',str(path)])
 text=source('lib/keeper/keeper_types_support.ml');start=text.index('let metrics_backup_number' if variant=='candidate' else 'let maybe_rotate_file')
 repair=source('lib/keeper/keeper_config_text.ml');repair=repair[repair.index('let utf8_repair_string'):]
 (dest/'rotation_support.ml').write_text('module Fs_compat = Rotation_fs_compat\nmodule Env_config = struct module KeeperMetrics = Rotation_env_config_keeper.KeeperMetrics end\n'+repair+'\n'+text[start:]);run(cmd+['-c','rotation_support.ml'])
 # The entire registered 24-case suite is unmodified; aliases bind its product
 # modules to the isolated source copies above, so the shared cache is untouched.
 suite=(wd/'test/test_metrics_rotation.ml').read_text()
 (dest/'test_metrics.ml').write_text('module Fs_compat = Rotation_fs_compat\nmodule Masc = struct module Keeper_types_support = Rotation_support end\n'+suite)
 stubs=list((root/'_build/default/lib').glob('**/lib*stubs.a'))
 run(cmd+['-linkpkg']+list(map(str,objects))+['rotation_fs_compat.cmx','rotation_env_config_keeper.cmx','rotation_support.cmx','test_metrics.ml','-o','test_metrics.exe']+[v for p in stubs for v in ['-cclib',str(p)]])
 p=subprocess.run([str(dest/'test_metrics.exe'),'--color=never'],cwd=dest,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (dest/'results.txt').write_text(p.stdout);results[variant]={'exit_code':p.returncode,'output':p.stdout};print(variant,'exit',p.returncode,p.stdout[-1600:],flush=True)
(out/'summary.json').write_text(json.dumps(results,indent=2)+'\n')
files=['lib/fs_compat/fs_compat.ml','lib/fs_compat/fs_compat.mli','lib/config/env_config_keeper.ml','lib/config/env_config_keeper.mli','lib/keeper/keeper_types_support.ml','lib/keeper/keeper_config_text.ml','test/test_metrics_rotation.ml']
(out/'manifest.json').write_text(json.dumps({'baseline':baseline,'scope':'complete actual Fs_compat/Env_config_keeper under isolated module names, exact JSONL rotation/append source and UTF-8 repair source; unmodified complete 24-case metrics suite; real Stdlib/Eio filesystem I/O in temporary dirs; cached dependencies; no full product build or TOML-loader test','sha256':{p:hashlib.sha256((wd/p).read_bytes()).hexdigest() for p in files}},indent=2)+'\n')
if results['candidate']['exit_code']:raise SystemExit(1)
