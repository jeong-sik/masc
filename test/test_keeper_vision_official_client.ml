(* Standalone image analysis across the real Codex process protocol. The model
   is a fixture: this proves exact image delivery and typed output handling,
   not the quality of an image interpretation. *)
open Alcotest
open Masc
module V = Keeper_vision_tool
external unsetenv : string -> unit = "masc_test_unsetenv"

let write path body = Out_channel.with_open_bin path (fun out -> output_string out body)
let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
let member = Yojson.Safe.Util.member
let query = "Describe the visible pixel."

let fixture root ~mode =
  let capture = Filename.concat root (mode ^ "-requests.jsonl") in
  let command = Filename.concat root (mode ^ "-codex") in
  write command (Printf.sprintf {|#!/usr/bin/env python3
import json, sys
if '--masc-warmup' in sys.argv:
    sys.exit(0)
capture = %S
mode = %S

def emit(value):
    print(json.dumps(value), flush=True)

for line in sys.stdin:
    request = json.loads(line)
    with open(capture, 'a') as out:
        out.write(json.dumps(request)+'\n')
    method, ident = request.get('method'), request.get('id')
    if method == 'initialize':
        emit({'id':ident,'result':{'userAgent':'fixture/0.147.0','codexHome':'/tmp/codex','platformFamily':'unix','platformOs':'linux'}})
    elif method == 'account/read':
        account = None if mode == 'no-account' else {'type':'chatgpt','email':'fixture@example.test','planType':'pro'}
        emit({'id':ident,'result':{'account':account,'requiresOpenaiAuth':True}})
    elif method == 'thread/start':
        emit({'id':ident,'result':{'thread':{'id':'vision-thread'},'model':'vision-response-model'}})
    elif method == 'turn/start':
        emit({'id':ident,'result':{'turn':{'id':'vision-turn'}}})
        if mode == 'interrupted':
            emit({'method':'turn/completed','params':{'threadId':'vision-thread','turn':{'id':'vision-turn','items':[],'status':'interrupted'}}})
            continue
        text = {'valid':'{"text":"  A red pixel.  "}', 'malformed':'{"text":', 'empty':'{"text":"  "}', 'wrong-type':'{"text":42}'}[mode]
        item = {'type':'agentMessage','id':'final','text':text,'phase':'final_answer'}
        emit({'method':'item/completed','params':{'threadId':'vision-thread','turnId':'vision-turn','completedAtMs':1,'item':item}})
        emit({'method':'turn/completed','params':{'threadId':'vision-thread','turn':{'id':'vision-turn','items':[item],'status':'completed'}}})
|} capture mode);
  Unix.chmod command 0o700;
  command, capture

let runtime_config ~command ~fallback ~media = Printf.sprintf {|
[providers.official]
protocol = "codex-app-server"
command = %S
is-non-interactive = true
[providers.fallback]
protocol = "codex-app-server"
command = %S
is-non-interactive = true
[models.vision]
api-name = "vision-request-model"
max-context = 400000
tools-support = true
[models.vision.capabilities]
supports-image-input = true
[official.vision]
[fallback.vision]
[runtime]
default = "official.vision"
media_failover = %s
[runtime.exact_output_lanes.verifier_exact]
slots = []
cli_slots = ["official.vision"]
|} command fallback media

