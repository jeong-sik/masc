open Alcotest
open Masc
module Capture = Keeper_librarian_durable_capture
module Consumer = Keeper_librarian_durable_consumer
module B = Keeper_turn_boundaries
module P = Keeper_librarian_progress
module C = Keeper_checkpoint_store
module F = Keeper_turn_fragments
let keeper_name = "source-capture-reader"
let get = function Ok value -> value | Error detail -> fail detail
let message text = Agent_core.Types.make_message ~role:Agent_core.Types.User [Agent_core.Types.Text text]
let checkpoint ~trace_id messages turn_count : Agent_core.Checkpoint.t =
  { provider_binding = None; version = Agent_core.Checkpoint.checkpoint_version
  ; session_id = trace_id
  ; agent_name = keeper_name
  ; model = "fixture-model"
  ; system_prompt = None
  ; messages
  ; usage = Agent_core.Types.empty_usage
  ; turn_count
  ; created_at = Float.of_int turn_count
  ; tools = []
  ; tool_choice = None
  ; disable_parallel_tool_use = false
  ; temperature = None
  ; top_p = None
  ; top_k = None
  ; min_p = None
  ; reasoning_effort = None
  ; enable_thinking = None
  ; preserve_thinking = None
  ; response_format = Agent_core.Types.Off
  ; cache_system_prompt = false
  ; context = Agent_core.Context.create_sync ()
  ; pending_input = None; mcp_sessions = []
  ; working_context = None
  }
;;

let save_checkpoint config ~trace_id messages turn_count =
  let session_dir = Keeper_fs.keeper_session_dir config trace_id in
  match
    C.save_agent_core_classified
      ~session_dir
      ~history_retained:0
      (checkpoint ~trace_id messages turn_count)
  with
  | Ok (C.Saved _) -> ()
  | Ok (C.Stale_noop _) -> fail "fixture checkpoint was stale"
  | Error detail -> failf "save checkpoint: %s" detail
;;

let append config ~trace_id ~turn ~time ~history_at_start position =
  B.append ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name
    {B.recorded_at=time;event=B.Turn_ended {turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:turn;
      task_context=Keeper_turn_task_context.No_task;history_at_start;position}}
  |> Result.map_error B.append_error_to_string |> get
let atom_boundary config ~trace_id ~turn ~time ~history_at_start messages =
  append config ~trace_id ~turn ~time ~history_at_start (B.position_of_messages messages |> get)
