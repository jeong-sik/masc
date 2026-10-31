"""Reject late duplicate, malformed HTTP/JSON and outcome-record failures."""
import argparse
import hashlib
import http.client
import json
from pathlib import Path
import sys

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--repo',type=Path,required=True)
parser.add_argument('--binary',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
parser.add_argument('--case',choices=['duplicate','malformed','http-method','outcome-write'],default='duplicate')
args=parser.parse_args()
repo=args.repo.resolve(strict=True)
target=args.output.resolve()
target.mkdir(parents=True,exist_ok=False)
sys.path.insert(0,str(repo/'scripts/harness/perf'))
import keeper_scale_session as session

serve=session.Fixture.serve
snapshot=session.Fixture.coverage_snapshot
provider={}
if args.case=='outcome-write':
    original_open=Path.open
    def fail_outcome_open(path,*a,**kw):
        if path.name=='model-outcomes.jsonl' and provider.get('inject_outcome_failure'):
            raise OSError('injected outcome record failure')
        return original_open(path,*a,**kw)
    Path.open=fail_outcome_open

def serve_owned(fixture):
    server,thread=serve(fixture)
    provider['server']=server
    provider['fixture']=fixture
    return server,thread

def replay_after_first_snapshot(fixture):
    assert fixture.handlers_idle.wait(timeout=5)
    captured=snapshot(fixture)
    if not provider.get('replayed'):
        assert captured['actual_model_calls']==4 and not captured['errors']
        provider['replayed']=True
        provider['inject_outcome_failure']=args.case=='outcome-write'
        # Only synthetic data from this owned fixture, never operator inputs.
        request=[] if args.case=='malformed' else fixture.requests[0]['request']
        client=http.client.HTTPConnection('127.0.0.1',provider['server'].server_port,timeout=15)
        try:
            client.request('PUT' if args.case=='http-method' else 'POST',
                           '/v1/chat/completions',json.dumps(request),{'Content-Type':'application/json'})
            response=client.getresponse()
            response.read()
            assert response.status=={'malformed':500,'http-method':501}.get(args.case,200)
        finally:
            client.close()
    return captured

session.Fixture.serve=serve_owned
session.Fixture.coverage_snapshot=replay_after_first_snapshot
sys.argv=[str(session.__file__),'--binary',str(args.binary.resolve(strict=True)),
          '--repo',str(repo),'--output',str(target/'owned-run'),'--keepers','2','--settle-timeout','120']
try:
    session.main()
except session.ProbeError as error:
    rejection=str(error)
else:
    raise AssertionError('late duplicate provider call was accepted')
assert rejection==('final model request coverage is missing or duplicated' if args.case=='duplicate'
                   else 'provider error recorded through shutdown')
if args.case=='outcome-write':
    assert any(row.get('stage')=='provider_handler' and row.get('error')=='OSError' for row in provider['fixture'].errors)
read=lambda name:json.loads((target/'owned-run'/name).read_text())
before,after=read('model-coverage-before-shutdown.json'),read('model-coverage.json')
assert before['actual_model_calls']==4 and after['actual_model_calls']==(4 if args.case in ['malformed','http-method'] else 5)
cleanup=read('fallback-cleanup.json')
assert cleanup['server_reaped'] and cleanup['server_returncode']==0 and cleanup['model_server_stopped']
assert provider['server'].fileno()==-1
result={'verdict':'PASS','scope':'Real isolated native 2-Keeper workload: four normal model calls, followed by the explicitly named injected case. Not performance evidence.',
        'rejection':rejection,'case':args.case,'before_model_calls':None if before is None else before['actual_model_calls'],'final_model_calls':None if after is None else after['actual_model_calls'],'server_reaped':True,
        'model_socket_closed':True,'tested_source_sha256':hashlib.sha256(Path(session.__file__).read_bytes()).hexdigest()}
(target/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
