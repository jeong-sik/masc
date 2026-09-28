from pathlib import Path
from datetime import datetime, timezone
import importlib.util
import json, os, platform, statistics, subprocess, sys

root, artifact, out = map(lambda x: Path(x).resolve(), sys.argv[1:])
assert platform.system() == 'Darwin' and platform.machine() == 'arm64'
assert subprocess.check_output(['git','rev-parse','HEAD'], cwd=root, text=True).strip() == '4d31a42ca9c948d9c1605625dd45c2b6c122d0a3'
assert not subprocess.check_output(['git','diff','--name-only','HEAD','--','test','scripts/harness/perf'],cwd=root,text=True).strip()
spec=importlib.util.spec_from_file_location('comparison', root/'scripts/harness/perf/compare_tui_artifacts.py')
c=importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
os.environ['GITHUB_REPOSITORY_ID']='1136640865'
identity=c.verify(artifact,source_commit='53f784617c1867b3ecadb300bc8bd1d0844dd233',run_id=36239521218,artifact_id=10905313235)
out.mkdir(exist_ok=False)
(out/'identity.json').write_text(json.dumps(identity,indent=2)+'\n')
scenario=root/'test/test_tui_input_frame_pty.py'
helper=root/'test/test_tui_keyboard_input.py'
scenario_hash,helper_hash=c.digest(scenario),c.digest(helper)
binary=Path(identity['binary'])
manifest_hash=identity['manifest']['sha256']['masc_tui.exe']
env={k:v for k,v in os.environ.items() if not k.startswith('MASC_')}
receipts=[]
for repetition in range(1,4):
 name=f'{repetition:02d}-diagnostic'
 frame=out/(name+'.frame-timing.txt')
 code,stdout=c.run_scenario(scenario,binary,cycles=10,retained_channels=250,metadata_path=None,root=root,environment={**env,'MASC_TUI_FRAME_TIMING':str(frame)},out=out,name=name)
 assert code == 0 and 'input and scroll frames: PASS' in stdout.splitlines(), (name,code)
 observations=[json.loads(line) for line in stdout.splitlines() if line.startswith('{')]
 assert len(observations)==1
 observation=observations[0]
 c.validate_observation(observation,cycles=10,retained_channels=250)
 assert observation['binary_sha256']==manifest_hash==c.digest(binary)
 assert observation['script_sha256']==scenario_hash==c.digest(scenario)
 assert c.digest(helper)==helper_hash
 assert frame.is_file() and frame.read_text().strip()
 if receipts: assert observation['preflight']==receipts[0]['preflight']
 receipt={'repetition':repetition,'frame_timing_file':frame.name,**observation}
 receipts.append(receipt)
 (out/(name+'.json')).write_text(json.dumps(receipt,indent=2)+'\n')
 values=[s['complete_frame_ms'] for s in receipt['samples']]
 print(json.dumps({'repetition':repetition,'transitions':len(values),'median_ms':statistics.median(values),'max_ms':max(values)}),flush=True)
summary={'observed_at':datetime.now(timezone.utc).isoformat(),'binary_source':'53f784617c1867b3ecadb300bc8bd1d0844dd233','scenario_source':'4d31a42ca9c948d9c1605625dd45c2b6c122d0a3','scenario_sha256':scenario_hash,'helper_sha256':helper_hash,'runner_sha256':c.digest(Path(__file__)),'platform':platform.platform(),'python':sys.version,'transitions':sum(len(r['samples']) for r in receipts),'preflight':receipts[0]['preflight'],'scope':'Local macOS ARM diagnostic on isolated synthetic fixture, 3 sessions, each 10 cycles and retained 250 channels. No baseline comparison, deployment, or physical display proof. This main-based binary does not include the separately reviewed drained-input or deferred-tab PRs.'}
(out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print('present output diagnostic: PASS',flush=True)