let with_fixture mode test =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Eio_context.set_env env;
  Eio_context.with_test_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~sw @@ fun () ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let saved = Runtime.For_testing.snapshot () in
  let root = Filename.temp_file "vision-official-" "" in
  Unix.unlink root; Unix.mkdir root 0o700;
  let previous_base = Sys.getenv_opt "MASC_BASE_PATH" in
  Unix.putenv "MASC_BASE_PATH" root;
  Config_dir_resolver.reset ();
  Eio.Switch.on_release sw (fun () ->
    (match previous_base with Some path -> Unix.putenv "MASC_BASE_PATH" path | None -> unsetenv "MASC_BASE_PATH");
    Config_dir_resolver.reset ();
    Runtime.For_testing.restore saved;
    Fs_compat.remove_tree root);
  let command, capture = fixture root ~mode in
  let fallback, fallback_capture = fixture root ~mode:"valid" in
  let load media =
    let config_path = Filename.concat root "runtime.toml" in
    write config_path (runtime_config ~command ~fallback ~media);
    match Runtime.init_default ~config_path with
    | Ok () -> () | Error detail -> fail detail in
  let run ?runtime_id () = V.run_vision ~base_path:root ?runtime_id
    ~sw ~net:env#net ~clock:env#clock ~query
    ~media_type:"image/png" ~bytes:(Base64.decode_exn png) () in
  let execute () =
    let meta = match Masc_test_deps.meta_of_json_fixture (`Assoc ["name", `String "vision-fixture"]) with
      | Ok meta -> meta | Error detail -> fail detail in
    let artifact = match V.store_artifact ~dir:(V.vision_store_dir ~keeper_name:meta.name)
        (Base64.decode_exn png) with
      | Ok handle -> Multimodal.Vision_artifact_store.to_string handle
      | Error detail -> fail detail in
    V.handle_with_outcome ~base_path:root ~sw ~clock:env#clock ~net:env#net
      ~meta ~args:(`Assoc ["artifact", `String artifact; "query", `String query]) () in
  test ~root ~load ~run ~execute ~capture ~fallback_capture

let records path = In_channel.with_open_bin path In_channel.input_lines
  |> List.map Yojson.Safe.from_string
let request name rows = List.find (fun row -> member "method" row = `String name) rows

