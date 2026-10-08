(* Real Owner -> Keeper_turn -> Keeper_agent_run. The HTTP peer is a provider
   fixture, not the server ingress. The in-process person-note tool performs
   the durable effect; no guest sandbox is acquired. *)
open Alcotest
open Masc
module Native = Keeper_direct_native_continuation
module Registry = Keeper_owner_registry
module Owner = Keeper_owner
module Checkpoint = Keeper_checkpoint_store
module Projection = Agent_core.Agent.Execution_projection

type cut = Settled_result | Returned_turn
type resume_proof =
  { original_call : Keeper_native_call.t
  ; canonical_result : Agent_core.Types.content_block
  }
let cut_name = function Settled_result -> "settled" | Returned_turn -> "terminal"
let exit_code = function Settled_result -> 86 | Returned_turn -> 87
let keeper_name = "ingress-native-proof"
let session_id = "ingress-native-session"
let model_id = "ingress-native-model"
let runtime_id = "fixture.native"
let tool_name = "keeper_person_note_set"
let target_id = "ingress-note-call"
let goal = "Remember the fixture person's note, then confirm it."
let note = "The original request owns this note."
let speaker = Keeper_input_speaker.Person Keeper_input_speaker.Owner
let require label = function Ok value -> value | Error _ -> fail (label ^ " failed")
let operation_id = Keeper_chat_operation.Operation_id.of_string "ingress-native-operation"
  |> require "operation ID"
let source = `Assoc ["kind", `String "fixture"; "submitted_by", `String "original-owner"]
let original_input () =
  Keeper_chat_operation_payload.input_to_json ~message:goal ~user_blocks:[]
    ~turn_instructions:(Some "Preserve this original task.") ~surface_context:None ~attachments:[]
  |> Keeper_chat_operation.canonical_json |> require "original input"

let write path bytes = Out_channel.with_open_bin path (fun channel ->
  output_string channel bytes; flush channel; Unix.fsync (Unix.descr_of_out_channel channel))
let read path = In_channel.with_open_bin path In_channel.input_all
let record root name =
  let channel = open_out_gen [Open_wronly; Open_creat; Open_append; Open_binary]
      0o600 (Filename.concat root (name ^ ".events")) in
  Fun.protect ~finally:(fun () -> close_out_noerr channel) (fun () ->
    output_string channel "observed\n"; flush channel; Unix.fsync (Unix.descr_of_out_channel channel))
let lines path = if Sys.file_exists path then
    read path |> String.split_on_char '\n' |> List.filter (fun line -> line <> "") else []
let count root name = List.length (lines (Filename.concat root (name ^ ".events")))

(* Outside the Eio turn: stream the executable rather than allocating its
   entire image. Digestif's public API has no file-digest convenience call. *)
let executable_sha256 () =
  In_channel.with_open_bin Sys.executable_name (fun channel ->
    let buffer = Bytes.create Sys.io_buffer_size in
    let rec loop context = match input channel buffer 0 (Bytes.length buffer) with
      | 0 -> Digestif.SHA256.(get context |> to_hex)
      | size -> loop (Digestif.SHA256.feed_bytes context ~off:0 ~len:size buffer) in
    loop Digestif.SHA256.empty)

let emit_evidence ~root ~cut ~executable_sha256 ~note_rows ~target_tool_log_rows =
  let json = `Assoc [
    "evidence", `String "keeper-ingress-native-restart";
    "case", `String (cut_name cut);
    "candidate_sha", (match Sys.getenv_opt "MASC_TEST_CANDIDATE_SHA" with
      | None -> `Null | Some sha -> `String sha);
    "executable_sha256", `String executable_sha256;
    "runtime_id", `String runtime_id;
    "provider_protocol", `String "loopback-openai-compatible-http";
    "scope", `String "Owner-to-admitted-Keeper-turn";
    "provider_calls", `Int (count root "provider");
    "ingress_calls", `Int (count root "ingress");
    "target_approval_calls", `Int (count root "approval");
    "target_ready_callbacks", `Int (count root "ready");
    "target_note_rows", `Int note_rows;
    "target_tool_log_rows", `Int target_tool_log_rows;
    "status", `String "all-assertions-passed"] in
  print_endline (Yojson.Safe.to_string json)

let response message finish_reason =
  Yojson.Safe.to_string (`Assoc ["id", `String "ingress-response"; "model", `String model_id;
    "choices", `List [`Assoc ["index", `Int 0; "message", message;
      "finish_reason", `String finish_reason]];
    "usage", `Assoc ["prompt_tokens", `Int 5; "completion_tokens", `Int 2; "total_tokens", `Int 7]])
