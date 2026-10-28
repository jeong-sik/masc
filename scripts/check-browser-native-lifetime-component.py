#!/usr/bin/env python3
# Isolated lane component check; does not type-check the full host or upload path.
from pathlib import Path
import subprocess,tempfile,shutil,argparse
parser=argparse.ArgumentParser(description='Standalone actual browser-lane component checks, not full host proof')
mode=parser.add_mutually_exclusive_group()
mode.add_argument('--selection',action='store_true',help='run browser selection and Space binding scenarios')
mode.add_argument('--activity',action='store_true',help='run the browser routing/activity feature suite')
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='masc-native-lifetime-') as folder:
 d=Path(folder)
 subprocess.run(['ocamlfind','ocamlc','-predicates','ppx_driver','-package','ppx_enumerate,ppxlib.runner','-linkall','-linkpkg','-o',str(d/'ppx.exe')],check=True,cwd=d)
 files=[]
 for sub,name in [('time_compat','time_compat'),('monotonic_deadline','monotonic_deadline'),('watched_work','watched_work'),('browser_lane','browser_pointer'),('browser_lane','browser_action'),('browser_lane','browser_keyboard'),('browser_lane','browser_document'),('browser_lane','browser_lane_name'),('browser_lane','browser_lane_token'),('browser_lane','browser_native_workflow')]:
  for ext in ['mli','ml']:
   source=root/'lib'/sub/(name+'.'+ext)
   if source.exists():shutil.copyfile(source,d/source.name);files.append(source.name)
 # Root lane only aliases this module; none of these tests use upload leases.
 (d/'browser_upload_lease.ml').write_text('(* Unused upload-lease alias only; not upload/host integration proof. *)\n')
 files.append('browser_upload_lease.ml')
 test_name='test_browser_selection.ml' if args.selection else 'test_browser_lane.ml' if args.activity else 'test_browser_lane_watched_work.ml'
 sources=[root/'lib/browser_lane/browser_lane.ml']
 if args.selection:
  for name in ['browser_capabilities','browser_selection','browser_binding','browser_addon_inventory']:
   sources.extend(root/'lib'/(name+'.'+ext) for ext in ['mli','ml'])
 for source in sources:
  shutil.copyfile(source,d/source.name);files.append(source.name)
 if args.selection:
  (d/'masc.ml').write_text('module Browser_selection = Browser_selection\nmodule Browser_binding = Browser_binding\nmodule Browser_addon_inventory = Browser_addon_inventory\n')
  files.append('masc.ml')
 source=root/'test'/test_name
 shutil.copyfile(source,d/source.name);files.append(source.name)
 compiler=['ocamlfind','ocamlc','-w','+4+32+69','-warn-error','+a','-ppx',str(d/'ppx.exe')+' -as-ppx','-package','alcotest,eio,eio_main,eio.mock,mcp_protocol.eio,yojson,uuidm,uri,mtime.clock.os,ppx_enumerate.runtime-lib']
 subprocess.run([*compiler,'-c',*files[:-1]],check=True,cwd=d)
 # Match dune's test/ flags while keeping library sources strict above.
 subprocess.run([*compiler,'-w','-4-69','-linkpkg',*[Path(f).with_suffix('.cmo').name for f in files[:-1] if f.endswith('.ml')],files[-1],'-o','check'],check=True,cwd=d)
 subprocess.run([str(d/'check')],check=True,cwd=d)
 print('Actual lane sources and selected feature scenarios compiled/executed; unused upload lease alias stubbed, not full host proof.')
