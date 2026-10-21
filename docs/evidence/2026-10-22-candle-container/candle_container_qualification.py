"""One manual Docker/persistent-store qualification; not a host-runtime or UI test."""
import datetime
import hashlib
import json
from pathlib import Path
import subprocess

config_path=Path('/tmp/masc-addon-goal-resume-20261021/candle-container-session-20261022.json')
c=json.loads(config_path.read_text());root=Path(c['root']);events=[];owned=[]
def now():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def command(argv,**kwargs):
    p=subprocess.run(argv,text=True,capture_output=True,**kwargs)
    events.append({'at':now(),'argv':argv,'exit_code':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
    (root/'docker-commands.json').write_text(json.dumps(events,indent=2)+'\n')
    if p.returncode:raise RuntimeError('Command failed: '+argv[1]+': '+p.stderr)
    return p.stdout

def inspect_container(cid):
    info=json.loads(command(['docker','container','inspect',cid]))[0]
    if info['Id']!=cid or info['Config']['Labels'].get('masc.proof-owner')!=c['owner']:
        raise RuntimeError('Container owner identity does not match')
    return info

def remove_owned(cid):
    info=inspect_container(cid)
    if info['State']['Running']:raise RuntimeError('Expected completed stdio worker before removal')
    command(['docker','container','rm',cid]);owned.remove(cid)

def call(name,args):return {'method':'tools/call','params':{'name':name,'arguments':args}}
def submit(req):return call('lane_call',{'tool':'candle_appraise','arguments':{'kind':'submit','request':req},'caller':{'kind':'operator'}})
def read(rid):return call('lane_call',{'tool':'candle_appraise','arguments':{'kind':'read','request_id':rid},'caller':{'kind':'operator'}})
def listing():return call('lane_host_requests',{})
def deliver(rid,result):return call('lane_host_result',{'request_id':rid,'result':result})
def value(reply):
    v=reply.get('result',{})
    if v.get('isError') or 'structuredContent' not in v:raise RuntimeError('Unexpected MCP refusal: '+json.dumps(reply))
    return v['structuredContent']
def refuse(reply):
    if not reply.get('result',{}).get('isError'):raise RuntimeError('Expected original-identity refusal')

def cycle(label,ops):
    package=root/'addons/candle-appraiser'
    argv=['docker','container','create','--pull','never','--name',c['owner']+'-'+label,
          '--label','masc.proof-owner='+c['owner'],'--label','masc.proof-incarnation='+label,
          '--cpus','0.5','--memory','134217728','--memory-swap','134217728','--pids-limit','16',
          '--network','none','--read-only','--cap-drop','ALL','--security-opt','no-new-privileges',
          '--interactive','--workdir','/addon','--mount',f'type=bind,src={package},dst=/addon,readonly',
          '--mount',f'type=volume,src={c["volume"]},dst=/state','--',c['image'],'python3','server.py','--state','/state']
    cid=command(argv).strip();owned.append(cid)
    c.setdefault('containers',[]).append({'incarnation':label,'id':cid});config_path.write_text(json.dumps(c,indent=2)+'\n')
    requests=[{'method':'initialize','params':{'capabilities':{}}},call('lane_observe',{'context':{'instance_id':label,'incarnation':label},'binding':{'sources':[]},'sources':[]}),*ops]
    body='\n'.join(json.dumps({'jsonrpc':'2.0','id':i,**v},ensure_ascii=False) for i,v in enumerate(requests,1))+'\n'
    (root/(label+'-requests.jsonl')).write_text(body)
    text=command(['docker','container','start','--attach','--interactive',cid],input=body)
    (root/(label+'-replies.jsonl')).write_text(text)
    info=inspect_container(cid);(root/(label+'-container-inspect.json')).write_text(json.dumps(info,indent=2)+'\n')
    if info['State']['ExitCode']!=0:raise RuntimeError('Worker exit failed')
    replies=[json.loads(l) for l in text.splitlines()]
    if [r.get('id') for r in replies]!=list(range(1,len(requests)+1)):raise RuntimeError('Incomplete original RPC responses')
    return cid,replies[2:]

original={'request_id':'container-grade-1','identity':{'goal_id':'synthetic-goal','request_id':'synthetic-payout','verification_run_id':'synthetic-proof'},'stage':'grade','input':{'goal':{'title':'Synthetic container qualification only'}},'schema':{'type':'object','properties':{'grade':{'enum':['A']}},'required':['grade'],'additionalProperties':False},'prompt':'Scripted response qualification; no real model invocation.'}
uncertain={**original,'request_id':'container-unknown-1'}
answer={'status':'answered','output':{'grade':'A'},'slot':'scripted-container-slot','usage':{'input_tokens':11,'output_tokens':3}}
unknown={'status':'outcome_unknown'}
started=now();result={}
try:
    image=json.loads(command(['docker','image','inspect',c['image']]))[0]
    if image['Config']['Labels'].get('masc.proof-owner')!=c['owner']:raise RuntimeError('Image owner mismatch')
    (root/'image-inspect.json').write_text(json.dumps(image,indent=2)+'\n')
    command(['docker','volume','create','--label','masc.proof-owner='+c['owner'],c['volume']])
    vol=json.loads(command(['docker','volume','inspect',c['volume']]))[0]
    if vol['Labels'].get('masc.proof-owner')!=c['owner']:raise RuntimeError('Volume owner mismatch')
    (root/'volume-created.json').write_text(json.dumps(vol,indent=2)+'\n')
    a,ra=cycle('first',[submit(original),submit(uncertain),listing()])
    if value(ra[0])['state']!='pending' or value(ra[1])['state']!='pending':raise RuntimeError('New intents not pending')
    expected=value(ra[2])['requests'];remove_owned(a)
    (root/'volume-after-first-container-removal.json').write_text(command(['docker','volume','inspect',c['volume']]))
    b,rb=cycle('second',[listing(),deliver(original['request_id'],answer),read(original['request_id']),deliver(uncertain['request_id'],unknown),read(uncertain['request_id']),listing()])
    if value(rb[0])['requests']!=expected:raise RuntimeError('Original pending intents changed across containers')
    if value(rb[2])!={'request_id':original['request_id'],'state':'finished','result':answer}:raise RuntimeError('Answer not retained')
    if value(rb[4])!={'request_id':uncertain['request_id'],'state':'finished','result':unknown}:raise RuntimeError('Unknown outcome not retained')
    if value(rb[5])!={'requests':[]}:raise RuntimeError('Terminal work relisted')
    remove_owned(b)
    changed={**original,'prompt':'Changed input must refuse reuse'}
    other={**answer,'output':{'grade':'B'}}
    cid,rc=cycle('third',[read(original['request_id']),submit(original),deliver(original['request_id'],answer),deliver(original['request_id'],other),submit(changed),read(uncertain['request_id']),listing()])
    if value(rc[0])['result']!=answer or value(rc[1])['result']!=answer or value(rc[2])!={'accepted':True}:raise RuntimeError('Original terminal not reusable')
    refuse(rc[3]);refuse(rc[4])
    if value(rc[5])['result']!=unknown or value(rc[6])!={'requests':[]}:raise RuntimeError('Terminal unknown redispatched after reconnect')
    (root/'retained-state').mkdir()
    command(['docker','container','cp',cid+':/state/.',str(root/'retained-state')]);remove_owned(cid)
    volume=json.loads(command(['docker','volume','inspect',c['volume']]))[0]
    if volume['Labels'].get('masc.proof-owner')!=c['owner']:raise RuntimeError('Volume owner changed before final cleanup')
    (root/'volume-before-final-cleanup.json').write_text(json.dumps(volume,indent=2)+'\n')
    command(['docker','volume','rm',c['volume']])
    result={'outcome':'passed','image_id':image['Id'],'pending_intents_across_container_replacement':2,'original_answer_retained':True,'terminal_unknown_retained':True,'same_terminal_redelivery_accepted':True,'different_terminal_and_input_reuse_refused':True,'terminal_requests_not_relisted':True,'volume':'same named volume survived first/second container removals; original state exported before final owned volume cleanup','provider':'scripted; none invoked','scope':'Direct Docker worker/persistent volume only. No host Runtime Off/On, common Exact provider, host payout ledger, TUI or Dashboard.'}
finally:
    result.update({'started_at':started,'finished_at':now(),'source':c['source'],'owned_containers_remaining':owned})
    (root/'receipt.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
