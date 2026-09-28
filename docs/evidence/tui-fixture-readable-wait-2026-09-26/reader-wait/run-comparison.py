from pathlib import Path
from datetime import datetime, timezone
import importlib.util
import difflib,json,os,platform,statistics,subprocess,sys
root,artifact,out=map(lambda x:Path(x).resolve(),sys.argv[1:])
assert platform.system()=='Darwin' and platform.machine()=='arm64'
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()=='4d31a42ca9c948d9c1605625dd45c2b6c122d0a3'
assert not subprocess.check_output(['git','diff','--name-only','HEAD','--','test','scripts/harness/perf'],cwd=root,text=True).strip()
spec=importlib.util.spec_from_file_location('comparison',root/'scripts/harness/perf/compare_tui_artifacts.py')
c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
os.environ['GITHUB_REPOSITORY_ID']='1136640865'
identity=c.verify(artifact,source_commit='53f784617c1867b3ecadb300bc8bd1d0844dd233',run_id=36239521218,artifact_id=10905313235)
binary=Path(identity['binary']);binary_hash=identity['manifest']['sha256']['masc_tui.exe']
helper=root/'test/test_tui_keyboard_input.py';original=helper.read_text()
start=original.index('def wait_for_fixture_state(');end=original.index('def wait_for_fixture_event(',start)
region=original[start:end]
assert region.count('        time.sleep(0.02)')==1
changed=region.replace('        time.sleep(0.02)','        select.select([master_fd], [], [], 0.02)')
variant=original[:start]+changed+original[end:]
out.mkdir(exist_ok=False)
helpers={}
for role,text in [('sleep',original),('readable',variant)]:
 directory=out/role;directory.mkdir()
 path=directory/'test_tui_keyboard_input.py';path.write_text(text);helpers[role]=path
(out/'helper.diff').write_text(''.join(difflib.unified_diff(original.splitlines(True),variant.splitlines(True),fromfile='sleep/test_tui_keyboard_input.py',tofile='readable/test_tui_keyboard_input.py')))
source=(root/'test/test_tui_input_frame_pty.py').read_text()
needle='import test_tui_keyboard_input as h'
assert source.count(needle)==1
source=source.replace(needle,needle+'\nassert Path(h.__file__).resolve() == Path(sys.path[1], "test_tui_keyboard_input.py").resolve()')
scenario=out/'scenario.py';scenario.write_text(source);scenario_hash=c.digest(scenario)
(out/'identity.json').write_text(json.dumps(identity,indent=2)+'\n')
env={k:v for k,v in os.environ.items() if not k.startswith('MASC_') and k!='PYTHONOPTIMIZE'}
receipts=[];expected_preflight=None;execution_order=[]
for repetition in range(1,4):
 for role in (('sleep','readable') if repetition%2 else ('readable','sleep')):
  name=f'{repetition:02d}-{role}';frame=out/(name+'.frame-timing.txt');helper_hash=c.digest(helpers[role])
  environment={**env,'MASC_TUI_FRAME_TIMING':str(frame),'PYTHONPATH':os.pathsep.join([str(helpers[role].parent),str(root/'test')])}
  code,stdout=c.run_scenario(scenario,binary,cycles=10,retained_channels=250,metadata_path=None,root=root,environment=environment,out=out,name=name)
  if code or 'input and scroll frames: PASS' not in stdout.splitlines():raise RuntimeError((name,code))
  observations=[json.loads(l) for l in stdout.splitlines() if l.startswith('{')]
  assert len(observations)==1
  obs=observations[0];c.validate_observation(obs,cycles=10,retained_channels=250)
  assert obs['binary_sha256']==binary_hash==c.digest(binary)
  assert obs['script_sha256']==scenario_hash==c.digest(scenario)
  assert c.digest(helpers[role])==helper_hash
  if expected_preflight is None:expected_preflight=obs['preflight']
  else:assert obs['preflight']==expected_preflight
  assert not (out/(name+'.stderr.txt')).read_bytes()
  receipt={'role':role,'repetition':repetition,'helper_sha256':helper_hash,'frame_timing_file':frame.name,**obs}
  (out/(name+'.json')).write_text(json.dumps(receipt,indent=2)+'\n');receipts.append(receipt);execution_order.append(role)
  present=frame.read_text().split('present frames=')[1]
  worst=next(l.strip() for l in present.splitlines() if 'worst[0]' in l)
  print(json.dumps({'session':name,'transitions':len(obs['samples']),'worst_present':worst}),flush=True)
summary={'observed_at':datetime.now(timezone.utc).isoformat(),'runner_sha256':c.digest(Path(__file__)),'platform':platform.platform(),'python':sys.version,'binary_source':'53f784617c1867b3ecadb300bc8bd1d0844dd233','harness_source':'4d31a42ca9c948d9c1605625dd45c2b6c122d0a3','helper_sha256':{role:c.digest(path) for role,path in helpers.items()},'scenario_sha256':scenario_hash,'execution_order':execution_order,'comparison_transitions':sum(len(r['samples']) for r in receipts),'preflight':expected_preflight,'scope':'Same local macOS ARM host, exact diagnostic binary and scenario. Only helper wait_for_fixture_state sleep(0.02) changes to readiness wait capped at0.02. Both use whole-history screen reconstruction. No product speedup/deployment/physical display proof.'}
(out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print('reader wait comparison: PASS',flush=True)
