(* Actual managed verifier -> named-runtime -> Codex app-server process boundary.
   The fixture supplies model responses, never the reviewer callback. This proves
   typed verdict delivery and initial image transport, not model judgement quality. *)
open Alcotest
open Masc
module AR = Task.Anti_rationalization
module VAT = Verification_authority_tools

let write path body = Out_channel.with_open_bin path (fun out -> output_string out body)
let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

let fixture_script root ~mode =
  let capture = Filename.concat root (mode ^ "-requests.jsonl") in
  let path = Filename.concat root (mode ^ "-codex") in
  write path (Printf.sprintf {|#!/usr/bin/env python3
import json, sys
if '--masc-warmup' in sys.argv:
    sys.exit(0)
capture = %S
mode = %S
pending = []
def emit(value):
    print(json.dumps(value), flush=True)
def finish():
    item = {'type':'agentMessage','id':'final','text':'APPROVE (free text is not a verdict)','phase':'final_answer'}
    emit({'method':'item/completed','params':{'threadId':'thread-1','turnId':'turn-1','completedAtMs':1,'item':item}})
    emit({'method':'turn/completed','params':{'threadId':'thread-1','turn':{'id':'turn-1','items':[item],'status':'completed'}}})
def advance():
    if pending:
        name, args, index = pending.pop(0)
        emit({'id':'call-'+str(index),'method':'item/tool/call','params':{'threadId':'thread-1','turnId':'turn-1','callId':'call-'+str(index),'tool':name,'namespace':None,'arguments':args}})
    else:
        finish()
for line in sys.stdin:
    request = json.loads(line)
    with open(capture, 'a') as out:
        out.write(json.dumps(request)+'\n')
    method = request.get('method')
    ident = request.get('id')
    if method == 'initialize':
        emit({'id':ident,'result':{'userAgent':'fixture/0.147.0','codexHome':'/tmp/codex','platformFamily':'unix','platformOs':'linux'}})
    elif method == 'account/read':
        emit({'id':ident,'result':{'account':{'type':'chatgpt','email':'fixture@example.test','planType':'pro'},'requiresOpenaiAuth':True}})
    elif method == 'thread/start':
        emit({'id':ident,'result':{'thread':{'id':'thread-1'},'model':'verifier-fixture'}})
    elif method == 'turn/start':
        emit({'id':ident,'result':{'turn':{'id':'turn-1'}}})
        pending = [('tool_read_file',{'file_path':'proof.txt'},0)]
        if mode != 'missing':
            pending.append(('report_review_verdict',{'verdict':'APPROVE','reason':'read-only fixture receipt'},1))
        if mode == 'duplicate':
            pending.append(('report_review_verdict',{'verdict':'REJECT','reason':'second verdict must invalidate review'},2))
        advance()
    elif method is None and isinstance(ident,str) and ident.startswith('call-'):
        advance()
|} capture mode);
  Unix.chmod path 0o700;
  path, capture

let runtime_config command = Printf.sprintf {|
[providers.official]
protocol = "codex-app-server"
command = %S
is-non-interactive = true
[models.verifier]
api-name = "verifier-fixture"
max-context = 400000
tools-support = true
[models.verifier.capabilities]
supports-image-input = true
[official.verifier]
[runtime]
default = "official.verifier"
[runtime.exact_output_lanes.verifier_exact]
slots = []
cli_slots = ["official.verifier"]
|} command

let records path = In_channel.with_open_bin path In_channel.input_lines
  |> List.map Yojson.Safe.from_string