let test_response mode = with_fixture mode @@ fun ~root:_ ~load ~run ~execute:_ ~capture ~fallback_capture:_ ->
  load "[\"official.vision\"]";
  (match mode, run () with
   | "valid", V.Vo_ok reading ->
     check string "validated text" "A red pixel." reading.text;
     check string "selected runtime" "official.vision" reading.runtime_id;
     check string "requested identity" "vision-request-model" reading.requested_model;
     check string "actual response identity" "vision-response-model" reading.response_model
   | ("malformed" | "empty" | "wrong-type"), V.Vo_invalid_structured_response _ -> ()
   | _ -> fail "unexpected vision outcome");
  let rows = records capture in
  let thread = request "thread/start" rows |> member "params" in
  let instructions = member "developerInstructions" thread |> Yojson.Safe.Util.to_string in
  check bool "nonempty analysis contract" true (String.length instructions > 0);
  check bool "user query is not promoted to system instructions" false
    (String_util.string_contains_substring ~needle:query instructions);
  let turn = request "turn/start" rows |> member "params" in
  let input = member "input" turn |> Yojson.Safe.Util.to_list in
  check bool "query reaches the user input" true
    (List.exists (fun item -> member "type" item = `String "text" &&
       match member "text" item with
       | `String text -> String_util.string_contains_substring ~needle:query text
       | _ -> false) input);
  let images = input
    |> List.filter (fun item -> member "type" item = `String "image") in
  check int "one actual image" 1 (List.length images);
  check string "exact image bytes" ("data:image/png;base64," ^ png)
    (List.hd images |> member "url" |> Yojson.Safe.Util.to_string);
  let schema = member "outputSchema" turn in
  check bool "text field is required" true
    (member "required" schema = `List [`String "text"]);
  check string "text field type" "string"
    (schema |> member "properties" |> member "text" |> member "type" |> Yojson.Safe.Util.to_string)

let test_selection () = with_fixture "malformed" @@ fun ~root:_ ~load ~run ~execute:_ ~capture ~fallback_capture ->
  load "[]";
  (match run () with V.Vo_no_runtime _ -> () | _ -> fail "verifier CLI slot leaked into media candidates");
  check bool "no undeclared dispatch" false (Sys.file_exists capture);
  load "[\"official.vision\", \"fallback.vision\"]";
  (match run ~runtime_id:"official.vision" () with
   | V.Vo_invalid_structured_response _ -> () | _ -> fail "explicit selection unexpectedly succeeded");
  check bool "explicit runtime never falls back" false (Sys.file_exists fallback_capture);
  (match run () with
   | V.Vo_ok reading -> check string "declared fallback succeeds" "fallback.vision" reading.runtime_id
   | _ -> fail "invalid output did not advance to declared fallback")

let test_transport_failure mode = with_fixture mode @@ fun ~root:_ ~load ~run ~execute ~capture ~fallback_capture ->
  load "[\"official.vision\", \"fallback.vision\"]";
  let outcome = run () in
  (match mode, outcome with
   | "no-account", V.Vo_ok reading ->
     check string "typed auth failure advances" "fallback.vision" reading.runtime_id;
     let rows = records capture in
     check bool "auth failure happened before thread start" false
       (List.exists (fun row -> member "method" row = `String "thread/start") rows);
     check bool "fallback submitted its image" true
       (List.exists (fun row -> member "method" row = `String "turn/start") (records fallback_capture))
   | "interrupted", V.Vo_official_failure _ ->
     check bool "intentional stop does not rotate" false (Sys.file_exists fallback_capture);
     let execution = execute () in
     check bool "accepted failure receipt preserves uncertainty" true
       (execution.failure_effect_disposition = Tool_result.Effect_outcome_unknown);
     check bool "handler remains failed" true
       (match execution.disposition with Tool_result.Failed _ -> true | _ -> false);
     check bool "handler did not rotate after stop" false (Sys.file_exists fallback_capture)
   | _ -> fail "incorrect typed failure rotation")

let test_claude_admission_failure () =
  with_fixture "valid" @@ fun ~root ~load:_ ~run ~execute:_ ~capture:_ ~fallback_capture ->
  let command = Filename.concat root "claude-invalid-auth" in
  let capture = Filename.concat root "claude-args.json" in
  write command (Printf.sprintf {|#!/usr/bin/env python3
import json, sys
with open(%S, 'w') as out:
    json.dump(sys.argv[1:], out)
print('{}', flush=True)
|} capture);
  Unix.chmod command 0o700;
  let fallback = Filename.concat root "valid-codex" in
  let config_text = runtime_config ~command:fallback ~fallback
      ~media:"[\"claude.vision\", \"fallback.vision\"]" ^ Printf.sprintf {|
[providers.claude]
protocol = "claude-code"
command = %S
is-non-interactive = true
[claude.vision]
|} command in
  let config_path = Filename.concat root "runtime.toml" in
  write config_path config_text;
  (match Runtime.init_default ~config_path with Ok () -> () | Error detail -> fail detail);
  (match run () with
   | V.Vo_ok reading -> check string "admission failure advances" "fallback.vision" reading.runtime_id
   | _ -> fail "Claude preflight failure prevented declared Codex fallback");
  let args = In_channel.with_open_bin capture In_channel.input_all
    |> Yojson.Safe.from_string |> Yojson.Safe.Util.to_list in
  check bool "Claude only measured authentication" true
    (List.mem (`String "auth") args && List.mem (`String "status") args);
  check bool "Claude never received a model prompt" false (List.mem (`String "--print") args);
  check bool "fallback received actual turn" true
    (List.exists (fun row -> member "method" row = `String "turn/start") (records fallback_capture))

let () = run "Keeper standalone official-client vision"
  [ "image and result", List.map (fun mode -> test_case mode `Quick (fun () -> test_response mode))
      ["valid"; "malformed"; "empty"; "wrong-type"]
  ; "selection", [test_case "explicit media membership and fallback" `Quick test_selection]
  ; "transport failure", List.map (fun mode -> test_case mode `Quick (fun () -> test_transport_failure mode))
      ["no-account"; "interrupted"]
  ; "admission", [test_case "Claude preflight failure advances" `Quick test_claude_admission_failure]
  ]
