"""Check retained scene roots against actual raw Keeper and composition results."""
from pathlib import Path
import argparse, hashlib, json
p=Path(__file__).resolve().parent
report=json.loads((p/'report.json').read_text())
audit=json.loads((p/'composition-audit.json').read_text())
rows=json.loads((p/'execution-receipts.json').read_text())
by_id={r['execution_id']:r for r in rows if r.get('record_kind')=='tool_call'}
raw={event['tool_use_id']:event for event in json.loads((p/'raw-tool-results.json').read_text())}
turn=json.loads((p/'turn-execution-ids.json').read_text())
assert [row['execution_id'] for row in audit['outer_calls']]==turn['execution_ids']
for row in audit['outer_calls']:
    event=raw[row['tool_use_id']]
    assert event['tool_result']==row['output'] and event['tool_name']==row['tool']
    assert event['tool_error']==(not row['success'])
expected={}
for outer in audit['outer_calls']:
    payload=json.loads(outer['output']) if outer['tool']!='keeper_skill' else None
    if outer['tool']=='BrowserRead': expected[outer['execution_id']]=payload
    elif payload and 'actions' in payload:
        for action in payload['actions']:
            if action['tool_name']=='BrowserRead':
                assert action['result']['disposition']=='completed'
                assert by_id[action['execution_id']]['tool_use_id']==action['tool_use_id']
                assert by_id[action['execution_id']]['input']==action['input']
                expected[action['execution_id']]=action['result']['data']
assert expected, 'run contains no browser observations'
proof=[]
for execution_id,data in expected.items():
    row=by_id[execution_id]
    refs=[r['_blob'] for r in row.get('artifact_refs',[]) if r.get('_blob',{}).get('mime')=='application/vnd.masc.browser-scene+json']
    assert len(refs)==1, f'{execution_id}: expected exactly one retained root'
    ref=refs[0]; sha=ref['sha256']
    blob=p/'observations'/sha
    raw=blob.read_bytes()
    assert len(raw)==ref['bytes'] and hashlib.sha256(raw).hexdigest()==sha
    observed=json.loads(raw)
    assert observed==data, f'{execution_id}: saved observation differs from model result'
    assert observed['schema']=='masc.browser.scene.v1'
    proof.append({'execution_id':execution_id,'tool_use_id':row['tool_use_id'],'reference':ref,
                  'url':observed['url'],'document_id':observed['documentId'],
                  'source':observed['source'],'client_id':observed['clientId'],
                  'tab_id':observed['tabId'],'scope':observed['scope'],'truncated':observed['truncated']})
assert not any(row['tool']=='keeper_artifact_read' for row in audit['outer_calls'])
result={'source_commit':report['build']['binary_commit'],'binary_sha256':report['binary_sha256'],
        'operation_id':report['operation_id'],'state':report['operation_state'],
        'outer_call_count':audit['outer_call_count'],'outer_errors':audit['outer_errors'],
        'retained_observation_count':len(proof),'artifact_reads_required':0,'observations':proof,
        'proof_scope':'Raw producer/composition data equals retained bytes after the browser and server closed; no historical TUI consumer or aligned screenshot claim.'}
assert result==json.loads((p/'retained-observation-audit.json').read_text())
for line in (p/'SHA256SUMS').read_text().splitlines():
    digest,name=line.split(None,1)
    assert hashlib.sha256((p/name).read_bytes()).hexdigest()==digest,name
print(json.dumps({k:v for k,v in result.items() if k!='observations'},ensure_ascii=False))
