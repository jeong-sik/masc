#!/usr/bin/env python3
import ast,copy,hashlib,json,pathlib
OUT=pathlib.Path(__file__).resolve().parent;ROOT=OUT.parent
source=(OUT/'mixed_probe.after.py').read_text();tree=ast.parse(source)
cls=next(n for n in tree.body if isinstance(n,ast.ClassDef) and n.name=='PlainText')
ns={};exec(compile(ast.Module(body=[cls],type_ignores=[]),'snapshot:PlainText','exec'),ns);PlainText=ns['PlainText']
fn=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='run')
loop=next(n for n in fn.body if isinstance(n,ast.For) and isinstance(n.iter,ast.Name) and n.iter.id=='chunks')
ack=compile(ast.Module(body=[fn.body[fn.body.index(loop)-1],loop],type_ignores=[]),'snapshot:offline-ack','exec')
def ref_ack(chunks,records):
 decoder=PlainText();tail=b'';keep=max(len(x['prefix'].encode()) for x in records)-1
 for at,data in chunks:
  window=tail+decoder.feed(data)
  for r in records:
   if r['ack_at'] is None and r['sent_at']<=at and r['prefix'].encode() in window:r['ack_at']=at
  tail=window[-keep:] if keep else b''
 return records
rows=[]
for dirname in ['mixed-eb4-fast-drain','mixed-eb4-profile-fast','mixed-eb4-corrected','alloc-eb4-final-probe','submit-unicode-eb4']:
 for file in sorted((ROOT/dirname).glob('*/result.json')):
  d=json.loads(file.read_text());raw=(file.parent/'capture.ansi').read_bytes();offset=0;chunks=[]
  for q in d['chunks']:
   chunks.append((q['at'],raw[offset:offset+q['bytes']]));offset+=q['bytes']
  assert offset==len(raw),(str(file),offset,len(raw))
  original=[r['ack_at'] for r in d['records']]
  records=[dict(r,ack_at=None) for r in d['records']]
  state={'chunks':chunks,'records':copy.deepcopy(records),'decoder':PlainText(),'plain_tail':b''};exec(ack,state)
  bounded=[r['ack_at'] for r in state['records']]
  full=[r['ack_at'] for r in ref_ack(chunks,copy.deepcopy(records))]
  posts=[q for q in d.get('posts',[]) if q['path']=='/api/v1/keepers/chat/stream']
  rows.append({'run':dirname+'/'+file.parent.name,'result_sha256':hashlib.sha256(file.read_bytes()).hexdigest(),'raw_sha256':hashlib.sha256(raw).hexdigest(),'raw_chunk_sizes_match':offset==len(raw),'records':len(records),'original_to_current_ack_differences':[i for i in range(len(original)) if original[i]!=bounded[i]],'current_to_full_scan_ack_differences':[i for i in range(len(original)) if bounded[i]!=full[i]],'current_unacknowledged':sum(t is None for t in bounded),'full_scan_unacknowledged':sum(t is None for t in full),'pageup_position_events':sum(s['name']=='position' for s in d['sends']),'scroll_events':sum(s['name']==d['condition'] for s in d['sends']),'complete':d['observation'].get('complete'),'errors':d['errors'],'final_prefix_occurs_in_retained_raw':records[-1]['prefix'].encode() in raw,'chat_post_count':len(posts),'posted_message_matches_final_prefix':len(posts)==1 and posts[0]['body'].get('message')==records[-1]['prefix'] if posts else None,'posted_message_sha256':hashlib.sha256(posts[0]['body'].get('message','').encode()).hexdigest() if len(posts)==1 else None})
output={'scope':'offline replay of retained synthetic PTY bytes only; no executable, PTY, HTTP or process started','decoder_snapshot_sha256':hashlib.sha256(source.encode()).hexdigest(),'runs':rows}
(OUT/'capture-replay-results.after.json').write_text(json.dumps(output,indent=2)+'\n')
print(json.dumps(output,indent=2))
