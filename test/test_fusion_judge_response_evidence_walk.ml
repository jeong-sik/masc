open Alcotest
open Masc

(* The external response producer is a local Python process that implements
   only the Claude auth/turn fixture protocol. The real MASC official adapter,
   Claude protocol owner, judge parser, private writer and seat walk execute. *)
let cli_source = {|#!/usr/bin/env python3
import json,sys
from pathlib import Path
root=Path(__file__).parent
def send(value):print(json.dumps(value),flush=True)
if 'auth' in sys.argv:
 send({'loggedIn':True,'authMethod':'claude.ai','apiProvider':'firstParty'});sys.exit(0)
def arg(flag):
 for index,value in enumerate(sys.argv):
  if value.startswith(flag+'='):return value.split('=',1)[1]
  if value==flag:return sys.argv[index+1]
 raise AssertionError((flag,sys.argv))
sid=arg('--session-id');model=arg('--model')
initialize=json.loads(sys.stdin.readline())
send({'type':'control_response','response':{'subtype':'success','request_id':initialize['request_id'],'response':{}}})
user=json.loads(sys.stdin.readline());assert user['message']['role']=='user'
with (root/'observed-turns.jsonl').open('a')as capture:capture.write(json.dumps({'model':model,'cwd':str(Path.cwd()),'user':user})+'\n')
if model=='claude-opus-5-5':text='~private-syntax-output~';usage={'input_tokens':11,'output_tokens':7}
elif model=='claude-sonnet-5':text='```json\n{"~private-schema-key~":true}\n```';usage={'input_tokens':13,'output_tokens':9}
elif model=='claude-haiku-4-5':text='{"resolved_answer":"retained final answer","decision":{"kind":"answer","answer":"yes"}}';usage={'input_tokens':17,'output_tokens':5}
else:raise AssertionError(model)
send({'type':'assistant','parent_tool_use_id':None,'session_id':sid,'uuid':'assistant-'+model,'message':{'role':'assistant','model':model,'content':[{'type':'text','text':text}]}})
send({'type':'result','subtype':'success','is_error':False,'session_id':sid,'uuid':'result-'+model,'result':text,'api_error_status':None,'usage':usage})
for _ in sys.stdin:pass
|}

let runtime_fixture cli = Printf.sprintf {|[runtime]
default="claude_code.claude-opus-5-5"
[providers.claude_code]
display-name="Isolated Claude protocol fixture"
protocol="claude-code"
command="%s"
is-non-interactive=true
[models."claude-opus-5-5"]
api-name="claude-opus-5-5"
max-context=200000
tools-support=true
streaming=true
turn-timeout-s=0
[claude_code."claude-opus-5-5"]
[models."claude-sonnet-5"]
api-name="claude-sonnet-5"
max-context=200000
tools-support=true
streaming=true
turn-timeout-s=0
[claude_code."claude-sonnet-5"]
[models."claude-haiku-4-5"]
api-name="claude-haiku-4-5"
max-context=200000
tools-support=true
streaming=true
turn-timeout-s=0
[claude_code."claude-haiku-4-5"]
[runtime.lanes.evidence-judge]
candidates=["claude_code.claude-opus-5-5","claude_code.claude-sonnet-5","claude_code.claude-haiku-4-5"]
|} cli

let write_file ~perm path contents =
 let channel = open_out_gen [Open_creat; Open_trunc; Open_wronly] perm path in
 Fun.protect ~finally:(fun () -> close_out channel)
  (fun () -> output_string channel contents)

let with_workspace f =
 let work = Filename.temp_file "fusion-judge-evidence-walk-" "" in
 Sys.remove work;
 Unix.mkdir work 0o700;
 Fun.protect ~finally:(fun () -> Fs_compat.remove_tree work) (fun () ->
  Masc_test_deps.with_process_env "MASC_BASE_PATH" (Some work) (fun () ->
   let cli = Filename.concat work "fixture-claude" in
   write_file ~perm:0o700 cli cli_source;
   write_file ~perm:0o600 (Filename.concat work "runtime.toml") (runtime_fixture cli);
   f work))

