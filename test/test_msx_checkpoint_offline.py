import tempfile,pathlib,json,subprocess,hashlib,base64,uuid,sys,os
script=str(pathlib.Path(__file__).resolve().parents[1]/'scripts/acknowledge-msx-checkpoint-offline.py')
with tempfile.TemporaryDirectory() as temp:
 base=pathlib.Path(temp).resolve(); root=base/'.masc'; pending=root/'tui/checkpoint-pending';pending.mkdir(parents=True)
 op=str(uuid.uuid4()); binding=dict(version=1,operation_id=op,restore=True,slot='quick',base_path=str(base),masc_root=str(root));raw=json.dumps(binding).encode();f=pending/(op+'.json');f.write_bytes(raw)
 other=pending/(str(uuid.uuid4())+'.json');other.write_text('retained');receipt=root/'msx/checkpoint-operations.sqlite3';receipt.parent.mkdir();receipt.write_bytes(b'unchanged receipt')
 args=[sys.executable,script,'--base-path',str(base),'--masc-root',str(root),'--operation-id',op,'--action','restore','--slot','quick']
 def run(extra=(),good=True):
  p=subprocess.run(args+list(extra),capture_output=True,text=True,timeout=5);assert (p.returncode==0)==good,(p.stdout,p.stderr);return p
 run(); assert f.read_bytes()==raw
 run(['--apply'],False)
 apply=['--apply','--writers-stopped-ack','all checkpoint writers and TUI clients are stopped and cannot restart','--outcome-ack','acknowledge unknown outcome without replay','--intent-sha256',hashlib.sha256(raw).hexdigest()]
 run(apply+['--slot','other'],False);run(apply+['--intent-sha256','0'*64],False)
 target=base/'intent';f.rename(target);f.symlink_to(target);run(apply,False);f.unlink();target.rename(f)
 f.rename(target);os.mkfifo(f);run(apply,False);f.unlink();target.rename(f)
 run(apply); assert not f.exists(); archived=json.loads((root/'tui/checkpoint-acknowledged'/(op+'.json')).read_text());assert base64.b64decode(archived['original_intent_base64'])==raw
 assert other.read_text()=='retained' and receipt.read_bytes()==b'unchanged receipt'
 f.write_bytes(raw);run(apply,False);assert f.read_bytes()==raw
 print('PASS: diagnosis read-only, acknowledgements required, binding/digest/symlink/FIFO refusal, exact durable backup, other intent/receipt preserved, archive reuse fails closed')
