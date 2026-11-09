#!/usr/bin/env python3
"""Execute only snapshotted PlainText and offline ACK AST over byte fixtures."""
import ast,copy,hashlib,json,pathlib
OUT=pathlib.Path(__file__).resolve().parent
source=(OUT/'mixed_probe.py').read_text();tree=ast.parse(source)
cls=next(n for n in tree.body if isinstance(n,ast.ClassDef) and n.name=='PlainText')
ns={};exec(compile(ast.Module(body=[cls],type_ignores=[]),'snapshot:PlainText','exec'),ns)
PlainText=ns['PlainText']
run=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='run')
ackloop=next(n for n in run.body if isinstance(n,ast.For) and isinstance(n.iter,ast.Name) and n.iter.id=='chunks')
code=compile(ast.Module(body=[ackloop],type_ignores=[]),'snapshot:offline-ack','exec')
def ack(chunks,prefix='M0123456789:a'):
 records=[{'prefix':prefix,'sent_at':1.0,'ack_at':None}]
 d={'chunks':chunks,'records':records,'decoder':PlainText(),'plain_tail':b''}
 exec(code,d)
 return records[0]['ack_at']
results=[]
prefix=b'M0123456789:a'
seqs={'osc-bel':b'A\x1b]title;'+prefix+b'\x07B','osc-st':b'A\x1b]title;'+prefix+b'\x1b\\B','dcs-st':b'A\x1bPq'+prefix+b'\x1b\\B','pm-st':b'A\x1b^'+prefix+b'\x1b\\B','apc-st':b'A\x1b_'+prefix+b'\x1b\\B','csi-sgr':b'A\x1b[1;32mB\x1b[0m'}
for name,data in seqs.items():
 outputs=[];acks=[]
 for k in range(len(data)+1):
  decoder=PlainText();chunks=[data[:k],data[k:]]
  outputs.append(b''.join(decoder.feed(c) for c in chunks)==b'AB')
  acks.append(ack([(2.0,c) for c in chunks]) is None)
 decoder=PlainText();onebytes=b''.join(decoder.feed(bytes([c])) for c in data)
 results.append({'case':name,'single_cut_count':len(data)+1,'all_decoded_AB':all(outputs),'all_hidden_prefix_unacknowledged':all(acks),'one_byte_chunks_decoded_AB':onebytes==b'AB'})
marker=b'\x1b[?7h'
marker_results=[]
for cut in range(len(marker)+1):
 tail=b'';seen=False
 for data in [b'abc'+marker[:cut],marker[cut:]+b'def']:
  seen|=marker in tail+data;tail=(tail+data)[-4:]
 marker_results.append(seen)
results.append({'case':'frame-end-marker-every-single-split','cuts':len(marker_results),'all_recognized':all(marker_results)})
stream=prefix+b'X'*17000
single=ack([(2.0,stream)])
split=ack([(2.0,stream[:1000]),(2.0,stream[1000:])])
results.append({'case':'valid-prefix-before-retained-tail','read_bytes':len(stream),'max_os_read_bytes':65536,'prefix_emit_at':2.0,'single_read_ack':single,'same_stream_same_timestamp_split_reads_ack':split,'chunk_partition_invariance':single==split,'expected_ack':2.0,'source_line':ackloop.body[0].lineno})
d={'scope':'pure byte fixtures; no imports of fixture servers, no PTY, no process or user TUI','snapshot_sha256':hashlib.sha256(source.encode()).hexdigest(),'results':results,'ack_loop_lineno':ackloop.lineno}
(OUT/'pure-byte-fixture-results.json').write_text(json.dumps(d,indent=2)+'\n')
print(json.dumps(d,indent=2))