let tool_response id name args = response (`Assoc ["role", `String "assistant"; "content", `Null;
  "tool_calls", `List [`Assoc ["id", `String id; "type", `String "function";
    "function", `Assoc ["name", `String name; "arguments", `String (Yojson.Safe.to_string args)]]]]) "tool_calls"
let final_response = response (`Assoc ["role", `String "assistant";
  "content", `String "The original note is saved."]) "stop"

let target_result = function
  | Agent_core.Types.ToolResult {tool_use_id; _} -> String.equal tool_use_id target_id
  | Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _
  | Image _ | Document _ | Audio _ -> false
let target_results (checkpoint : Agent_core.Checkpoint.t) =
  checkpoint.messages |> List.concat_map (fun (m : Agent_core.Types.message) -> m.content)
  |> List.filter target_result
let retained ~session_dir reference =
  Checkpoint.load_retained_exact_snapshot ~session_dir ~reference
  |> require "exact retained checkpoint" |> Checkpoint.exact_snapshot_checkpoint
let native_state binding =
  Registry.direct_native_call ~base_path:binding.Native.base_path
    ~keeper_name:binding.keeper_name ~operation_id:binding.operation_id
  |> require "native authority"

let projection_events projection =
  let through = Projection.current_cursor projection |> require "projection high watermark" in
  let rec read_pages after acc =
    let page = Projection.read_page projection ~after ~through ~limit:256 ()
      |> require "committed projection page" in
    let acc = List.rev_append page.events acc in
    if page.has_more then read_pages page.next_cursor acc else List.rev acc in
  read_pages (Projection.beginning_cursor projection) []

let check_original_input (checkpoint : Agent_core.Checkpoint.t) =
  let original = List.filter (fun (message : Agent_core.Types.message) ->
    message.role = Agent_core.Types.User && Agent_core.Types.text_of_content message.content = goal)
      checkpoint.messages in
  check int "original User input occurs once" 1 (List.length original);
  let message = List.hd original in
  check bool "original speaker metadata survives" true
    (message.metadata = Keeper_input_speaker.metadata speaker)

let check_repetition (checkpoint : Agent_core.Checkpoint.t) =
  let frame = Keeper_repetition_context.load checkpoint.context |> require "direct repetition context" in
  let observations = Keeper_repetition_snapshot.observations frame
      ~scope:(Keeper_execution_scope_id.direct_operation operation_id)
    |> require "original direct scope observations" in
  check int "settled note contributes one direct repetition observation" 1
    (List.length (List.filter (fun (observation : Keeper_repetition_snapshot.observation) ->
      String.equal observation.tool_name tool_name) observations))

let effect_counts root =
  let notes_path = Filename.concat (Filename.concat
      (Common.masc_dir_from_base_path ~base_path:root) "keeper_person_notes") (keeper_name ^ ".jsonl") in
  let note_rows = List.length (lines notes_path) in
  let rows = Keeper_tool_call_log.read_recent ~keeper_name ~n:32 () |> require "committed tool log" in
  let target_tool_log_rows = List.length (List.filter (fun row ->
    Yojson.Safe.Util.member "tool_use_id" row = `String target_id) rows) in
  note_rows, target_tool_log_rows

let check_effect_counts root =
  let note_rows, target_tool_log_rows = effect_counts root in
  check int "one durable note append, not a repeated overwrite" 1 note_rows;
  check (list (pair string string)) "the original note persists" ["fixture-person", note]
    (Keeper_person_notes.notes ~base_dir:root ~keeper_name);
  check int "one committed target tool-call row" 1 target_tool_log_rows;
  check int "target approval pre-hook ran once" 1 (count root "approval");
  check int "target post-tool ready callback ran once" 1 (count root "ready")