let meta config trace_id =
  let meta=Masc_test_deps.meta_of_json_fixture (`Assoc ["name",`String keeper_name;"trace_id",`String trace_id]) |> get in
  Keeper_meta_store.replace_snapshot config meta |> get
let official_turn config ~trace_id ~turn ~time =
  let turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:turn in
  let session=Keeper_context_core.create_session ~session_id:trace_id ~base_dir:(Keeper_fs.session_store_path config) in
  Keeper_context_core_history.persist_message ~keeper_name ~turn_ref ~source:"direct_user" session (message "official main");
  Keeper_context_core_history.persist_message ~keeper_name ~turn_ref ~source:"internal_assistant" session
    (Agent_core.Types.make_message ~role:Agent_core.Types.Assistant [Agent_core.Types.Text "official internal"]);
  Keeper_context_core_history.persist_tool_observation ~keeper_name ~turn_ref session ~tool_name:"read_file"
    ~outcome:Tool_result.Ok;
  append config ~trace_id ~turn ~time ~history_at_start:B.Continued_history B.No_atom_history

type fixture_kind = Atoms | Official | Mixed
let with_fixture kind f =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  Masc_test_deps.ensure_rng_initialized ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path=Filename.temp_dir "durable-original-source-" "" in
  Config_dir_resolver.reset ();
  Fun.protect ~finally:(fun () -> Config_dir_resolver.reset ();Fs_compat.remove_tree base_path) (fun () ->
    let config=Workspace.default_config base_path in
    ignore (Workspace.init config ~agent_name:None : string);
    Masc_test_deps.declare_fixture_keeper ~base_path ~sandbox_profile:(Some Keeper_types_profile.Docker)
      ~sandbox_image:"base" keeper_name;
    Keeper_types_profile.invalidate_keeper_profile_snapshots ();
    let trace_id="source-capture-trace" in
    meta config trace_id;
    let now=Time_compat.now () in
    let first=[message "already read"] in
    (match kind with
     | Official -> ()
     | Atoms | Mixed ->
       save_checkpoint config ~trace_id first 1;
       atom_boundary config ~trace_id ~turn:1 ~time:(now-.10.) ~history_at_start:B.Continued_history first;
       (match Consumer.consume_one ~config ~keeper_name
          ~commit:(fun _ -> fail "baseline must not request a Memory commit") with
        | Ok (Consumer.Baseline_advanced _) -> ()
        | Ok _ -> fail "fixture baseline did not advance"
        | Error error -> fail (Consumer.error_to_string error)));
    (match kind with Official | Mixed -> official_turn config ~trace_id ~turn:2 ~time:(now+.2.) | Atoms -> ());
    (match kind with
     | Official -> ()
     | Atoms | Mixed ->
       let source_question={(message "selected atom") with name=Some "original speaker";
         metadata=["input_speaker",`String "first";"source_note",`String "second"]} in
       let messages=first @ [source_question;
         Agent_core.Types.make_message ~role:Agent_core.Types.Assistant
           [Agent_core.Types.ToolUse {id="source-call";name="read_file";input=`Assoc ["path",`String "source"]}];
         Agent_core.Types.make_message ~role:Agent_core.Types.Tool
           [Agent_core.Types.ToolResult {tool_use_id="source-call";content="source tool content";
             outcome=Agent_core.Types.Tool_succeeded;json=Some (`Assoc ["raw",`Null;"raw",`String "ordered duplicate"]);content_blocks=Some []}]] in
       save_checkpoint config ~trace_id messages 3;
       atom_boundary config ~trace_id ~turn:3 ~time:(now+.4.)
         ~history_at_start:(B.history_at_start_of_messages first) messages);
    let item : Keeper_external_attention.item =
      {event_id=Keeper_external_attention.event_id_of_dedupe_key "original-counterpart";
       dedupe_key="original-counterpart";keeper_name;conversation={conversation_id="agent:original";surface=Keeper_external_attention.Agent};
       external_message=None;source_label="agent";actor={actor_id=Some "external";display_name=Some "External";
         authority=Keeper_chat_store.External};urgency=Keeper_external_attention.Ambient;
       content_preview="retain the external original";content_ref=None;received_at=now-.2.;metadata=["raw","retained"]} in
    (match Keeper_external_attention.For_testing.record_with_clock ~now:(fun () -> now-.2.) ~base_path item with
     | `Recorded -> () | `Duplicate _ -> fail "duplicate original fixture" | `Error detail -> fail detail);
    Keeper_chat_store.append_user_message ~base_dir:base_path ~keeper_name ~content:"retain the direct chat original"
      ~speaker:{speaker_id=Some "owner";speaker_name=Some "Owner";speaker_authority=Keeper_chat_store.Owner} ();
    let captured=ref None in
    (match Consumer.consume_one ~config ~keeper_name ~commit:(fun original ->
       captured:=Some original;Consumer.Memory_pending) with
     | Ok Consumer.Pending -> ()
     | Ok _ -> fail "actual original commit edge did not suspend"
     | Error error -> fail (Consumer.error_to_string error));
    let original=match !captured with Some original -> original | None -> fail "no original reached the real commit edge" in
    f config trace_id original)

let restore_from_disk config original =
  let path=Filename.concat config.Workspace.base_path "retained-durable-original.json" in
  let canonical=Lane_addon_action.canonical (Capture.to_json original) |> get in
  Fs_compat.save_file_atomic_strict path (Yojson.Safe.to_string canonical) |> get;
  Capture.of_json (Fs_compat.load_file path |> Yojson.Safe.from_string)
    |> Result.map_error Capture.error_to_string |> get
let check_roundtrip kind () = with_fixture kind @@ fun config _ original ->
  let restored=restore_from_disk config original in
  check bool "complete original typed input survives actual disk retention" true
    (Capture.input original=Capture.input restored);
  check bool "both original receipts and all cursor roles survive" true
    (Capture.range_id original=Capture.range_id restored
     && Capture.official_range_id original=Capture.official_range_id restored
     && Capture.positions original=Capture.positions restored);
  check int "both raw counterpart stores contribute to the original input" 2
    (List.length (Capture.input restored).counterpart_observations);
  check bool "strict complete original data is stable" true (Capture.to_json original=Capture.to_json restored);
  let check_checkpoint checkpoint =
    check bool "exact checkpoint bytes name the original reference" true
      (Keeper_checkpoint_ref.sha256_of_canonical_bytes checkpoint.Capture.canonical_bytes=checkpoint.reference.sha256);
    check bool "the complete source includes the prior read prefix" true
      ((List.hd checkpoint.messages).Agent_core.Types.content=[Agent_core.Types.Text "already read"]);
    let user=List.find (fun (message:Agent_core.Types.message) -> message.name=Some "original speaker") checkpoint.messages in
    check bool "complete ordered canonical metadata retained" true
      (user.metadata=["input_speaker",`String "first";"source_note",`String "second"]) in
  let check_official official =
    check int "one original official trace" 1 (List.length official.Capture.traces);
    let trace=List.hd official.traces in
    check bool "Main rows remain separately numbered" true (trace.main<>[]);
    check bool "Internal rows remain separately numbered" true (trace.internal<>[]);
    check int "actual internal host tool observation retained" 1
      (List.length (List.filter (function _,Ok (F.Fragment (F.Tool_observation _)) -> true | _ -> false) trace.internal)) in
  match kind,Capture.source restored with
  | Atoms,Capture.Checkpoint_only checkpoint -> check_checkpoint checkpoint
  | Official,Capture.Official_only official -> check_official official
  | Mixed,Capture.Mixed (checkpoint,official) -> check_checkpoint checkpoint;check_official official
  | _ -> fail "restoration changed the original source kind"
let expect_refusal json = match Capture.of_json json with Error _ -> () | Ok _ -> fail "inconsistent original was accepted"
let map_field key transform = function
  | `Assoc fields -> `Assoc (List.map (fun (name,value) -> name,if name=key then transform value else value) fields)
  | _ -> fail "fixture capture must be an object"
let map_json_text transform = function
  | `String raw -> `String (Yojson.Safe.to_string (transform (Yojson.Safe.from_string raw)))
  | _ -> fail "expected retained JSON text"
let test_tampered_original_is_refused () = with_fixture Mixed @@ fun _ _ original ->
  let json=Capture.to_json original in
  expect_refusal (map_field "input_text" (map_json_text (map_field "keeper_instructions" (fun _ -> `String "changed"))) json
    |> map_field "range_id" (fun _ -> `Null));
  expect_refusal (map_field "input_text" (map_json_text (map_field "messages" (fun _ -> `List []))) json);
  expect_refusal (map_field "official_range_id" (fun _ -> `Null) json);
  expect_refusal (map_field "source_text" (map_json_text (function `List [`String "mixed";checkpoint;official] ->
    `List [`String "mixed";map_field "canonical_bytes" (fun _ -> `String "{}") checkpoint;official]
    | _ -> fail "expected mixed fixture")) json);
  expect_refusal (match json with `Assoc fields -> `Assoc (("schema",`Int 1)::fields) | _ -> fail "object");
  expect_refusal (match json with `Assoc fields -> `Assoc (("extra",`Null)::fields) | _ -> fail "object")
