#!/usr/bin/env python3
"""Replay source-extracted preflight index reuse with synthetic History ports."""
from pathlib import Path
import argparse, hashlib, json, os, subprocess
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source-root',required=True,type=Path)
p.add_argument('--output',required=True,type=Path)
a=p.parse_args(); root=a.source_root.resolve(); out=a.output.resolve(); out.mkdir(parents=True,exist_ok=True)
owner=(root/'lib/lane_addon/lane_addon_tool_request_owner.ml').read_text()
lineage=(root/'lib/keeper/keeper_librarian_history_resolution_lineage.ml').read_text()
preflight=(root/'lib/keeper/keeper_librarian_store_preflight.ml').read_text()
def part(text,start,end):
    i=text.index(start);return text[i:text.index(end,i)]
code=r'''open Result.Syntax
module Domain_pool_ref=struct let submit_cpu_or_inline ~name:_ f=f () end
module String_util=struct let is_lowercase_sha256_hex s=String.length s=64 &&
 String.for_all (function '0'..'9'|'a'..'f'->true|_->false) s end
module Lane_addon_request_progress=struct type t=Yojson.Safe.t let of_json x=Ok x let to_json x=x end
module Lane_addon_action=struct
'''+(root/'lib/lane_addon/lane_addon_json.ml').read_text()+r'''
end
module Lane_addon_store=struct
 type t=unit
 let digest bytes=Agent_core_sha256.(to_hex (digest_string bytes))
 let load_tool_request () ~scope:_ ~request_id:_ ~name_body:(_ : Yojson.Safe.t -> ('a * string,string) result) : (('a * string option) option,string) result=Ok None
end
module Owner=struct
type error=Binding_conflict|Store_unavailable of string|Invalid_identity of string|Invalid_request of string
'''+part(owner,'module Record = struct','let discover ~store')+part(owner,'let decode_published','type observation_issue')+part(owner,'module Published_reader = struct','let unavailable')+r'''
end
let field k j=Yojson.Safe.Util.member k j
let text k j=Yojson.Safe.Util.to_string (field k j)
let require ok msg=if ok then Ok () else Error msg
module Request=struct
 type owner={scope:string;epoch:int}
 type predecessor={request_id:string;request_digest:string}
 type index={owner:owner;destination:string;predecessor:predecessor option;source_basis_digest:string}
 type t={id:string;digest:string;index:index;materialized:string}
 let restores=ref 0 and confirmations=ref 0
 let scope (owner:owner)=owner.scope
 let owner_json (owner:owner)=`Assoc ["scope",`String owner.scope;"epoch",`Int owner.epoch]
 let owner_of_json j={scope=text "scope" j;epoch=Yojson.Safe.Util.to_int (field "epoch" j)}
 let pred_json=function None->`Null|Some (p:predecessor)->`Assoc ["id",`String p.request_id;"digest",`String p.request_digest]
 let pred_of_json=function `Null->None|j->Some {request_id=text "id" j;request_digest=text "digest" j}
 let index_json (i:index)=`Assoc ["owner",owner_json i.owner;"destination",`String i.destination;
   "predecessor",pred_json i.predecessor;"basis",`String i.source_basis_digest]
 let index_json_read j={owner=owner_of_json (field "owner" j);destination=text "destination" j;
   predecessor=pred_of_json (field "predecessor" j);source_basis_digest=text "basis" j}
 let index_of_summary (r:Owner.Record.t)=
   try let i=index_json_read r.summary in
     let+ ()=require (r.scope=i.owner.scope && r.installation_id=i.destination && r.package_id="fixture" && r.tool="judge") "index binding" in i
   with Yojson.Safe.Util.Type_error _->Error "index shape"
 let restore_payload ~owner (r:Owner.retained)=
   incr restores;
   let j=r.request in
   let i=index_json_read (field "index" j) in
   let* ()=require (owner=i.owner && r.scope=owner.scope && r.request_id=text "id" j
     && r.installation_id=i.destination && r.package_id="fixture" && r.tool="judge") "restore binding" in
   let materialized=Yojson.Safe.to_string (Yojson.Safe.from_string (text "source_text" j)) in
   Ok {id=r.request_id;digest=r.request_digest;index=i;materialized}
 let confirm_index (r:t) (record:Owner.Record.t)=
   incr confirmations;let* index=index_of_summary record in require (index=r.index) "index differs"
 let request_id (r:t)=r.id
 let body_digest (r:t)=r.digest
 let physical_owner (r:t)=r.index.owner
 let predecessor (r:t)=r.index.predecessor
 let source_basis_digest (r:t)=Ok r.index.source_basis_digest
 let validate_predecessor_link_payload ~read ~require_confirmed:_ (r:t)=
   match r.index.predecessor with None->Ok ()|Some predecessor->
   let* current=read ~scope:r.index.owner.scope ~request_id:predecessor.request_id in
   match current with Some parent when parent.Owner.progress=`String r.id->Ok ()|_->Error "known basis publication"
end
module Fence=struct
 type t={expected:string;actor:string;reason:string}
 let of_json j=Ok {expected=text "expected" j;actor=text "actor" j;reason=text "reason" j}
 let confirm_binding_index ~index:_ ~original:_ (_:t)=Ok ()
end
module Intent=struct
 type child={request_id:string;request_digest:string}
 type phase=Child_confirmed of child|Child_intended of child|Requested|Refused of string|Fenced
 type t={expected:string;actor:string;reason:string;phase:phase}
 let decode_published ~scope:_ ~request_id:_ j=
   let c={request_id=text "id" j;request_digest=text "digest" j} in
   Ok [{expected=text "expected" j;actor=text "actor" j;reason=text "reason" j;
     phase=(if field "confirmed" j=`Bool true then Child_confirmed c else Child_intended c)}]
 let child i=match i.phase with Child_confirmed c|Child_intended c->Some c|Requested|Refused _|Fenced->None
end
module Lineage=struct
'''+part(lineage,'type node =','(* A fenced original')+part(lineage,'let validate_node','let store_readers')+r'''
end
'''+part(preflight,'let per_scope fresh =','(* The forest')+r'''
let checks=ref 0
let must=function Ok x->x|Error e->failwith e
let check label expected actual=incr checks;if expected<>actual then failwith label
let owner:Request.owner={scope="fixture-scope";epoch=7}
let canonical j=must (Lane_addon_action.canonical j)
let make ?predecessor ?(payload=String.make 200_000 'x') id=
 let index:Request.index={owner;destination="configuration";predecessor;source_basis_digest="basis"} in
 let request=canonical (`Assoc ["id",`String id;"index",Request.index_json index;
   "source_text",`String (Yojson.Safe.to_string (`Assoc ["input",`String payload]))]) in
 let bytes=Yojson.Safe.to_string request in
 let r:Owner.retained={scope=owner.scope;request_id=id;installation_id="configuration";
 package_id="fixture";tool="judge";request_digest=Lane_addon_store.digest bytes;
 summary=canonical (Request.index_json index);request;progress=`Null} in r,bytes
let ()=
 let records=Hashtbl.create 32 and bodies=Hashtbl.create 32 and body_reads=ref 0 in
 let reader=Owner.Published_reader.create ~read_body:(fun ~scope:_ ~request_digest->incr body_reads;Ok (Hashtbl.find_opt bodies request_digest)) in
 let read ~scope ~request_id=match Hashtbl.find_opt records request_id with None->Ok None|Some json->
   Result.map Option.some (Owner.Published_reader.read reader ~directory_name:(Lane_addon_store.digest scope)
    ~file_name:(Lane_addon_store.digest request_id^".json") json) in
 let rows=Array.init 32 (fun i->let predecessor=if i=0 then None else
   let previous=must (read ~scope:owner.scope ~request_id:(string_of_int (i-1))) |> Option.get in
   Some {Request.request_id=previous.request_id;request_digest=previous.request_digest} in
   let r,b=make ?predecessor (string_of_int i) in
   Hashtbl.add records r.request_id (Owner.to_json r);Hashtbl.add bodies r.request_digest b;r) in
 let fence_reads=ref 0 and resolution_reads=ref 0 and confirmed=ref true and corrupt_intent=ref false and fenced=ref true in
 let read_fence ~scope:_ ~request_id:_=incr fence_reads;if not !fenced then Ok None else
   Ok (Some (`Assoc ["expected",`String "observed";"actor",`String "operator";"reason",`String "retry"])) in
 let read_resolution ~scope:_ ~request_id=incr resolution_reads;
   let child=rows.(int_of_string request_id+1) in
   Ok (Some (`Assoc ["id",`String child.request_id;"digest",`String (if !corrupt_intent then "wrong" else child.request_digest);
    "expected",`String "observed";"actor",`String "operator";"reason",`String "retry";"confirmed",`Bool !confirmed])) in
 let walk ?indexes row=let request=must (Request.restore_payload ~owner row) in
   Lineage.validate_predecessor_payload ?indexes ~read ~read_fence ~read_resolution ~require_confirmed:true request in
 let run ?indexes ()=Array.iter (fun r->must (walk ?indexes r)) rows in
 Request.restores:=0;run ();let before= !Request.restores in
 Request.restores:=0;let indexes=Lineage.payload_indexes () in run ~indexes ();let after= !Request.restores in
 check "32node chain baseline restores" 528 before;check "32node chain index reuse restores" 63 after;
 let last=rows.(31) in
 let compare label=check label (walk last) (walk ~indexes last) in
 compare "unchanged walk";
 confirmed:=false;compare "fresh child ACK";check "unacknowledged refuses" true (Result.is_error (walk ~indexes last));confirmed:=true;
 corrupt_intent:=true;compare "fresh intended digest";check "changed digest refuses" true (Result.is_error (walk ~indexes last));corrupt_intent:=false;
 let parent=rows.(30) in
 let body=Hashtbl.find bodies parent.request_digest in
 Hashtbl.remove bodies parent.request_digest;compare "missing actual bytes";
 check "missing body refuses" true (Result.is_error (walk ~indexes last));Hashtbl.add bodies parent.request_digest body;
 let corrupt=Bytes.of_string body in Bytes.set corrupt 0 '[';Hashtbl.replace bodies parent.request_digest (Bytes.to_string corrupt);
 compare "same length body corruption";check "corruption refuses" true (Result.is_error (walk ~indexes last));Hashtbl.replace bodies parent.request_digest body;
 let honest=Hashtbl.find records parent.request_id in
 let modify name value=match honest with `Assoc fs->`Assoc (List.map (fun (k,v)->k,if k=name then value else v) fs)|_->assert false in
 Hashtbl.replace records parent.request_id (modify "tool" (`String "other"));compare "changed host binding";
 check "binding refuses" true (Result.is_error (walk ~indexes last));Hashtbl.replace records parent.request_id honest;
 Hashtbl.replace records parent.request_id (modify "summary" (`Assoc []));compare "changed summary";
 check "summary refuses" true (Result.is_error (walk ~indexes last));Hashtbl.replace records parent.request_id honest;
 compare "restored proof inputs";
 let altered={owner with epoch=8} in
 check "same scope different fullowner refuses" true (Result.is_error
  (Lineage.payload_node ~indexes ~read ~owner:altered ~request_id:parent.request_id));
 let before= !Request.restores in
 ignore (must (Lineage.payload_node ~indexes ~read ~owner ~request_id:parent.request_id));
 check "failed restore not cached" true (!Request.restores>before);
 fenced:=false;compare "known basis checks fresh progress";check "bad knownbasis publication refuses" true (Result.is_error (walk ~indexes last));
 let first=rows.(0) in
 let original_first=Hashtbl.find records first.request_id in
 let advanced=match original_first with `Assoc fs->`Assoc (List.map (fun (k,v)->k,if k="progress" then `String "1" else v) fs)|_->assert false in
 Hashtbl.replace records first.request_id advanced;
 check "current progress is used on a cached knownbasis node" (Ok ()) (walk ~indexes rows.(1));
 Hashtbl.replace records first.request_id original_first;
 check "later progress changes remain visible" true (Result.is_error (walk ~indexes rows.(1)));fenced:=true;
 let same_node=must (Lineage.payload_node ~indexes ~read ~owner ~request_id:parent.request_id) |> Option.get in
 let before= !Request.restores in ignore (must (same_node.body ()));
 check "full body remains restorable for knownbasis" true (!Request.restores>before);
 let rebound_indexes=Lineage.payload_indexes () in
 let original,_=make ~payload:"small" "actual-id" in
 let rebound_read r ~scope:_ ~request_id:_=Ok (Some r) in
 ignore (must (Lineage.payload_node ~indexes:rebound_indexes ~read:(rebound_read original) ~owner ~request_id:"lookup-id"));
 let rebound={original with Owner.request_id="lookup-id"} in
 check "wrong-key read cannot lend a body proof to rebound metadata" true (Result.is_error
  (Lineage.payload_node ~indexes:rebound_indexes ~read:(rebound_read rebound) ~owner ~request_id:"lookup-id"));
 let transient_indexes=Lineage.payload_indexes () in
 let weak=(fun ()->let r,_=make ~payload:(String.make 1_000_000 'z') "transient" in
   let weak=Weak.create 1 in Weak.set weak 0 (Some r.request);
   ignore (must (Lineage.payload_node ~indexes:transient_indexes ~read:(fun ~scope:_ ~request_id:_->Ok (Some r)) ~owner ~request_id:r.request_id));weak) () in
 Gc.full_major ();ignore (Sys.opaque_identity transient_indexes);
 check "memo retains no full request" false (Weak.check weak 0);
 let scopes=per_scope Lineage.payload_indexes in
 let first=scopes "a" in ignore (scopes "b");check "scope exit drops prior map" false (first==scopes "a");
 check "all walks still read bodies/fences/intents" true (!body_reads>496 && !fence_reads>496 && !resolution_reads>496);
 print_endline (Yojson.Safe.to_string (`Assoc ["checks",`Int !checks;"chain_nodes",`Int 32;
  "restores_without_indexes",`Int 528;"restores_with_indexes",`Int 63;
  "fresh_body_reads",`Int !body_reads;"fence_reads",`Int !fence_reads;"resolution_reads",`Int !resolution_reads]))
'''
(out/'probe.ml').write_text(code)
for name in ('agent_core_digest_slices.ml','agent_core_sha256.ml'):
 (out/name).write_bytes((root/'packages/agent_core/lib/digest'/name).read_bytes())
