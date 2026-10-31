from pathlib import Path
import subprocess,json,hashlib,shutil,time,os
root=Path.cwd();out=root/'artifacts/extreme-perf-20261030/frame-union-v3'; build=out/'build'
shutil.copyfile(out/'replay.ml',build/'replay.ml')
command=['ocamlfind','ocamlopt','-w','+4+32+69','-warn-error','+a','-package','yojson,mtime.clock.os,unix','-linkpkg','masc_tui_frame_timing.cmx','replay.ml','-o','replay.exe']
r=subprocess.run(command,cwd=build,capture_output=True,text=True)
(out/'replay-compile.stdout').write_text(r.stdout);(out/'replay-compile.stderr').write_text(r.stderr)
if r.returncode: print(r.stderr);raise SystemExit(r.returncode)
results=[]
for owners in (2,30,300):
 capture=root/f'docs/evidence/extreme-performance-20261030/native-tui-owners/owners-{owners}/tui-observer/frame-timing.txt'
 command=[str(build/'replay.exe'),str(capture)]
 r=subprocess.run(command,cwd=build,capture_output=True,text=True,check=True)
 with (out/f'native-replay-{owners}.json').open('x') as stream:stream.write(r.stdout)
 (out/f'native-replay-{owners}.stderr').write_text(r.stderr)
 actual={row['frame']:int(row['uncovered_ns']) for row in json.loads(r.stdout)}
 rows=[json.loads(line) for line in capture.read_text().splitlines() if line.startswith('{')]
 frames=[row for row in rows if row['schema']=='masc.tui.frame.v2' and row['phase']=='build']
 stage_rows=[row for row in rows if row['schema']=='masc.tui.stage.v1']
 comparisons=[]
 for frame in frames:
  start=int(frame['started_ns']);end=int(frame['completed_ns'])
  windows=[(int(row['started_ns']),int(row['completed_ns'])) for row in stage_rows if row['frame']==frame['frame']]
  assert windows and all(start<=a<=b<=end for a,b in windows)
  # Independent oracle partitions all endpoints and marks each segment by membership.
  boundaries=sorted({start,end,*[n for pair in windows for n in pair]})
  covered=sum(b-a for a,b in zip(boundaries,boundaries[1:]) if any(lo<=a and b<=hi for lo,hi in windows))
  expected=end-start-covered
  prior=max(0,end-start-sum(b-a for a,b in windows))
  assert actual[frame['frame']]==expected,(owners,frame['frame'],actual.get(frame['frame']),expected)
  comparisons.append({'frame':frame['frame'],'surface':frame['surface'],'expected_ns':str(expected),'old_sum_residual_ns':str(prior),'underreported_ns':str(expected-prior)})
 assert set(actual)=={row['frame'] for row in comparisons}
 result={'owners':owners,'builds_checked':len(comparisons),'underreported_builds':sum(int(row['underreported_ns'])>0 for row in comparisons),'maximum_underreported_ns':str(max(int(row['underreported_ns']) for row in comparisons)),'capture':str(capture.relative_to(root)),'capture_sha256':hashlib.sha256(capture.read_bytes()).hexdigest(),'replay_sha256':hashlib.sha256((out/'replay.ml').read_bytes()).hexdigest(),'decisions':comparisons}
 results.append(result)
 print({k:v for k,v in result.items() if k!='decisions'})
with (out/'comparison.json').open('x') as stream:json.dump({'scope':'Exact copied product module on retained native timer inputs; numeric endpoint-partition oracle. Not a new TUI run, CPU attribution or latency improvement.','results':results},stream,indent=2);stream.write('\n')