let test_matching_source_and_input_cannot_disagree_with_checkpoint_bytes () =
  with_fixture Atoms @@ fun _ _ original ->
  let tamper change =
    let messages values=match values with
      | `List rows -> `List (List.map (fun json ->
          let message=Keeper_librarian_input_capture.message_of_json json |> get in
          Keeper_librarian_input_capture.message_json (change message)) rows)
      | _ -> fail "expected complete captured messages" in
    let changed=Capture.to_json original
      |> map_field "input_text" (map_json_text (map_field "messages" messages))
      |> map_field "source_text" (map_json_text (function
        | `List [`String "checkpoint";checkpoint] ->
          `List [`String "checkpoint";map_field "messages" messages checkpoint]
        | _ -> fail "expected checkpoint source")) in
    expect_refusal changed in
  tamper (fun (message:Agent_core.Types.message) ->
    if message.name=Some "original speaker" then
      {message with content=[Agent_core.Types.Text "replaced selected atom"]} else message);
  tamper (fun (message:Agent_core.Types.message) ->
    {message with content=List.map (function
      | Agent_core.Types.ToolResult value -> Agent_core.Types.ToolResult {value with content="replaced tool payload"}
      | (Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _ | Image _ | Document _ | Audio _) as block ->
        block) message.content})
let test_richer_producer_snapshot_retains_complete_tool_json () =
  (* Complete message data can retain duplicate metadata, although the canonical
     checkpoint codec rejects it. Keep that data-codec claim separate from the
     actual checkpoint fixture and its persisted-field consistency check. *)
  let raw_message={(message "raw source data") with
    metadata=["input_speaker",`String "first";"input_speaker",`String "second"]} in
  let restored_message=Keeper_librarian_input_capture.message_json raw_message
    |> Yojson.Safe.to_string |> Yojson.Safe.from_string
    |> Keeper_librarian_input_capture.message_of_json |> get in
  check bool "complete message data codec retains duplicate ordered metadata" true
    (raw_message=restored_message);
  with_fixture Atoms @@ fun config trace_id original ->
  let old=match Capture.source original with Capture.Checkpoint_only value -> value
    | Official_only _ | Mixed _ -> fail "expected checkpoint fixture" in
  let payload=`Assoc ["raw",`Null;"raw",`String "ordered duplicate"] in
  let messages=List.map (fun (message:Agent_core.Types.message) ->
    {message with content=List.map (function
      | Agent_core.Types.ToolResult value -> Agent_core.Types.ToolResult {value with json=Some payload}
      | (Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _ | Image _ | Document _ | Audio _) as block -> block)
      message.content}) old.messages in
  (* The producer-value snapshot port intentionally retains richer data than
     its canonical checkpoint codec. This is data restoration, not a live lock. *)
  let snapshot=C.exact_snapshot_of_value ~expected_session_id:old.reference.trace_id
    (checkpoint ~trace_id messages old.reference.turn_count)
    |> Result.map_error C.checkpoint_ref_load_error_to_string |> get in
  let source=Capture.Checkpoint_only (Capture.checkpoint ~snapshot ~range:old.range
    ~boundary_lines_seen:old.boundary_lines_seen ~end_boundary_line:old.end_boundary_line) in
  let projection=Capture.project_source ~boundaries:(Capture.boundaries original) source
    |> Result.map_error Capture.error_to_string |> get in
  let input={(Capture.input original) with messages=projection.messages;
    tool_observations=projection.tool_observations;historical_task_contexts=projection.historical_task_contexts} in
  let richer=Capture.create ~runtime_keepers_dir:(Capture.runtime_keepers_dir original)
    ~extent:(Capture.extent original) ~boundaries:(Capture.boundaries original) ~positions:(Capture.positions original)
    ~source ~counterparts:(Capture.counterparts original) ~external_before:(Capture.external_before original)
    ~external_prepared:(Capture.external_prepared original) ~expected_revision:(Capture.expected_revision original)
    ~range_id:(Capture.range_id original) ~official_range_id:(Capture.official_range_id original) input
    |> Result.map_error Capture.error_to_string |> get in
  let restored=restore_from_disk config richer in
  check bool "complete producer ToolResult JSON survives persisted-field consistency check" true
    (List.exists (fun (message:Agent_core.Types.message) -> List.exists (function
      | Agent_core.Types.ToolResult {json;_} -> json=Some payload
      | Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _ | Image _ | Document _ | Audio _ -> false)
      message.content) (Capture.input restored).messages)
let test_source_changes_do_not_replace_the_original () = with_fixture Mixed @@ fun config trace_id original ->
  let retained=Capture.to_json original in
  let runtime_keepers_dir=Workspace.keepers_runtime_dir config in
  let atom_before=P.read ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name in
  let official_before=Keeper_librarian_official_progress.read ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name in
  let session_dir=Keeper_fs.keeper_session_dir config trace_id in
  let checkpoint_path=C.agent_core_checkpoint_path ~session_dir ~session_id:trace_id in
  Fs_compat.save_file_atomic_strict checkpoint_path "{}" |> get;
  Fs_compat.save_file_atomic_strict (F.path ~session_dir F.Main) "replaced source\n" |> get;
  Fs_compat.save_file_atomic_strict (F.path ~session_dir F.Internal) "replaced internal source\n" |> get;
  B.append ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name
    {B.recorded_at=Time_compat.now ();event=B.History_restarted {trace_id}} |> Result.map_error B.append_error_to_string |> get;
  let restored=restore_from_disk config original in
  check bool "disk restoration retains the original without consulting replaced sources" true
    (retained=Capture.to_json restored);
  check bool "original immutable observation does not advance the actual cursor" true
    (P.read ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name=atom_before
     && Keeper_librarian_official_progress.read ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name=official_before)
let () = Alcotest.run "durable source original capture" ["actual source retention",[
  test_case "checkpoint original survives strict disk roundtrip" `Quick (check_roundtrip Atoms);
  test_case "official Main and Internal originals survive strict disk roundtrip" `Quick (check_roundtrip Official);
  test_case "mixed original preserves source order and both receipt kinds" `Quick (check_roundtrip Mixed);
  test_case "changed source bodies receipts and malformed envelopes refuse" `Quick test_tampered_original_is_refused;
  test_case "source and input tampering cannot contradict canonical checkpoint bytes" `Quick
    test_matching_source_and_input_cannot_disagree_with_checkpoint_bytes;
  test_case "producer snapshot richer ToolResult JSON survives strict data restoration" `Quick
    test_richer_producer_snapshot_retains_complete_tool_json;
  test_case "later source replacement and restart cannot substitute a retained original" `Quick test_source_changes_do_not_replace_the_original]]
