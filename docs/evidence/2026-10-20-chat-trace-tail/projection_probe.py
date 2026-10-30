"""Exercise both actual projection modules with in-memory dependencies, not the server.

Requires git, ocaml, ocamlfind and yojson; does not invoke Dune.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--before', required=True, help='Baseline commit containing the projection module')
parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[3])
args = parser.parse_args()
root = args.repo
before=subprocess.check_output(['git','show',args.before + ':lib/server/server_dashboard_http_keeper_api_trace.ml'],cwd=root,text=True)
after=(root/'lib/server/server_dashboard_http_keeper_api_trace.ml').read_text()
stubs=r'''
module Set_util = struct module StringSet = Set.Make(String) end
module Json_util = struct
 let dedupe_keep_order rows = let seen=Hashtbl.create 8 in List.filter (fun row -> if Hashtbl.mem seen row then false else (Hashtbl.add seen row ();true)) rows
end
module Workspace = struct type config=string let masc_dir value=value end
module Ids = struct
 module Execution_id = struct type t=string let of_string value=value end
 module Turn_ref = struct
  type t={trace:string;turn:int}
  let trace_id value=value.trace let absolute_turn value=value.turn
  let to_string value=value.trace ^ "#" ^ string_of_int value.turn
 end
end
module Trajectory = struct
 type withheld_reasoning_kind = Thinking_block | Reasoning_details | Redacted_thinking
 type withheld_thinking_entry={turn:int;block_index:int;reasoning_kind:withheld_reasoning_kind;ts_iso:string}
 type tool_call_entry={turn:int;tool_name:string;args_json:string;result:string option;duration_ms:int;error:string option;execution_id:string option;ts_iso:string}
 type trajectory_line=Tool_call of tool_call_entry | Withheld_thinking of withheld_thinking_entry
 let sources : (string,trajectory_line list) Hashtbl.t=Hashtbl.create 8
 let read_recent_lines ~masc_root:_ ~keeper_name:_ ~trace_id ~max_lines =
  let rows=Option.value ~default:[] (Hashtbl.find_opt sources trace_id) in List.drop (max 0 (List.length rows-max_lines)) rows
end
module Keeper_chat_blocks = struct
 type trace_tool_status=Trace_tool_pending|Trace_tool_ok|Trace_tool_err
 type trace_step =
 | Trace_think of {text:string;content_withheld:bool;ts:string option;agent_core_block_index:int option}
 | Trace_tool of {name:string;tool_call_id:string option;execution_id:Ids.Execution_id.t option;status:trace_tool_status option;dur:string option;args:Yojson.Safe.t option;result:Yojson.Safe.t option;ts:string option;agent_core_block_index:int option}
 type chat_block=Trace of {trace:trace_step list;omitted:int}
end
'''
checks=r'''
let turn trace number : Ids.Turn_ref.t={trace;turn=number}
let tool index turn payload = Trajectory.Tool_call {
 turn; tool_name="tool"^string_of_int index; args_json=payload;
 result=Some(if index mod 7=0 then "literal result" else payload); duration_ms=index;
 error=(if index mod 11=0 then Some "error" else None);
 execution_id=Some("execution-"^string_of_int index);ts_iso=string_of_int index}
let make factory = factory ~max_lines:500 ~config:"fixture" ~keeper_name:"keeper" ~allowed_trace_ids:["a";"b";"a"]
let () =
 Random.init 71;
 for case=1 to 400 do
  let rows=List.init (Random.int 700) (fun index ->
   if index mod 3=0 then Trajectory.Withheld_thinking {
    turn=Random.int 4;block_index=index mod 5;reasoning_kind=Trajectory.Thinking_block;ts_iso=string_of_int index}
   else tool index (Random.int 4) (if index mod 5=0 then "literal args" else "{\"unicode\":\"한글\",\"value\":[1,2]}")) in
  Hashtbl.replace Trajectory.sources "a" rows;
  Hashtbl.replace Trajectory.sources "b" (List.rev rows);
  let old=make Old.chat_trace_block_by_turn_ref and fresh=make New.chat_trace_block_by_turn_ref in
  List.iter (fun trace -> for index=0 to 5 do
   let ref=turn trace index in assert(old ref=fresh ref);assert(old ref=fresh ref)
  done) ["a";"b";"disallowed"];
  Hashtbl.replace Trajectory.sources "a" [tool case 5 "{}"];
  assert(old (turn "a" 5)=fresh (turn "a" 5))
 done;
 Printf.printf "equivalence_cases=400\n%!"
let payload=Yojson.Safe.to_string (`Assoc ["text",`String(String.make 8192 'x')])
let rows=List.init 453 (fun index -> tool index 1 payload)
let ()=Hashtbl.replace Trajectory.sources "a" rows
let bench label factory repeats =
 Gc.full_major ();let resolver=make factory in
 let before=Gc.allocated_bytes () and started=Unix.gettimeofday () in
 for _=1 to repeats do ignore(Sys.opaque_identity(resolver (turn "a" 1))) done;
 Printf.printf "%s repeats=%d elapsed_ms=%.3f allocated_bytes=%.0f\n%!" label repeats ((Unix.gettimeofday()-.started)*.1000.) (Gc.allocated_bytes()-.before)
let ()=bench "before-cold" Old.chat_trace_block_by_turn_ref 1;bench "after-cold" New.chat_trace_block_by_turn_ref 1;bench "before-repeated" Old.chat_trace_block_by_turn_ref 10;bench "after-repeated" New.chat_trace_block_by_turn_ref 10
'''
source=stubs+'\nmodule Old = struct\n'+before+'\nend\nmodule New = struct\n'+after+'\nend\n'+checks
yojson=subprocess.check_output(['ocamlfind','query','yojson'],text=True).strip()
with tempfile.TemporaryDirectory(prefix='masc-trace-probe-') as directory:
    path = Path(directory) / 'projection.ml'
    path.write_text(source)
    r = subprocess.run(['ocaml', '-noinit', '-I', '+unix', '-I', yojson, 'yojson.cma', 'unix.cma', str(path)], text=True, capture_output=True)
print(r.stdout+r.stderr)
raise SystemExit(r.returncode)