let method_request method_name rows =
  List.find (fun row -> Yojson.Safe.Util.member "method" row = `String method_name) rows
let member = Yojson.Safe.Util.member

let test_review mode =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Eio_context.set_env env;
  Eio_context.with_test_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~sw @@ fun () ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let saved = Runtime.For_testing.snapshot () in
  let root = Filename.temp_file "verifier-official-" "" in
  Unix.unlink root; Unix.mkdir root 0o700;
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore saved;
    Fs_compat.remove_tree root);
  let config = Workspace.default_config root in
  let proof_root = Filename.concat root Playground_paths.all_playgrounds_prefix in
  Fs_compat.mkdir_p proof_root;
  write (Filename.concat proof_root "proof.txt") "verified-file-receipt";
  let lookup_tools = match VAT.create_goal_proof ~config with
    | Ok tools -> tools | Error detail -> fail detail in
  let lookup = AR.Lookup_tools
    { schemas = VAT.schemas lookup_tools; dispatch = VAT.dispatch lookup_tools
    ; root_layout = ["proof.txt"] } in
  let command, capture = fixture_script root ~mode in
  let config_path = Filename.concat root "runtime.toml" in
  let runtime_text = runtime_config command in
  write config_path runtime_text;
  (match Runtime.init_default ~config_path with Ok () -> () | Error detail -> fail detail);
  if mode = "valid" then (
    let refused = Keeper_turn_driver.run_named ~runtime_id:"official.verifier"
      ~keeper_name:"arbitrary-transform-probe" ~base_path:root
      ~goal:"This request must be refused before spawn." ~system_prompt:"Explicit contract."
      ~tools:[] ~agent_core_tools:[] ~output_contract:Keeper_turn_driver.Tool_verdict
      ~provider_config_transform:(fun cfg -> Ok cfg) ~sw () in
    (match refused with
     | Error (Agent_core.Error.Config (Agent_core.Error.InvalidConfig {field="provider_config_transform"; _})) -> ()
     | Error e -> fail (Agent_core.Error.to_string e)
     | Ok _ -> fail "arbitrary provider transform was silently dropped");
    check bool "unsupported arbitrary transform never spawned client" false (Sys.file_exists capture));
  let declarations = match Runtime_toml.parse_string runtime_text with
    | Ok config -> config.Runtime_schema.exact_output_lane_decls
    | Error _ -> fail "fixture runtime declarations failed to parse" in
  let io : Agent_core.Exact_output.resolver_io = {getenv=(fun _ -> Ok None)} in
  let snapshot = match Agent_core.Exact_output.load_resolver_snapshot ~io () with
    | Ok snapshot -> snapshot | Error _ -> fail "embedded resolver snapshot unavailable" in
  (match Runtime.publish_exact_output_registry ~lanes:declarations snapshot with
   | Ok _ -> () | Error detail -> fail detail);
  (* The lane the server reads for exact_output_authority_available. This
     fixture declares a materialized official client, so readiness holds; the
     precedence suite covers the id that names nothing. *)
  (match Runtime.verifier_exact_lane_readiness () with
   | Ok () -> () | Error detail -> failf "verifier lane must be ready: %s" detail);
  let previous_slots = Atomic.get Workspace_hooks.get_verifier_exact_lane_slot_ids_fn in
  Atomic.set Workspace_hooks.get_verifier_exact_lane_slot_ids_fn Runtime.verifier_exact_lane_slot_ids;
  Eio.Switch.on_release sw (fun () ->
    Atomic.set Workspace_hooks.get_verifier_exact_lane_slot_ids_fn previous_slots);
  let calls = ref [] in
  let review () = AR.run ~sw:(Some sw)
    ~log_info:(fun _ -> ()) ~log_warn:(fun _ -> ())
    ~render_prompt:(fun () -> Ok "Verify the supplied image and read proof.txt before reporting.")
    ~goal_blocks:[Agent_core.Types.Image
      { media_type="image/png"; data=png; source_type=Base64 }]
    ~lookup ~base_path:root
    ~on_tool_result:(fun ~input:_ result -> calls := result :: !calls) () in
  let result = review () in
  (match mode, result.AR.verdict, result.gate with
   | "valid", Some (AR.Approve "read-only fixture receipt"), AR.Structured_tool -> ()
   | "missing", None, AR.Invalid_verdict -> ()
   | "duplicate", None, AR.Evaluator_unavailable -> ()
   | _ -> failf "unexpected verdict outcome: gate=%s detail=%s"
      (AR.gate_to_string result.gate) (Option.value ~default:"none" result.fallback_reason));
  let rows = records capture in
  let thread = method_request "thread/start" rows |> member "params" in
  let instructions = member "developerInstructions" thread |> Yojson.Safe.Util.to_string in
  let managed = Prompt_registry.render_prompt_template Prompt_names.verification_system [] |> Result.get_ok in
  check string "managed verifier contract reaches official client"
    (String.concat "\n\n" (managed :: Keeper_codex_runtime.For_testing.native_posture_note Runtime_native_tools.codex_default))
    instructions;
  let turn = method_request "turn/start" rows |> member "params" in
  let images = member "input" turn |> Yojson.Safe.Util.to_list
    |> List.filter (fun item -> member "type" item = `String "image") in
  check int "one actual initial image" 1 (List.length images);
  check string "exact initial image bytes" ("data:image/png;base64," ^ png)
    (List.hd images |> member "url" |> Yojson.Safe.Util.to_string);
  let read_response = List.find (fun row -> member "id" row = `String "call-0") rows in
  check bool "read-only authority result reaches model" true
    (member "success" (member "result" read_response) = `Bool true);
  check bool "real filesystem content survives tool bridge" true
    (String_util.contains_substring (Yojson.Safe.to_string read_response) "verified-file-receipt");
  check int "each tool result observed" (if mode = "missing" then 1 else if mode = "duplicate" then 3 else 2)
    (List.length !calls);
  if mode = "valid" then (
    (* A second independent review of the same workspace/runtime must start a
       new client thread, not resume the previous review's persisted session. *)
    let second = review () in
    check bool "second review has its own successful session" true
      (second.verdict = Some (AR.Approve "read-only fixture receipt"));
    let rows = records capture in
    check int "both reviews started fresh threads" 2
      (List.length (List.filter (fun row -> member "method" row = `String "thread/start") rows));
    check int "no previous review thread resumed" 0
      (List.length (List.filter (fun row -> member "method" row = `String "thread/resume") rows)))

let () =
  Prompt_registry.set_markdown_dir
    (Filename.concat (Masc_test_deps.find_project_root ()) "config/prompts");
  Workspace_metric_hooks.install ();
  Alcotest.run "official-client completion verifier"
    ["actual client dispatch", List.map (fun mode -> test_case mode `Quick (fun () -> test_review mode))
      ["valid"; "missing"; "duplicate"]]
