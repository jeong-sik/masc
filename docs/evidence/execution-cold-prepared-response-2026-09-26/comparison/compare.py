from pathlib import Path
import argparse, hashlib, json, os, platform, signal, subprocess, sys, time
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--repo',type=Path,required=True);p.add_argument('--baseline',type=Path,required=True);p.add_argument('--candidate',type=Path,required=True);p.add_argument('--runner',type=Path,required=True);p.add_argument('--cycles',type=int,default=20);p.add_argument('--tasks',type=int,default=250);p.add_argument('--repetitions',type=int,default=3);a=p.parse_args()
a.output.mkdir(exist_ok=False)
identities={'baseline':('53f784617c1867b3ecadb300bc8bd1d0844dd233',36239521218,10905313235),'candidate':('887807abe0bfb2b3d2df7fbca7672faa199aa898',36241015541,10905529982)}
plan=[]
for encoding in ('identity','gzip'):
 for rep in range(1,a.repetitions+1):
  for role in (('baseline','candidate') if rep%2 else ('candidate','baseline')):
   commit,run,artifact_id=identities[role]
   label={'baseline':'before','candidate':'after_'}[role]
   name=f'{encoding}-{rep}-{label}'
   # before and after_ have equal length; role is retained separately.
   command=[sys.executable,str(a.runner),str(getattr(a,role)),str(a.output/name),'--repo',str(a.repo),'--encoding',encoding,'--commit',commit,'--run',str(run),'--artifact-id',str(artifact_id),'--cycles',str(a.cycles),'--tasks',str(a.tasks)]
   plan.append({'name':name,'role':role,'encoding':encoding,'repetition':rep,'command':command})
(a.output/'plan.json').write_text(json.dumps({'plan':plan,'session_runner_sha256':hashlib.sha256(a.runner.read_bytes()).hexdigest(),'driver_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'command':[sys.executable,*sys.argv],'platform':platform.platform(),'python':sys.version,'started_at_unix':time.time(),'expected_samples_per_encoding_role':a.repetitions*a.cycles},indent=2)+'\n')
def interrupted(signum,_frame):
 raise SystemExit(128+signum)
signal.signal(signal.SIGTERM,interrupted)
signal.signal(signal.SIGINT,interrupted)
for entry in plan:
 print('START '+entry['name'],flush=True)
 with (a.output/(entry['name']+'.stdout.txt')).open('w') as out,(a.output/(entry['name']+'.stderr.txt')).open('w') as err:
  result=subprocess.Popen(entry['command'],stdout=out,stderr=err,start_new_session=True)
  try:
   result.wait()
  finally:
   if result.poll() is None:
    os.killpg(result.pid,signal.SIGTERM)
    try:result.wait(timeout=20)
    except subprocess.TimeoutExpired:
     os.killpg(result.pid,signal.SIGKILL);result.wait(timeout=5)
 (a.output/(entry['name']+'.returncode.json')).write_text(json.dumps({'returncode':result.returncode})+'\n')
 if result.returncode:
  print('FAILED '+entry['name']+'; raw stdout/stderr and partial receipts retained',flush=True)
  sys.exit(result.returncode)
 print('PASS '+entry['name'],flush=True)
print('All sessions complete; timings require independent aggregation and review.',flush=True)
