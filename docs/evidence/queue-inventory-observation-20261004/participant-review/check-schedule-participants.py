from pathlib import Path
import subprocess,json,tempfile,hashlib,sys
wd=Path(sys.argv[1]).resolve();root=Path(sys.argv[2]).resolve();base='f4e6ff0eb583a3354486a0a3cc334f144d8ec1c1'
out=Path(tempfile.mkdtemp(prefix='masc-schedule-participant-native-'));Path('/tmp/masc-schedule-participant-native-dir').write_text(str(out))
# Read cached dependency objects without building or modifying the shared cache.
paths=list((root/'_build/default/lib').glob('**/*.cmx'))+list((root/'_build/default/packages').glob('**/*.cmx'))
index={p.stem[0].upper()+p.stem[1:]:p for p in paths if '/native/' in str(p)}
objects=[];visited=set();external=set()
objinfo=['opam','exec','--switch=5.5.1','--','ocamlobjinfo']
def visit(name):
 if name in visited:return
 visited.add(name)
 if name not in index:
  if not name.startswith(('Stdlib','Camlinternal')):external.add(name)
  return
 path=index[name]
 raw=subprocess.check_output(objinfo+[str(path)],text=True)
 imports=raw.split('Implementations imported:\n',1)[1].split('Clambda approximation:',1)[0]
 for line in imports.splitlines():
  words=line.split()
  if len(words)==2:visit(words[1])
 objects.append(path)
