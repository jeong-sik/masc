from pathlib import Path
import subprocess,json,hashlib,time,sys,os
root=Path.cwd();out=root/'artifacts/extreme-perf-20261030/keeper-list-matched-v1';runs=out/'runs';runs.mkdir()
variants={'control':('5297349b101d61bb901b3729d43c4dec8bb30ec4',root/'artifacts/extreme-perf-20261030/tui-prefix-native-v1'),
          'candidate':('5de2eb7684f0e4fecee1c48caef50010c2f951fa',root/'artifacts/extreme-perf-20261030/keeper-list-frame-native-v1')}
plan=[(2,'control'),(2,'candidate'),(30,'candidate'),(30,'control'),(300,'control'),(300,'candidate')]
records=[]
for population,variant in plan:
 source,binary_dir=variants[variant];receipt=json.loads((binary_dir/'receipt.json').read_text())
 assert receipt['source_sha']==source
 for name,expected in [('masc',receipt['server_sha256']),('masc-tui',receipt['sha256'])]:
  assert hashlib.sha256((binary_dir/name).read_bytes()).hexdigest()==expected
 target=runs/f'owners-{population}-{variant}'
 cmd=[sys.executable,str(root/'artifacts/extreme-perf-20261030/keeper-list-only-probe-v1/keeper_scale_session.py'),
      '--binary',str(binary_dir/'masc'),'--tui-binary',str(binary_dir/'masc-tui'),'--repo',str(root),
      '--output',str(target),'--keepers',str(population),'--messages-per-keeper','2']
 started=time.time();load=os.getloadavg();print(json.dumps({'event':'start','population':population,'variant':variant,'source':source,'at_unix':started}),flush=True)
 p=subprocess.run(cmd,capture_output=True,text=True)
 observation=json.loads((target/'tui-observer/observation.json').read_text()) if (target/'tui-observer/observation.json').exists() else {}
 identity=json.loads((target/'identity.json').read_text()) if (target/'identity.json').exists() else {}
 result={'population':population,'variant':variant,'source_expected':source,'source_actual':identity.get('source'),
         'command':cmd,'started_unix':started,'ended_unix':time.time(),'returncode':p.returncode,
         'stdout':p.stdout,'stderr':p.stderr,'capture_qualified':observation.get('capture_qualified',False),
         'loadavg_before':load,'loadavg_after':os.getloadavg(),'cpu_count':os.cpu_count()}
 with (runs/(target.name+'.execution.json')).open('x') as stream:json.dump(result,stream,indent=2);stream.write('\n')
 records.append(result)
 print(json.dumps({k:result[k] for k in ['population','variant','source_actual','returncode','capture_qualified','started_unix','ended_unix']}),flush=True)
 if population==2 and (p.returncode or not result['capture_qualified'] or identity.get('source')!=source):break
with (out/'execution.json').open('x') as stream:json.dump({'scope':'Planned paired native source observations; workload failure and TUI capture qualification separate. No retries, source speedup conclusion, applied UI cardinality or physical display claim.','plan':plan,'records':records},stream,indent=2);stream.write('\n')
raise SystemExit(0 if len(records)==len(plan) and all(row['returncode']==0 and row['capture_qualified'] for row in records) else 1)
