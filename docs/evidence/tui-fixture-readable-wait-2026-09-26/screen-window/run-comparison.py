from pathlib import Path
from datetime import datetime, timezone
import importlib.util
import difflib,json,os,platform,re,statistics,subprocess,sys

root,artifact,out=map(lambda x:Path(x).resolve(),sys.argv[1:])
assert platform.system()=='Darwin' and platform.machine()=='arm64'
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()=='4d31a42ca9c948d9c1605625dd45c2b6c122d0a3'
assert not subprocess.check_output(['git','diff','--name-only','HEAD','--','test','scripts/harness/perf'],cwd=root,text=True).strip()
spec=importlib.util.spec_from_file_location('comparison',root/'scripts/harness/perf/compare_tui_artifacts.py')
c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
os.environ['GITHUB_REPOSITORY_ID']='1136640865'
identity=c.verify(artifact,source_commit='53f784617c1867b3ecadb300bc8bd1d0844dd233',run_id=36239521218,artifact_id=10905313235)
binary=Path(identity['binary']);binary_hash=identity['manifest']['sha256']['masc_tui.exe']
helper=root/'test/test_tui_keyboard_input.py';helper_hash=c.digest(helper)
original=(root/'test/test_tui_input_frame_pty.py').read_text()
old='                screen = h.screen_text(bytes(output[:end + len(h.FRAME_END)]))'
assert original.count(old)==1
window='''                redraw = output.rfind(h.FULL_REDRAW, 0, end)
                start = max(0, redraw)
                screen = h.screen_text(bytes(output[start:end + len(h.FRAME_END)]))'''
oracle=window+'''
                if screen != h.screen_text(bytes(output[:end + len(h.FRAME_END)])):
                    raise AssertionError("latest full redraw differs from whole-history screen")'''
out.mkdir(exist_ok=False)
variants={'whole':original,'window':original.replace(old,window),'oracle':original.replace(old,oracle)}
for role,source in variants.items():(out/(role+'.py')).write_text(source)
(out/'observer.diff').write_text(''.join(difflib.unified_diff(original.splitlines(True),variants['window'].splitlines(True),fromfile='whole.py',tofile='window.py')))
(out/'identity.json').write_text(json.dumps(identity,indent=2)+'\n')
env={k:v for k,v in os.environ.items() if not k.startswith('MASC_') and k!='PYTHONOPTIMIZE'}
env['PYTHONPATH']=str(root/'test')
expected_preflight=None;receipts=[];execution_order=[]
def run(role,repetition,cycles):
 global expected_preflight
 name=f'{repetition:02d}-{role}'
 scenario=out/(role+'.py');scenario_hash=c.digest(scenario)
 frame=out/(name+'.frame-timing.txt')
 code,stdout=c.run_scenario(scenario,binary,cycles=cycles,retained_channels=250,metadata_path=None,root=root,environment={**env,'MASC_TUI_FRAME_TIMING':str(frame)},out=out,name=name)
 if code or 'input and scroll frames: PASS' not in stdout.splitlines():raise RuntimeError((name,code))
 observations=[json.loads(l) for l in stdout.splitlines() if l.startswith('{')]
 assert len(observations)==1
 obs=observations[0];c.validate_observation(obs,cycles=cycles,retained_channels=250)
 assert obs['binary_sha256']==binary_hash==c.digest(binary)
 assert obs['script_sha256']==scenario_hash==c.digest(scenario)
 assert c.digest(helper)==helper_hash
 if expected_preflight is None:expected_preflight=obs['preflight']
 else:assert expected_preflight==obs['preflight']
 assert not (out/(name+'.stderr.txt')).read_bytes()
 receipt={'role':role,'repetition':repetition,'frame_timing_file':frame.name,**obs}
 (out/(name+'.json')).write_text(json.dumps(receipt,indent=2)+'\n')
 present=frame.read_text().split('present frames=')[1]
 worst=next(l.strip() for l in present.splitlines() if 'worst[0]' in l)
 print(json.dumps({'session':name,'transitions':len(obs['samples']),'worst_present':worst}),flush=True)
 return receipt
# A separate oracle run checks identical completed-screen reconstruction. Its
# extra decode is deliberately excluded from the controlled timing comparison.
run('oracle',0,10)
for repetition in range(1,4):
 for role in (('whole','window') if repetition%2 else ('window','whole')):
  receipts.append(run(role,repetition,10));execution_order.append(role)
summary={'observed_at':datetime.now(timezone.utc).isoformat(),'runner_sha256':c.digest(Path(__file__)),'platform':platform.platform(),'python':sys.version,'binary_source':'53f784617c1867b3ecadb300bc8bd1d0844dd233','harness_source':'4d31a42ca9c948d9c1605625dd45c2b6c122d0a3','helper_sha256':helper_hash,'scenario_sha256':{role:c.digest(out/(role+'.py')) for role in variants},'execution_order':execution_order,'comparison_transitions':sum(len(r['samples']) for r in receipts),'oracle_transitions':100,'preflight':expected_preflight,'scope':'Same local macOS ARM host and exact diagnostic binary. Only retained Channels readiness screen reconstruction differs: whole terminal history vs suffix from latest completed clear-screen. Oracle extra decoding is outside comparison. No product speedup/deployment/physical display proof.'}
(out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print('observer comparison: PASS',flush=True)
