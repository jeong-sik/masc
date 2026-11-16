#!/usr/bin/env python3
"""Source-extracted body recheck probe; transport/owned-store checks are excluded."""
from pathlib import Path
import argparse, hashlib, json, os, subprocess

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-root',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
SOURCE=args.source_root.resolve()
OUT=args.output.resolve()
OUT.mkdir(parents=True,exist_ok=True)
owner = (SOURCE/'lib/lane_addon/lane_addon_tool_request_owner.ml').read_text()
def section(start, end):
    return owner[owner.index(start):owner.index(end, owner.index(start))]
canonical = (SOURCE/'lib/lane_addon/lane_addon_json.ml').read_text()
prefix = '''open Result.Syntax
module Domain_pool_ref = struct let submit_cpu_or_inline ~name:_ f = f () end
module String_util = struct let is_lowercase_sha256_hex s = String.length s=64 &&
  String.for_all (function '0'..'9'|'a'..'f' -> true | _ -> false) s end
module Lane_addon_request_progress = struct
  type t = Yojson.Safe.t
  let of_json x = Ok x
  let to_json x = x
end
module Lane_addon_action = struct
'''+canonical+'''end
module Lane_addon_store = struct
  type t = {record:string;body:string}
  let digest bytes = Agent_core_sha256.(to_hex (digest_string bytes))
  let load_tool_request store ~scope:_ ~request_id:_ ~name_body =
    if not (Sys.file_exists store.record) then Ok None else
    let json=Yojson.Safe.from_string (In_channel.with_open_bin store.record In_channel.input_all) in
    let* record,_=name_body json in
    let body=if Sys.file_exists store.body then
      Some (In_channel.with_open_bin store.body In_channel.input_all) else None in
    Ok (Some (record,body))
end
type error = Binding_conflict | Store_unavailable of string | Invalid_identity of string
  | Invalid_request of string
'''
parts = [section('module Record = struct', 'let discover ~store'),
         section('type verified_body =', 'let load_record ~store')]
code = prefix + parts[0] + '\nlet unavailable result = Result.map_error (fun x -> Store_unavailable x) result\n' + parts[1]
harness = r'''
let must = function Ok x -> x | Error _ -> failwith "unexpected refusal"
let checks=ref 0
let check name expected actual = incr checks; if expected<>actual then failwith name
let write p s=Out_channel.with_open_bin p (fun f -> output_string f s)
let measure f =
  Gc.full_major (); let a=Gc.allocated_bytes () and cpu=Sys.time () and wall=Unix.gettimeofday () in
  let result=f () in
  let cpu=Sys.time ()-.cpu and wall=Unix.gettimeofday ()-.wall and allocated=Gc.allocated_bytes ()-.a in
  ignore (Sys.opaque_identity result); cpu,wall,allocated
let () =
  let root=Filename.temp_dir "verified-body-probe" "" in
  Fun.protect ~finally:(fun () -> Array.iter (fun n -> Sys.remove (Filename.concat root n)) (Sys.readdir root);Unix.rmdir root)
    (fun () ->
    let store:Lane_addon_store.t={record=Filename.concat root "record";body=Filename.concat root "body"} in
    let raw=`Assoc ["history",`String (String.make 30_731_000 'a');"prompt",`String (String.make 30_731_000 'b')] in
    let request=must (Lane_addon_action.canonical raw) in
    let bytes=Yojson.Safe.to_string request in
    let digest=Lane_addon_store.digest bytes in
    let original:retained={scope="fixture";request_id="original";installation_id="configuration";
      package_id="history";tool="judge";request_digest=digest;summary=`Null;request;progress=`List []} in
    let record=Yojson.Safe.to_string (to_json original) in
    write store.record record;write store.body bytes;
    let verified=verified_body (Option.get (must (load ~store ~scope:"fixture" ~request_id:"original"))) in
    let weak,identity=(fun () ->
      let child=`List [`String (String.make 1_000_000 'c')] in
      let weak=Weak.create 1 in Weak.set weak 0 (Some child);
      weak,verified_body {original with request=child;progress=child}) () in
    Gc.full_major ();
    ignore (Sys.opaque_identity identity);
    check "proof retains neither original JSON nor progress child" false (Weak.check weak 0);
    check "unchanged body" true (Result.is_ok (recheck_body ~store verified));
    let corrupt=Bytes.of_string bytes in Bytes.set corrupt 0 '[';write store.body (Bytes.to_string corrupt);
    check "same-length corruption" true (Result.is_error (recheck_body ~store verified));
    Sys.remove store.body;
    check "missing body" true (Result.is_error (recheck_body ~store verified));
    write store.body bytes;
    write store.record (Yojson.Safe.to_string (to_json {original with summary=`Bool true}));
    check "changed immutable summary" true (Result.is_error (recheck_body ~store verified));
    write store.record (Yojson.Safe.to_string (to_json {original with request_digest=String.make 64 '0'}));
    check "changed digest" true (Result.is_error (recheck_body ~store verified));
    write store.record (Yojson.Safe.to_string (to_json {original with tool="another"}));
    check "changed binding" true (Result.is_error (recheck_body ~store verified));
    Sys.remove store.record;
    check "missing record" true (Result.is_error (recheck_body ~store verified));
    write store.record (Yojson.Safe.to_string (to_json {original with progress=`List [`String "advanced"]}));
    let advanced=must (recheck_body ~store verified) in
    check "fresh progress" true (Record.progress advanced=`List [`String "advanced"]);
    write store.record record;
    let before=measure (fun () -> must (load ~store ~scope:"fixture" ~request_id:"original")) in
    let after=measure (fun () -> must (recheck_body ~store verified)) in
    let result (cpu,wall,allocated)=`Assoc ["cpu_s",`Float cpu;"wall_s",`Float wall;"allocated_bytes",`Float allocated] in
    print_endline (Yojson.Safe.to_string (`Assoc ["checks",`Int !checks;"body_bytes",`Int (String.length bytes);
      "before",result before;"after",result after])))
'''
(OUT/'probe.ml').write_text(code+harness)
for name in ('agent_core_digest_slices.ml', 'agent_core_sha256.ml'):
    (OUT/name).write_bytes((SOURCE/'packages/agent_core/lib/digest'/name).read_bytes())
env=dict(os.environ)
cmd=['ocamlfind','ocamlopt','-linkpkg','-package','yojson,digestif.c,unix','-w','+4+8','-warn-error','+4+8',
     'agent_core_digest_slices.ml','agent_core_sha256.ml','probe.ml','-o','probe']
p=subprocess.run(cmd,cwd=OUT,env=env,capture_output=True,text=True)
(OUT/'compile.stderr').write_text(p.stderr)
if p.returncode:
    print(p.stderr);raise SystemExit(p.returncode)
p=subprocess.run([str(OUT/'probe')],cwd=OUT,capture_output=True,text=True)
(OUT/'run.stderr').write_text(p.stderr)
if p.returncode:
    print(p.stderr);raise SystemExit(p.returncode)
result=json.loads(p.stdout);result['source_sha256']=hashlib.sha256(owner.encode()).hexdigest()
result['limits']=['Store read and progress decoder are fixture ports; owned descriptor/sync/serializer checks are not exercised.',
                  'Source-extracted owner load/recheck only; nested History restoration, full lineage, provider, process RSS and TUI are not measured.']
(OUT/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
