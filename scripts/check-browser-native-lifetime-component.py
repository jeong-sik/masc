#!/usr/bin/env python3
# Isolated lane component check; does not type-check the full host or upload path.
from pathlib import Path
import subprocess,tempfile,shutil
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
 for source in [root/'lib/browser_lane/browser_lane.ml',root/'test/test_browser_lane_watched_work.ml']:
  shutil.copyfile(source,d/source.name);files.append(source.name)
 subprocess.run(['ocamlfind','ocamlc','-w','+4+32+69','-warn-error','+a','-ppx',str(d/'ppx.exe')+' -as-ppx','-package','alcotest,eio,eio.mock,mcp_protocol.eio,yojson,uuidm,uri,mtime.clock.os,ppx_enumerate.runtime-lib','-linkpkg',*files,'-o','check'],check=True,cwd=d)
 subprocess.run([str(d/'check')],check=True,cwd=d)
 print('Actual lane sources and mock-clock tests compiled/executed; unused upload lease alias stubbed, not full host proof.')
