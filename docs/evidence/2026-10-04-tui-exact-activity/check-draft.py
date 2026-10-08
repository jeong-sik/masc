"""Compile actual leaf modules with the pinned compiler; not the full TUI."""
import hashlib,json,os,pathlib,shutil,subprocess,tempfile
root=pathlib.Path.cwd(); out=pathlib.Path(tempfile.mkdtemp(prefix='masc-tui-activity-'))
# The caller names its OCaml 5.5.1 toolchain; the version is checked below.
compiler=pathlib.Path(os.environ.get('ACTIVITY_OCAML_BIN',str(pathlib.Path(shutil.which('ocamlc')).parent)))
env={**os.environ,'PATH':str(compiler)+os.pathsep+os.environ['PATH']}
paths=['lib/runtime/standalone_lane','lib/runtime_toml_namespace/runtime_toml_namespace','lib/toml_line_editor/toml_line_editor','bin/masc_tui_runtime_config_edit','bin/masc_tui_runtime_config_receipt','bin/masc_tui_exact_activity','test/test_tui_exact_activity']
sources={};commands=[]
for path in paths:
 for suffix in ['.mli','.ml']:
  source=root/(path+suffix)
  if source.exists():
   shutil.copyfile(source,out/source.name)
   sources[path+suffix]=hashlib.sha256(source.read_bytes()).hexdigest()
def run(args):
 commands.append(args);print('+ '+' '.join(args),flush=True);subprocess.run(args,cwd=out,env=env,check=True)
version=subprocess.check_output([str(compiler/'ocamlc'),'-version'],text=True).strip()
if version!='5.5.1': raise RuntimeError('Expected OCaml 5.5.1, got '+version)
for path in paths:
 name=pathlib.Path(path).name
 for suffix in ['.mli','.ml']:
  if (out/(name+suffix)).exists():
   run(['ocamlfind','ocamlc','-package','otoml,yojson,alcotest,ppx_enumerate','-w','+32+69','-warn-error','+a','-c',name+suffix])
run(['ocamlfind','ocamlc','-package','otoml,yojson,alcotest,ppx_enumerate','-linkpkg',*[pathlib.Path(p).name+'.cmo' for p in paths],'-o','test.exe'])
run(['./test.exe'])
evidence={'scope':'Actual full leaf modules and actual test; not full TUI typechecking/linking, PTY, backend or deployment evidence.','compiler':version,'sources':sources,'commands':commands,'directory':str(out)}
(root/'docs/evidence/2026-10-04-tui-exact-activity/draft-provenance.json').write_text(json.dumps(evidence,indent=2)+'\n')
