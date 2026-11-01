from pathlib import Path
import hashlib,json,subprocess,os,time,shutil
root=Path.cwd(); out=root/'artifacts/extreme-perf-20261030/frame-union-v3'; build=out/'build';build.mkdir()
files=['bin/masc_tui_frame_timing.mli','bin/masc_tui_frame_timing.ml','test/test_tui_frame_timing.ml']
source={}
for f in files:
 p=root/f;shutil.copyfile(p,build/p.name);source[f]=hashlib.sha256(p.read_bytes()).hexdigest()
env=os.environ.copy();env['MASC_TUI_FRAME_TIMING']='test-tui-frame-timing.report'
commands=[['ocamlc','-version'],['ocamlfind','ocamlopt','-w','+4+32+69','-warn-error','+a','-package','yojson,mtime.clock.os,unix,alcotest','-linkpkg','masc_tui_frame_timing.mli','masc_tui_frame_timing.ml','test_tui_frame_timing.ml','-o','test.exe'],['./test.exe','--color=never']]
receipts=[]
for i,cmd in enumerate(commands):
 started=time.time();r=subprocess.run(cmd,cwd=build,env=env,capture_output=True,text=True)
 (out/f'command-{i}.stdout').write_text(r.stdout);(out/f'command-{i}.stderr').write_text(r.stderr)
 receipts.append({'command':cmd,'cwd':str(build),'started_unix':started,'completed_unix':time.time(),'returncode':r.returncode,'stdout':f'command-{i}.stdout','stderr':f'command-{i}.stderr'})
 if r.returncode:break
(out/'receipt.json').write_text(json.dumps({'scope':'Standalone exact copied frame-timing module and focused existing/new numeric tests. No Dune or project/native TUI build; not physical display or performance proof.','source_sha256':source,'commands':receipts},indent=2)+'\n')
print(json.dumps({'success':len(receipts)==3 and all(r['returncode']==0 for r in receipts),'commands':receipts},indent=2))
if receipts[-1]['returncode']:print((out/receipts[-1]['stderr']).read_text())
raise SystemExit(receipts[-1]['returncode'])
