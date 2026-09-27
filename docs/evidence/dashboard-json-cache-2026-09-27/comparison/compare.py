from pathlib import Path
import argparse,hashlib,json,os,platform,signal,subprocess,sys,time
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--repo',type=Path,required=True);p.add_argument('--runner',type=Path,required=True)
for role in ('baseline','candidate'):
 p.add_argument('--'+role,type=Path,required=True);p.add_argument('--'+role+'-commit',required=True);p.add_argument('--'+role+'-run',type=int,required=True);p.add_argument('--'+role+'-artifact',type=int,required=True)
a=p.parse_args();a.output.mkdir(exist_ok=False);plan=[];expected={}
for role in ('baseline','candidate'):
 artifact_root=getattr(a,role);manifest=json.loads((artifact_root/'manifest.json').read_text());metadata=json.loads((artifact_root/'artifact.json').read_text())
 assert manifest['commit']==getattr(a,role+'_commit') and metadata['workflow_run']['head_sha']==manifest['commit']
 assert metadata['id']==getattr(a,role+'_artifact') and metadata['workflow_run']['id']==getattr(a,role+'_run')
 assert metadata['workflow_run']['repository_id']==metadata['workflow_run']['head_repository_id']==1136640865 and metadata['expired'] is False
 expected[role]={'source':manifest['commit'],'binary_sha256':manifest['sha256']['main_eio.exe'],'artifact_id':metadata['id'],'artifact_run':metadata['workflow_run']['id']}
assert expected['baseline']['source']!=expected['candidate']['source']
assert expected['baseline']['binary_sha256']!=expected['candidate']['binary_sha256']
for kind in ('ascii','multilingual'):
 for encoding in ('identity','gzip'):
  for rep in range(1,4):
   for role in (('baseline','candidate') if rep%2 else ('candidate','baseline')):
    label={'baseline':'before','candidate':'after_'}[role];name=f'{kind}-{encoding}-{rep}-{label}'
    command=[sys.executable,str(a.runner),str(getattr(a,role)),str(a.output/name),'--repo',str(a.repo),'--encoding',encoding,'--text-kind',kind,'--commit',getattr(a,role+'_commit'),'--run',str(getattr(a,role+'_run')),'--artifact-id',str(getattr(a,role+'_artifact')),'--cycles','20','--tasks','250']
    plan.append({'name':name,'role':role,'text_kind':kind,'encoding':encoding,'repetition':rep,'command':command})
(a.output/'plan.json').write_text(json.dumps({'plan':plan,'expected_identities':expected,'session_runner_sha256':hashlib.sha256(a.runner.read_bytes()).hexdigest(),'driver_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'command':[sys.executable,*sys.argv],'platform':platform.platform(),'python':sys.version,'started_at_unix':time.time(),'expected_samples_per_kind_encoding_role_phase':60,'design':'24sessions,960GETs;no pooling across text kind or requested encoding;fixed250seedtasks+20mutationcycles/session'},indent=2)+'\n')
def interrupted(signum,_frame):raise SystemExit(128+signum)
signal.signal(signal.SIGTERM,interrupted);signal.signal(signal.SIGINT,interrupted)
for entry in plan:
 print('START '+entry['name'],flush=True)
 with (a.output/(entry['name']+'.stdout.txt')).open('w') as out,(a.output/(entry['name']+'.stderr.txt')).open('w') as err:
  child=subprocess.Popen(entry['command'],stdout=out,stderr=err,start_new_session=True)
  try:child.wait()
  finally:
   if child.poll() is None:
    os.killpg(child.pid,signal.SIGTERM)
    try:child.wait(timeout=20)
    except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait(timeout=5)
 (a.output/(entry['name']+'.returncode.json')).write_text(json.dumps({'returncode':child.returncode})+'\n')
 if child.returncode:
  print('FAILED '+entry['name']+'; partial receipts retained',flush=True);sys.exit(child.returncode)
 print('PASS '+entry['name'],flush=True)
print('All planned sessions complete; timings still require independent aggregation/review.',flush=True)