cmd=['ocamlfind','ocamlopt','-linkpkg','-package','yojson,digestif.c,unix','-w','+4+8','-warn-error','+4+8','agent_core_digest_slices.ml','agent_core_sha256.ml','probe.ml','-o','probe']
env=dict(os.environ)
r=subprocess.run(cmd,cwd=out,env=env,capture_output=True,text=True);(out/'compile.stderr').write_text(r.stderr)
if r.returncode:print(r.stderr);raise SystemExit(r.returncode)
r=subprocess.run([str(out/'probe')],cwd=out,capture_output=True,text=True);(out/'run.stderr').write_text(r.stderr)
if r.returncode:print(r.stderr);raise SystemExit(r.returncode)
result=json.loads(r.stdout);result['compiler_version']=subprocess.check_output(['ocamlc','-version'],env=env,text=True).strip();result['lineage_source_sha256']=hashlib.sha256(lineage.encode()).hexdigest()
result['owner_source_sha256']=hashlib.sha256(owner.encode()).hexdigest()
result['limits']=['Actual source-extracted Published_reader and lineage walk/cache; History restoration/index/fence/intent parsers and progress are synthetic fixture ports.', 'No production preflight, owned filesystem authority, provider dispatch or installed CPU/RSS result.']
(out/'results.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
