"""Run actual catalog/browser sources; manifest-loader and HTTP integration are outside this check."""
import hashlib, json, os, pathlib, shutil, subprocess, tempfile
root=pathlib.Path.cwd(); evidence=pathlib.Path(__file__).resolve().parent
compiler=pathlib.Path(os.environ['DISCOVERY_OCAML_BIN'])
env={**os.environ,'PATH':str(compiler)+os.pathsep+os.environ['PATH'],'NO_COLOR':'1'}
version=subprocess.check_output([str(compiler/'ocamlc'),'-version'],text=True).strip()
if version!='5.5.1': raise RuntimeError('Expected OCaml 5.5.1')
scratch=pathlib.Path(tempfile.mkdtemp(prefix='masc-package-discovery-'))
paths=['lib/lane_addon/lane_addon_catalog','masc','bin/masc_tui_package_browser','test/test_tui_package_browser']
(scratch/'masc.ml').write_text('module Lane_addon_catalog = Lane_addon_catalog\n')
sources={};commands=[]
for path in paths:
 for suffix in ['.mli','.ml']:
  source=root/(path+suffix)
  if source.exists():
   shutil.copyfile(source,scratch/source.name);sources[path+suffix]=hashlib.sha256(source.read_bytes()).hexdigest()
def run(command):
 print('+ '+' '.join(command),flush=True)
 result=subprocess.run(command,cwd=scratch,env=env)
 commands.append({'command':command,'returncode':result.returncode});result.check_returncode()
try:
 for path in paths:
  for suffix in ['.mli','.ml']:
   name=pathlib.Path(path).name+suffix
   if (scratch/name).exists():run(['ocamlfind','ocamlc','-package','unix,yojson,alcotest','-w','+32+69','-warn-error','+a','-c',name])
 run(['ocamlfind','ocamlc','-package','unix,yojson,alcotest','-linkpkg',*[pathlib.Path(p).name+'.cmo' for p in paths],'-o','check.exe'])
 run(['./check.exe'])
 # Typecheck the installer against the exact source interfaces, without
 # pretending these interfaces execute the schema form or declaration owner.
 for source_name in ['bin/masc_tui_schema_form.mli','bin/masc_tui_lane_declaration.mli','bin/masc_tui_lane_installer.mli','bin/masc_tui_lane_installer.ml']:
  source=root/source_name;shutil.copyfile(source,scratch/source.name)
  sources[source_name]=hashlib.sha256(source.read_bytes()).hexdigest()
  run(['ocamlfind','ocamlc','-package','yojson,otoml','-w','+32+69','-warn-error','+a','-c',source.name])
finally:
 (evidence/'provenance.json').write_text(json.dumps({'compiler':version,'sources':sources,'commands':commands,'scratch':str(scratch),'scope':'Actual catalog filesystem discovery and browser state machine. Masc is only a namespace alias to the complete actual catalog. Installer is separately typechecked against actual source interfaces without linking or executing its form/declaration dependencies. Manifest callback is controlled; real manifest parser, server, schema installer, native PTY and deployment are not executed.'},indent=2)+'\n')