let field key json = Yojson.Safe.Util.member key json
let strings key rows = List.map(fun row->field key row |>Yojson.Safe.Util.to_string)rows
let scenario () = with_workspace (fun work ->
 Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
 Prompt_defaults.init ();
 (match Runtime.init_default ~config_path:(Filename.concat work "runtime.toml") with Ok ()->()|Error detail->fail detail);
 let seen = ref None in
 let result = Eio_main.run(fun env->
  Eio_context.set_env env;
  Eio.Switch.run(fun sw-> Eio_context.with_test_env ~net:(Eio.Stdenv.net env)
   ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw(fun()->
    Fusion_judge.run ~base_dir:work ~sw ~net:(Eio.Stdenv.net env)
     ~judge_system_prompt:"Return the exact synthesis" ~judge_model:"evidence-judge"
     ~question:"preserve prior candidate failures" ~panel:[] ~web_tools:false
     ~seat_route:(Fusion_types.Single,(fun route->seen:=Some route)) ()))) in
 (match result with
 |Ok(answer,usage)->
  check string "third candidate answers" "retained final answer" answer.resolved_answer;
  check int "failed and successful input usage summed" 41 usage.input_tokens;
  check int "failed and successful output usage summed" 21 usage.output_tokens
 |Error _->fail "actual judge did not complete the controlled three-candidate walk");
 let observed=Fs_compat.load_file(Filename.concat work "observed-turns.jsonl")
  |>String.split_on_char '\n' |>List.filter(fun row->String.trim row<>"") |>List.map Yojson.Safe.from_string in
 check(list string)"actual controlled CLI turn order"
  ["claude-opus-5-5";"claude-sonnet-5";"claude-haiku-4-5"](strings "model" observed);
 List.iter(fun row->check string "actual subprocess cwd" (Unix.realpath work)(Unix.realpath(field "cwd"row|>Yojson.Safe.Util.to_string)))observed;
 let route=match !seen with Some row->row|None->fail "actual seat route missing" in
 check(option string)"actual final answer identity"(Some "claude_code.claude-haiku-4-5")route.answered_by;
 check int "both previous actual failures remain"2(List.length route.failed_attempts);
 let directory=Structured_response_evidence.record_path ~base_path:work
  (Structured_response_evidence.invocation_id())|>Filename.dirname in
 let records=Sys.readdir directory |>Array.to_list |>List.filter(fun file->Filename.check_suffix file ".jsonl")
  |>List.map(fun file-> let path=Filename.concat directory file in
   check int "private 0600 evidence"0o600((Unix.stat path).st_perm land 0o777);
   Yojson.Safe.from_string(Fs_compat.load_file path))
  |>List.sort(fun a b->Int.compare(Yojson.Safe.Util.to_int(field "attempt_index"a))(Yojson.Safe.Util.to_int(field "attempt_index"b)))in
 check int "only two actual parse failures create evidence"2(List.length records);
 check(list int)"exact actual ordinals"[0;1](List.map(fun row->field "attempt_index"row|>Yojson.Safe.Util.to_int)records);
 check(list string)"actual failed runtime identities"["claude_code.claude-opus-5-5";"claude_code.claude-sonnet-5"](strings "runtime_id" records);
 check(list string)"exact original received response before fence removal"
  ["~private-syntax-output~";"```json\n{\"~private-schema-key~\":true}\n```"](strings "raw_preview"records);
 check(list string)"one original judge invocation"
  [List.hd(strings "invocation_id"records)](List.sort_uniq String.compare(strings "invocation_id"records));
 List.iter2(fun (failed:Fusion_types.seat_attempt) row ->
  check string "failure attribution matches original runtime"failed.attempt_runtime(field "runtime_id"row|>Yojson.Safe.Util.to_string);
  match failed.attempt_failure with
  |Fusion_types.Judge_attempt_failed(Parse_error detail)->
   check bool "original failure references exact private record"true
    (String_util.contains_substring detail(field "evidence_id"row|>Yojson.Safe.Util.to_string));
   check bool "seat failure never exposes response bytes"false(String.contains detail '~')
  |Panel_attempt_failed _
  |Judge_attempt_failed(Timeout|Provider_error _|Empty_response _|Empty_result|Build_error _|Panels_unavailable _|Unknown_route _|Route_unavailable _|Internal_error _)->fail "actual parser failure was reclassified")route.failed_attempts records)
let ()=run "actual Fusion judge evidence"["controlled official candidate walk",[test_case "two failures survive third success" `Quick scenario]]