let check_resume_authority ~env ~root binding =
  let call = match native_state binding with
    | Keeper_native_call.Active call -> call
    | No_native_call | Terminal_unacknowledged _ -> fail "restart lost its Active native receipt" in
  let checkpoint = retained ~session_dir:binding.session_dir call.checkpoint in
  check int "native checkpoint precedes target ToolResult append" 0 (List.length (target_results checkpoint));
  ignore (Keeper_tool_load_receipts.restore ~source:checkpoint.context
    ~target:(Agent_core.Context.create ()) |> require "retained tool-load receipt decodes");
  let loads = Agent_core.Context.get_scoped checkpoint.context Agent_core.Context.Session
      "keeper_outstanding_tool_loads" |> Option.get in
  let pending = Yojson.Safe.Util.(loads |> member "pending" |> to_list) in
  check bool "exact checkpoint retains the original target load receipt" true
    (List.exists (fun row -> Yojson.Safe.Util.member "name" row = `String tool_name
      && Yojson.Safe.Util.member "tool_use_id" row = `String "ingress-load-call") pending);
  let seed = retained ~session_dir:binding.session_dir call.seed_checkpoint in
  check_original_input seed;
  check string "Active call stays on its saved runtime" runtime_id call.runtime_id;
  check string "receipt binds original execution digest" binding.execution_digest call.operation_digest;
  let runtime = Runtime_agent_execution_runtime.get () |> Option.get in
  let dir = Eio.Path.(env#fs / binding.session_dir / "native-executions" / call.call_id) in
  let projection = Agent_core.Agent.open_execution_projection ~runtime ~dir call.locator
    |> require "open Core journal projection" in
  check bool "Core root is still running" true
    (Agent_core.Agent.read_execution_terminal projection |> require "read Core terminal" |> Option.is_none);
  let results = projection_events projection |> List.filter_map (fun (event : Projection.event) ->
    match event.payload with
    | Projection.Node_updated {update=Tool_result result; _} when target_result result -> Some result
    | Node_opened _ | Node_closed _ | Node_updated _ -> None) in
  check int "Core has one committed target ToolResult before checkpoint" 1 (List.length results);
  let before = native_state binding in
  (match Native.load ~binding:{binding with execution_digest=String.make 64 '0'} with
   | Error _ -> () | Ok _ -> fail "foreign operation digest reused the Active receipt");
  check bool "refused digest does not alter receipt" true
    (Keeper_native_call.equal_state before (native_state binding));
  check_effect_counts root;
  {original_call=call; canonical_result=List.hd results}

let run_phase ~child ~cut root =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  Eio_context.set_env env;
  Eio_context.with_test_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~sw @@ fun () ->
  ignore (Server_startup_state.mark_state_ready ());
  Runtime_agent_execution_runtime.initialize ~sw ~domain_mgr:env#domain_mgr ~domain_count:1
    |> require "native execution capability";
  Keeper_tool_call_log.init ~base_path:root ();
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  Prompt_defaults.init ();
  Masc_test_deps.init_unified_tool_registry ();
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let catalog_snapshot = Llm_provider.Model_catalog.global () in
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore runtime_snapshot;
    match catalog_snapshot with None -> Llm_provider.Model_catalog.clear_global ()
    | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
  let catalog = Printf.sprintf
    "[[models]]\nid_prefix=%S\nprovider_name=\"fixture\"\nbase=\"openai_chat\"\nmax_context_tokens=400000\nmax_output_tokens=256\nsupports_tools=true\nsupports_native_streaming=false\n" model_id in
  Llm_provider.Model_catalog.of_toml_string ~source:"ingress-restart" catalog
    |> require "catalog" |> Llm_provider.Model_catalog.set_global;
  let resumed_proof = ref None in
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
      (Exact_output_fixture.Reply_with (fun index body ->
        record root "provider";
        if child then (`OK, match index with
          | 0 -> tool_response "ingress-load-call" "keeper_tool_search" (`Assoc ["names", `List [`String tool_name]])
          | 1 -> tool_response target_id tool_name (`Assoc ["speaker_id", `String "fixture-person"; "note", `String note])
          | _ -> final_response)
        else (
          let request = Yojson.Safe.from_string body in
          let messages = Yojson.Safe.Util.(request |> member "messages" |> to_list) in
          let results = List.filter (fun message -> Yojson.Safe.Util.member "tool_call_id" message = `String target_id) messages in
          check int "real ingress resumes with exactly one target ToolResult" 1 (List.length results);
          let proof = match !resumed_proof with
            | Some proof -> proof
            | None -> fail "provider ran before canonical recovery evidence was checked" in
          let canonical_content = match proof.canonical_result with
            | Agent_core.Types.ToolResult {content; _} -> content
            | Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _
            | Image _ | Document _ | Audio _ -> fail "canonical recovery evidence is not a ToolResult" in
          check bool "provider receives the canonically settled result, not a repair placeholder" true
            (Yojson.Safe.Util.member "content" (List.hd results) = `String canonical_content);
          let tools = Yojson.Safe.Util.(request |> member "tools" |> to_list) in
          check bool "loaded target schema survives real tool setup" true
            (List.exists (fun tool -> Yojson.Safe.Util.(tool |> member "function" |> member "name") = `String tool_name) tools);
          `OK, final_response))) in
  let runtime_path = Filename.concat root "runtime.toml" in
  write runtime_path (Printf.sprintf {|[runtime]
default = "fixture.native"
[runtime.assignments]
ingress-native-proof = "fixture.native"
[providers.fixture]
protocol = "openai-compatible-http"
endpoint = %S
[models.native]
api-name = %S
max-context = 400000
tools-support = true
streaming = false
[fixture.native]
is-default = true
|} server.base_url model_id);
  Runtime.init_default ~config_path:runtime_path |> require "runtime";
  let config = Workspace.default_config root in
  if child then (
    ignore (Workspace.init config ~agent_name:(Some "ingress-fixture"));
    (* The admitted turn validates the complete Docker profile even though
       these in-process tools never acquire a guest. The catalog helper only
       records a reference; it neither inspects nor starts Docker. *)
    Masc_test_deps.write_sandbox_image_catalog ~base_path:root
      ["base", "masc-ingress-native-fixture:unused"];
    let keeper_path = Config_dir_resolver.keeper_toml_path_for_base_path
        ~base_path:root keeper_name in
    Fs_compat.mkdir_p (Filename.dirname keeper_path);
    write keeper_path (Otoml.Printer.to_string (Otoml.TomlTable [
      "keeper", Otoml.TomlTable [
        "instructions", Otoml.TomlString (keeper_name ^ " fixture instructions");
        "activation_mode", Otoml.TomlString "manual";
        "sandbox_profile", Otoml.TomlString
          (Keeper_types_profile.sandbox_profile_to_string Keeper_types_profile.Docker);
        "sandbox_image", Otoml.TomlString "base"]]));
    let meta = Masc_test_deps.meta_of_json_fixture (`Assoc ["name", `String keeper_name;
      "trace_id", `String session_id; "activation_mode", `String "manual"])
      |> require "meta" in
    Keeper_meta_store.replace_snapshot config meta |> require "persist meta");
  let meta = Keeper_meta_store.read_meta config keeper_name |> require "load meta" |> Option.get in
  ignore (Keeper_registry.For_testing.register ~base_path:root keeper_name meta);
  Eio.Switch.on_release sw (fun () -> Keeper_registry.For_testing.unregister ~base_path:root keeper_name);
  let session_dir = Keeper_fs.keeper_session_dir config session_id in
  Masc_test_deps.with_publication_recovery_registry ~sw ~fs:env#fs ~registry_root:root
  @@ fun publication_registry ->
  let publication_recovery_provider = Masc_test_deps.publication_recovery_provider publication_registry in
  let completed, resolve_completed = Eio.Promise.create () in
  let execute ~sw:turn_sw ~keeper_name:_ ~claim =
    record root "ingress";
    if not child && cut = Returned_turn then fail "Owner redispatched a terminal native operation";
    let operation : Keeper_chat_operation.t = claim () |> require "claim" |> Option.get in
    check bool "Owner claims the original input" true (operation.input = Some (original_input ()));
    check bool "Owner preserves original source" true (operation.source = source);
    check bool "Owner preserves original ID" true
      (Keeper_chat_operation.Operation_id.equal operation_id operation.operation_id);
    let digest_path = Filename.concat root "original-execution-digest" in
    if child then write digest_path operation.execution_digest
    else check string "execution digest is unchanged after restart" (read digest_path) operation.execution_digest;
    let binding : Native.binding = {base_path=root;keeper_name;operation_id;
      execution_digest=operation.execution_digest;session_dir;session_id} in
    if not child then resumed_proof := Some (check_resume_authority ~env ~root binding);
    let gate = Keeper_tool_approval_gate.create
        ~registry:(Keeper_tool_approval_registry.create ())
        ~late_approvals:(Keeper_late_approval.create ()) ~publish:(fun _ -> ())
        ~redact_text:Fun.id ~clock:env#clock ~keeper_name
        ~timeout_sec:Exact_output_fixture.fixture_wait_seconds in
    let approval_gate = {gate with Keeper_tool_approval_gate.pre_tool_use=(fun ~identity_tool_index event ->
      (match event with
       | Agent_core.Hooks.PreToolUse {tool_name=name; _} when String.equal name tool_name -> record root "approval"
       | PreToolUse _ | BeforeTurn _ | BeforeTurnParams _ | AfterTurn _ | PostToolUse _
       | PostToolUseFailure _ | OnToolError _ | OnError _ | OnStop _ -> ());
      gate.pre_tool_use ~identity_tool_index event)} in
    check bool "the real approval policy remains Auto" true
      (Keeper_tool_approval_mode.resolve (Keeper_tool_approval_mode.shared ()) ~keeper_name
       = Keeper_tool_approval_mode.Auto);
    let on_tool_result_ready ~tool_call_id ~turn:_ ~planned_index:_ ~execution_id:_ =
      if String.equal tool_call_id target_id then (
        record root "ready";
        if child && cut = Settled_result then Unix._exit (exit_code cut)) in
    let ctx : _ Keeper_types_profile.context = {config;agent_name="original-owner";sw=turn_sw;
      clock=env#clock;proc_mgr=Some env#process_mgr;net=Some env#net;publication_recovery_provider} in
    let message = Keeper_invocation_contract.direct_message ~keeper_name ~prompt:goal ~direct_reply:false
        ~turn_instructions:"Preserve this original task." ~channel:"fixture" ~user_blocks:[] ~attachments:[] ()
      |> require "direct message" in
    let dispatched = Keeper_turn_dispatch_authority.run (fun admission_token ->
      Keeper_turn.handle_keeper_msg_admitted ~operation_id ~admission_token ~input_speaker:speaker
        ~approval_gate ~on_tool_result_ready ctx message) in
    (match dispatched with
     | Keeper_turn.Turn_failed {failure; _} -> fail (Keeper_request_failure.summary failure)
     | Keeper_turn.Turn_settled result ->
       if not (Tool_result.is_success result) then fail (Tool_result.message result));
    let terminal_call = match native_state binding with
      | Keeper_native_call.Terminal_unacknowledged (call, {Agent_core.Agent.outcome=Terminal_succeeded; recovery=Retire}) ->
        call
      | No_native_call | Active _ | Terminal_unacknowledged _ -> fail "real ingress omitted its native terminal receipt" in
    let checkpoint = retained ~session_dir terminal_call.checkpoint in
    check_original_input checkpoint;
    check int "final checkpoint includes target result once" 1 (List.length (target_results checkpoint));
    (match !resumed_proof with
     | None -> ()
     | Some proof ->
       check string "resume finishes the original native call" proof.original_call.call_id terminal_call.call_id;
       check bool "resume retains the original Core execution locator" true
         (Yojson.Safe.equal
           (Agent_core.Agent.execution_locator_to_yojson proof.original_call.locator)
           (Agent_core.Agent.execution_locator_to_yojson terminal_call.locator));
       check bool "final retained result exactly equals canonical journal evidence" true
         (target_results checkpoint = [proof.canonical_result]));
    check_repetition checkpoint;
    check_effect_counts root;
    if child then Unix._exit (exit_code cut);
    Owner.Operation_succeeded {outcome_ref="real-ingress-native-recovered"}
  in
  let runner : Owner.operation_runner = {ready=(fun ~keeper_name:_ -> true);execute;
    on_execution_settled=(fun ~keeper_name:_ ~claimed_operation_id:_ ~execution ->
      Eio.Promise.resolve resolve_completed execution)} in
  Registry.install_from_store ~sw ~operation_runner:(Some runner) ~on_turn_slot_released:None config
    |> require "install real Owner" |> ignore;
  if child then Registry.submit_operation ~base_path:root ~keeper_name ~operation_id ~source ~input:(original_input ())
    |> require "submit original operation" |> ignore;
  if child || cut = Settled_result then (
    (match Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds
        (fun () -> Eio.Promise.await completed) with
     | Owner.Operation_succeeded _ -> ()
     | Operation_failed {detail;_} -> fail detail
     | Operation_deferred -> fail "fixture unexpectedly deferred");
    let operation = Registry.exact_operation ~base_path:root ~keeper_name operation_id |> require "final operation" |> Option.get in
    check bool "Owner committed the exact terminal receipt" true
      (match operation.state with
       | Keeper_chat_operation.Succeeded {outcome_ref;_} -> outcome_ref = "real-ingress-native-recovered"
       | Queued | Running _ | Failed _ | Cancelled _ -> false);
    check bool "Owner atomically acknowledged native authority" true
      (Registry.direct_native_call ~base_path:root ~keeper_name ~operation_id |> require "final native state"
       |> Keeper_native_call.equal_state Keeper_native_call.No_native_call))
  else (
    let operation = Registry.exact_operation ~base_path:root ~keeper_name operation_id |> require "interrupted terminal operation" |> Option.get in
    check bool "unacknowledged terminal never infers successful delivery" true
      (match operation.state with
       | Keeper_chat_operation.Failed {failure={kind=Interrupted_by_restart;_};_} -> true
       | Queued | Running _ | Succeeded _ | Failed _ | Cancelled _ -> false);
    let binding : Native.binding = {base_path=root;keeper_name;operation_id;
      execution_digest=operation.execution_digest;session_dir;session_id} in
    (match Native.load ~binding |> require "terminal admission" with
     | Native.Terminal_pending _ -> ()
     | No_pending | Resume _ -> fail "terminal receipt became replayable");
    check int "terminal restart does not invoke ingress again" 1 (count root "ingress");
    check int "terminal restart admits no provider request" 0 (Exact_output_fixture.post_count server));
  check_effect_counts root;
  effect_counts root

let test_restart cut () =
  let root = Filename.temp_dir "keeper-ingress-restart-" "" in
  let executable_before = executable_sha256 () in
  Fun.protect ~finally:(fun () ->
    Eio_main.run (fun env -> Eio.Path.rmtree ~missing_ok:true Eio.Path.(env#fs / root))) (fun () ->
    Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      let process = Eio.Process.spawn ~sw env#process_mgr
          [Sys.executable_name; "--ingress-native-child"; cut_name cut; root] in
      match Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds
          (fun () -> Eio.Process.await process) with
      | `Exited code -> check int "hard process cut at the requested boundary" (exit_code cut) code
      | `Signaled signal -> failf "child died from signal %d" signal));
    let note_rows, target_tool_log_rows = run_phase ~child:false ~cut root in
    check int "only two original requests and one final response" 3 (count root "provider");
    let executable_after = executable_sha256 () in
    check string "the child and parent used an unchanged executable" executable_before executable_after;
    emit_evidence ~root ~cut ~executable_sha256:executable_after ~note_rows ~target_tool_log_rows)

let () = match Array.to_list Sys.argv with
  | [_; "--ingress-native-child"; "settled"; root] -> ignore (run_phase ~child:true ~cut:Settled_result root)
  | [_; "--ingress-native-child"; "terminal"; root] -> ignore (run_phase ~child:true ~cut:Returned_turn root)
  | _ -> run "Keeper direct ingress native restart" ["real ingress", [
      test_case "settled result resumes through the original Keeper turn" `Quick (test_restart Settled_result);
      test_case "unacknowledged terminal does not reexecute ingress" `Quick (test_restart Returned_turn)]]