for name in ['Schedule_domain','String_util','Log','Keeper_continuation_channel','Schedule_supported_kinds']:visit(name)
(out/'graph.json').write_text(json.dumps({'objects':list(map(str,objects)),'external':sorted(external)},indent=2)+'\n')
incs=sorted({str(path.parent.parent/'byte') for path in paths if '/native/' in str(path)})
packages='yojson,uuidm,eio_main,mcp_protocol.eio,digestif.c,ptime,re,mirage-crypto-rng.unix'
cmd=['opam','exec','--switch=5.5.1','--','ocamlfind','ocamlopt','-opaque','-thread','-package',packages]
probe=r'''open Schedule_domain
let actor kind id : actor = { kind; id; display_name=None }
let payload kind body = `Assoc ["kind",`String kind;"body",body]
let wake target = payload "masc.keeper_wake" (`Assoc ["keeper_name",`String target;"message",`String "verify"])
let opaque = payload "unsupported.test" (`Assoc [])
let malformed = payload "masc.keeper_wake" (`Assoc ["message",`String "missing target"])
let a = actor Automated_actor "a" and b=actor Automated_actor "b"
let human=actor Human_operator "a" and system=actor System "a"
let unknown=actor Automated_actor "unknown"
let cases = [
 "creator only",a,opaque,["a"];
 "B wakes A",b,wake "a",["b";"a"];
 "operator wakes A",human,wake "a",["a"];
 "operator wakes B",human,wake "b",["b"];
 "system wakes A",system,wake "a",["a"];
 "system wakes B",system,wake "b",["b"];
 "operator unrelated",human,opaque,[];
 "system unrelated",system,opaque,[];
 "unknown creator",unknown,opaque,["unknown"];
 "unknown wakes A",unknown,wake "a",["unknown";"a"];
 "self wake",a,wake "a",["a"];
 "A wakes B",a,wake "b",["a";"b"];
 "malformed target retains creator",b,malformed,["b"]]
let () =
 let pass=ref 0 and total=ref 0 and failures=ref [] in
 let check label ok = incr total; if ok then incr pass else failures:=label::!failures in
 List.iter (fun (label,scheduled_by,payload,participants) ->
  let request=match create_request ~schedule_id:"scope-check" ~requested_by:human ~scheduled_by
   ~requested_at:100. ~due_at:200. ~payload ~source:Operator_request () with
   | Ok request->request | Error e->failwith e in
  List.iter (fun scope->
   let expected=match scope with None->true | Some name->List.mem name participants in
   check (label^": world visibility") (World.schedule_visible_to_keeper scope request=expected))
   [None;Some "a";Some "b";Some "unknown"];
  List.iter (fun status ->
   let request={request with status} in
   let state:Schedule_store.state={version=1;updated_at=100.;schedules=[request];wakes=[];notes=[]} in
   let active=match status with Scheduled|Due|Running->true|Succeeded|Failed|Cancelled|Expired->false in
   List.iter(fun scope ->
    let expected=active && (match scope with None->true|Some name->List.mem name participants) in
    let names=match scope with None->["a";"b"]|Some name->[name] in
    let rows=Inventory.schedule_rows ?keeper_name:scope ~keeper_names:names state in
    let suffix=label^":"^schedule_status_to_string status^":"^(match scope with None->"fleet"|Some x->x) in
    check (suffix^": count") (List.length rows=(if expected then 1 else 0));
    if expected then match rows with
    | [row] ->
      check (suffix^": local owner")
       (row.Inventory.keeper_name=List.find_opt (fun n->List.mem n names) participants);
      check (suffix^": participants preserved")
       (Yojson.Safe.Util.member "keeper_participants" row.detail=`List(List.map(fun n->`String n)participants))
    | [] | _::_ -> check (suffix^": missing row") false)
   [None;Some "a";Some "b";Some "unknown"])
  [Scheduled;Due;Running;Succeeded;Failed;Cancelled;Expired]) cases;
 let result=`Assoc ["passed",`Int !pass;"total",`Int !total;
  "failures",`List (List.rev_map(fun label->`String label)!failures)] in
 Yojson.Safe.to_file "results.json" result;
 Printf.printf "%d/%d checks passed across 13 scenarios, 7 statuses and 4 scopes\n" !pass !total
'''
results={}
files=['lib/schedule_payload_projection.mli','lib/schedule_payload_projection.ml','lib/keeper/keeper_world_observation.ml','lib/server_keeper_waiting_inventory.ml']
for variant in ['baseline','candidate']:
 dest=out/variant;dest.mkdir()
 def source(rel):return (wd/rel).read_text() if variant=='candidate' else subprocess.check_output(['git','show',base+':'+rel],cwd=root,text=True)
 def run(args):
  p=subprocess.run(args,cwd=dest,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
  if p.returncode:
   (dest/'failure.txt').write_text(p.stdout);raise RuntimeError(p.stdout[-3500:])
  return p.stdout
 args=cmd+['-I',str(dest)]+[v for d in incs for v in ['-I',d]]+[v for p in objects for v in ['-I',str(p.parent)]]
 for ext in ['mli','ml']:
  path=dest/('masc__Schedule_payload_projection.'+ext);path.write_text(source('lib/schedule_payload_projection.'+ext))
  run(args+['-open','Masc','-c',str(path)])
 world=source('lib/keeper/keeper_world_observation.ml');world=world[world.index('let schedule_visible_to_keeper'):world.index('let read_scheduled_automation_observation')]
 (dest/'world.ml').write_text('open Masc\n'+world);run(args+['-c','world.ml'])
 inv=source('lib/server_keeper_waiting_inventory.ml');prefix=inv[:inv.index('let source_to_string')]
 scope=inv[inv.index('let scope_includes_actor'):inv.index('let pending_confirm_rows')]
 rows=inv[inv.index('let schedule_active'):inv.index('let schedule_rows_or_error')]
 (dest/'inventory.ml').write_text('open Masc\n'+prefix+scope+rows);run(args+['-c','inventory.ml'])
 (dest/'probe.ml').write_text(probe)
 stubs=list((root/'_build/default/lib').glob('**/lib*stubs.a'))
 run(args+['-linkpkg']+list(map(str,objects))+['masc__Schedule_payload_projection.cmx','world.cmx','inventory.cmx','probe.ml','-o','probe.exe']+[v for p in stubs for v in ['-cclib',str(p)]])
 report=run([str(dest/'probe.exe')]);(dest/'execution.txt').write_text(report)
 results[variant]=json.loads((dest/'results.json').read_text());print(variant,report.strip(),flush=True)
assert results['candidate']['passed']==results['candidate']['total']
assert results['baseline']['passed']<results['baseline']['total']
(out/'summary.json').write_text(json.dumps(results,indent=2)+'\n')
(out/'manifest.json').write_text(json.dumps({'baseline':base,'scope':'full native Schedule_payload_projection and exact source-sliced world visibility and inventory schedule projection with cached real Schedule_domain dependencies; no storage/HTTP/PTY run','source_sha256':{p:hashlib.sha256((wd/p).read_bytes()).hexdigest() for p in files}},indent=2)+'\n')
print(out)
