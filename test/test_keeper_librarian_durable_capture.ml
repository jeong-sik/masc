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
    C.save_agent_core_classified ~boundary:Agent_core.Checkpoint_objects.Turn_closes
      ~session_dir
      ~history_retained:0
      (checkpoint ~trace_id messages turn_count)
  with
  | Ok (C.Saved _) -> ()
  | Ok (C.Stale_noop _) -> fail "fixture checkpoint was stale"
  | Error detail -> failf "save checkpoint: %s" detail
;;

let append_record config record =
  B.append ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name record
  |> Result.map_error B.append_error_to_string |> get
let append config ~trace_id ~turn ~time ~history_at_start position =
  append_record config {B.recorded_at=time;event=B.Turn_ended {turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:turn;
    task_context=Keeper_turn_task_context.No_task;history_at_start;position}}
let atom_boundary config ~trace_id ~turn ~time ~history_at_start messages =
  append config ~trace_id ~turn ~time ~history_at_start (B.position_of_messages messages |> get)
let append_raw path line =
  match Fs_compat.append_private_jsonl_durable_locked_result path line with
  | Fs_compat.Private_file_succeeded () | Private_file_succeeded_with_cleanup_failure _ -> ()
  | Private_file_failed _ | Private_file_failed_with_cleanup_failure _ -> fail "fixture could not write a refused line"
let meta config trace_id =
  let meta=Masc_test_deps.meta_of_json_fixture (`Assoc ["name",`String keeper_name;"trace_id",`String trace_id]) |> get in
  Keeper_meta_store.replace_snapshot config meta |> get
let session config trace_id =
  Keeper_context_core.create_session ~session_id:trace_id ~base_dir:(Keeper_fs.session_store_path config)
let official_row config ~trace_id ~turn text =
  Keeper_context_core_history.persist_message ~keeper_name ~turn_ref:(Ids.Turn_ref.make ~trace_id ~absolute_turn:turn)
    ~source:"direct_user" (session config trace_id) (message text)
let official_turn config ~trace_id ~turn ~time =
  let turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:turn in
  let session=session config trace_id in
  Keeper_context_core_history.persist_message ~keeper_name ~turn_ref ~source:"direct_user" session (message "official main");
  Keeper_context_core_history.persist_message ~keeper_name ~turn_ref ~source:"internal_assistant" session
    (Agent_core.Types.make_message ~role:Agent_core.Types.Assistant [Agent_core.Types.Text "official internal"]);
  Keeper_context_core_history.persist_tool_observation ~keeper_name ~turn_ref session ~tool_name:"read_file"
    ~outcome:Tool_result.Ok;
  append config ~trace_id ~turn ~time ~history_at_start:B.Continued_history B.No_atom_history

(* Every source also holds elements the pass does not read: a checkpoint
   message of a turn still running, official rows of other turns, a boundary
   line of another trace, and in [Mixed] a refused first official row. *)
type fixture_kind = Atoms | Official | Mixed
let with_fixture ?(refused_boundary=false) kind f =
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
    let session_dir=Keeper_fs.keeper_session_dir config trace_id in
    (* A refused line before a restart of this trace never stops a round. *)
    if refused_boundary then
      append_raw (B.path_for_keepers_dir ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name)
        "{refused boundary\n";
    let first=[message "already read"] in
    (match kind with
     | Official -> ()
     | Atoms | Mixed ->
       save_checkpoint config ~trace_id first 1;
       (* A fresh history starts reading at atom zero, so that variant has no
          baseline round and reads both turns. *)
       atom_boundary config ~trace_id ~turn:1 ~time:(now-.10.)
         ~history_at_start:(if refused_boundary then B.Fresh_history else B.Continued_history) first;
       if not refused_boundary then
         (match Consumer.consume_one ~config ~keeper_name
            ~commit:(fun _ -> fail "baseline must not request a Memory commit") with
          | Ok (Consumer.Baseline_advanced _) -> ()
          | Ok _ -> fail "fixture baseline did not advance"
          | Error error -> fail (Consumer.error_to_string error)));
    (* A refused row before the first named row of a file does not stop a round. *)
    (match kind with Mixed -> append_raw (F.path ~session_dir F.Main) "{refused official\n" | Atoms | Official -> ());
    (match kind with
     | Official | Mixed ->
       official_row config ~trace_id ~turn:1 "earlier official";
       official_turn config ~trace_id ~turn:2 ~time:(now+.2.);
       official_row config ~trace_id ~turn:9 "later official"
     | Atoms -> ());
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
       save_checkpoint config ~trace_id (messages @ [message "in flight"]) 3;
       atom_boundary config ~trace_id ~turn:3 ~time:(now+.4.)
         ~history_at_start:(B.history_at_start_of_messages first) messages);
    append_record config {B.recorded_at=now+.5.;event=B.History_restarted {trace_id="another-trace"}};
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

type live = {boundaries:Capture.boundary_lines;messages:Agent_core.Types.message list option;
  traces:Capture.official_trace list}
let read_live config trace_id =
  let session_dir=Keeper_fs.keeper_session_dir config trace_id in
  {boundaries=B.read ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name |> get;
   messages=Result.to_option (C.with_agent_core_exact_snapshot ~session_dir ~session_id:trace_id C.exact_snapshot_messages);
   traces=[{Capture.trace_id;main=F.read ~session_dir F.Main |> get;internal=F.read ~session_dir F.Internal |> get}]}
let confirm live original =
  Capture.confirm_sources ~boundaries:live.boundaries ~messages:live.messages ~traces:live.traces original
  |> Result.map_error Capture.error_to_string
let expect_confirmed label live original =
  match confirm live original with Ok () -> () | Error detail -> failf "%s: %s" label detail
let expect_unconfirmed label live original =
  match confirm live original with Error _ -> () | Ok () -> failf "%s was confirmed" label

let restore_from_disk config original =
  let path=Filename.concat config.Workspace.base_path "retained-durable-original.json" in
  let canonical=Lane_addon_action.canonical (Capture.to_json original) |> get in
  Fs_compat.save_file_atomic_strict path (Yojson.Safe.to_string canonical) |> get;
  Capture.of_json (Fs_compat.load_file path |> Yojson.Safe.from_string)
    |> Result.map_error Capture.error_to_string |> get
let contains text sub =
  let length=String.length sub in
  let rec scan index = index+length<=String.length text
    && (String.sub text index length=sub || scan (index+1)) in
  scan 0
let has_text text (message:Agent_core.Types.message) = List.mem (Agent_core.Types.Text text) message.content

let check_roundtrip kind () = with_fixture kind @@ fun config trace_id original ->
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
  let retained=Yojson.Safe.to_string (Capture.to_json restored) in
  List.iter (fun unread -> check bool ("the original does not hold unread " ^ unread) false (contains retained unread))
    ["already read";"in flight";"earlier official";"later official"];
  expect_confirmed "a restored original against its unchanged sources" (read_live config trace_id) restored;
  let check_checkpoint (checkpoint:Capture.Held.checkpoint) =
    check int "the span counts every checkpoint message the capture saw" 5 checkpoint.messages.count;
    check bool "the input holds the selected atom" true
      (List.exists (has_text "selected atom") (Capture.input restored).messages) in
  let check_official (official:Capture.Held.official) =
    check int "one original official trace" 1 (List.length official.traces);
    let trace=List.hd official.traces in
    check bool "Main and Internal rows are counted separately" true (trace.main.count>0 && trace.internal.count>0);
    check bool "the input holds the selected official turn" true
      (List.exists (has_text "official main") (Capture.input restored).messages) in
  match kind,Capture.source restored with
  | Atoms,Capture.Held.Checkpoint_only checkpoint -> check_checkpoint checkpoint
  | Official,Capture.Held.Official_only official -> check_official official
  | Mixed,Capture.Held.Mixed (checkpoint,official) -> check_checkpoint checkpoint;check_official official
  | (Atoms | Official | Mixed),(Capture.Held.Checkpoint_only _ | Official_only _ | Mixed _) ->
    fail "restoration changed the original source kind"

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
  expect_refusal (map_field "official_range_id" (fun _ -> `Null) json);
  expect_refusal (map_field "boundaries" (map_field "digest" (fun _ -> `String "not a digest")) json);
  expect_refusal (map_field "source_text" (map_json_text (function `List [`String "mixed";checkpoint;official] ->
    `List [`String "mixed";map_field "messages" (map_field "count" (fun _ -> `Int (-1))) checkpoint;official]
    | _ -> fail "expected mixed fixture")) json);
  expect_refusal (map_field "schema" (fun _ -> `Int 1) json);
  expect_refusal (match json with `Assoc fields -> `Assoc (("schema",`Int 2)::fields) | _ -> fail "object");
  expect_refusal (match json with `Assoc fields -> `Assoc (("extra",`Null)::fields) | _ -> fail "object")

let change_at index change rows = List.mapi (fun at row -> if at=index then change row else row) rows
let index_where label predicate rows =
  let rec find index = function
    | [] -> failf "fixture has no %s" label
    | row::rest -> if predicate row then index else find (index+1) rest in
  find 0 rows
let changed_message (message:Agent_core.Types.message) = {message with content=[Agent_core.Types.Text "changed"]}
let later_boundary = function
  | line,Ok (record:B.record) -> line,Ok {record with recorded_at=record.recorded_at+.1.}
  | _,Error _ -> fail "expected a readable boundary line"
let turn_line turn = function
  | _,Ok {B.event=B.Turn_ended {turn_ref;_};_} -> Ids.Turn_ref.absolute_turn turn_ref=turn
  | _,Ok {B.event=B.History_restarted _;_} | _,Error _ -> false
let official_text text = function
  | _,Ok (F.Fragment (F.Message {message;_})) -> has_text text message
  | _,Ok (F.Fragment (F.Tool_observation _)) | _,Ok F.Untagged | _,Error _ -> false
let changed_official_row = function
  | line,Ok (F.Fragment (F.Message fragment)) ->
    line,Ok (F.Fragment (F.Message {fragment with message=changed_message fragment.message}))
  | _,(Ok (F.Fragment (F.Tool_observation _) | F.Untagged) | Error _) -> fail "expected an official message row"

let test_every_element_the_capture_saw_is_bound () = with_fixture Mixed @@ fun config trace_id original ->
  let live=read_live config trace_id in
  expect_confirmed "unchanged sources" live original;
  let messages=Option.get live.messages in
  List.iter (fun (label,text) ->
    let index=index_where label (has_text text) messages in
    expect_unconfirmed label {live with messages=Some (change_at index changed_message messages)} original)
    ["a checkpoint message before the range","already read";"a checkpoint message in the range","selected atom";
     "a checkpoint message after the range","in flight"];
  List.iter (fun (label,select) ->
    let index=index_where label select live.boundaries in
    expect_unconfirmed label {live with boundaries=change_at index later_boundary live.boundaries} original)
    ["a boundary line before the range",turn_line 1;"a boundary line in the range",turn_line 3;
     "a boundary line after the range",(function _,Ok {B.event=B.History_restarted {trace_id};_} -> trace_id="another-trace"
       | _,Ok {B.event=B.Turn_ended _;_} | _,Error _ -> false)];
  let trace=List.hd live.traces in
  List.iter (fun (label,text) ->
    let index=index_where label (official_text text) trace.main in
    expect_unconfirmed label {live with traces=[{trace with main=change_at index changed_official_row trace.main}]} original)
    ["an official row before the turn","earlier official";"an official row of the turn","official main";
     "an official row after the turn","later official"];
  expect_unconfirmed "a source shorter than the capture saw"
    {live with messages=Some (List.filteri (fun index _ -> index<List.length messages-1) messages)} original;
  let grown={boundaries=live.boundaries @ [List.length live.boundaries+1,
      Ok {B.recorded_at=Time_compat.now ();event=B.History_restarted {trace_id="yet-another-trace"}}];
    messages=Some (messages @ [message "appended later"]);
    traces=[{trace with main=trace.main @ [List.length trace.main+1,Ok F.Untagged]}]} in
  expect_confirmed "appended history" grown original

let test_a_refused_row_that_turns_readable_is_bound () =
  with_fixture Mixed (fun config trace_id original ->
    let live=read_live config trace_id in
    let trace=List.hd live.traces in
    let index=index_where "a refused official row" (function _,Error _ -> true | _,Ok _ -> false) trace.main in
    expect_confirmed "unchanged sources" live original;
    expect_unconfirmed "a refused official row read as an untagged row"
      {live with traces=[{trace with main=change_at index (fun (line,_) -> line,Ok F.Untagged) trace.main}]} original);
  with_fixture ~refused_boundary:true Atoms (fun config trace_id original ->
    let live=read_live config trace_id in
    let index=index_where "a refused boundary line" (function _,Error _ -> true | _,Ok _ -> false) live.boundaries in
    expect_confirmed "unchanged sources" live original;
    expect_unconfirmed "a refused boundary line read as a restart of another trace"
      {live with boundaries=change_at index (fun (line,_) ->
        line,Ok {B.recorded_at=0.;event=B.History_restarted {trace_id="another-trace"}}) live.boundaries} original)

let tamper_input change original =
  Capture.to_json original |> map_field "input_text" (map_json_text (map_field "messages" (function
    | `List rows -> `List (List.map (fun json ->
        Keeper_librarian_input_capture.message_json (change (Keeper_librarian_input_capture.message_of_json json |> get))) rows)
    | _ -> fail "expected captured messages")))
let test_a_changed_range_is_never_confirmed () = with_fixture Atoms @@ fun config trace_id original ->
  let live=read_live config trace_id in
  let never_confirmed label change =
    match Capture.of_json (tamper_input change original) with
    | Error _ -> ()
    | Ok restored -> expect_unconfirmed label live restored in
  never_confirmed "a replaced selected atom" (fun (message:Agent_core.Types.message) ->
    if message.name=Some "original speaker" then
      {message with content=[Agent_core.Types.Text "replaced selected atom"]} else message);
  never_confirmed "a replaced tool payload" (fun (message:Agent_core.Types.message) ->
    {message with content=List.map (function
      | Agent_core.Types.ToolResult value -> Agent_core.Types.ToolResult {value with content="replaced tool payload"}
      | (Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _ | Image _ | Document _ | Audio _) as block ->
        block) message.content});
  never_confirmed "a changed origin" (fun (message:Agent_core.Types.message) ->
    {message with origin=Agent_core.Types.System_context})

let test_richer_producer_snapshot_retains_complete_tool_json () =
  (* Complete message data can retain duplicate metadata, although the canonical
     checkpoint codec rejects it. Keep that data-codec claim separate from the
     actual checkpoint fixture. *)
  let raw_message={(message "raw source data") with
    metadata=["input_speaker",`String "first";"input_speaker",`String "second"]} in
  let restored_message=Keeper_librarian_input_capture.message_json raw_message
    |> Yojson.Safe.to_string |> Yojson.Safe.from_string
    |> Keeper_librarian_input_capture.message_of_json |> get in
  check bool "complete message data codec retains duplicate ordered metadata" true
    (raw_message=restored_message);
  with_fixture Atoms @@ fun config trace_id original ->
  let live=read_live config trace_id in
  let old=match Capture.source original with Capture.Held.Checkpoint_only value -> value
    | Official_only _ | Mixed _ -> fail "expected checkpoint fixture" in
  let payload=`Assoc ["raw",`Null;"raw",`String "ordered duplicate"] in
  let messages=List.map (fun (message:Agent_core.Types.message) ->
    {message with content=List.map (function
      | Agent_core.Types.ToolResult value -> Agent_core.Types.ToolResult {value with json=Some payload}
      | (Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _ | Image _ | Document _ | Audio _) as block -> block)
      message.content}) (Option.get live.messages) in
  (* The producer-value snapshot port retains richer data than its canonical
     checkpoint codec; the live checkpoint read from disk does not. *)
  let snapshot=C.exact_snapshot_of_value ~expected_session_id:old.trace_id
    (checkpoint ~trace_id messages 3)
    |> Result.map_error C.checkpoint_ref_load_error_to_string |> get in
  let source=Capture.Checkpoint_only (Capture.checkpoint ~snapshot ~range:old.range
    ~boundary_lines_seen:old.boundary_lines_seen ~end_boundary_line:old.end_boundary_line) in
  let projection=Capture.project_source ~boundaries:live.boundaries source
    |> Result.map_error Capture.error_to_string |> get in
  let input={(Capture.input original) with messages=projection.messages;
    tool_observations=projection.tool_observations;historical_task_contexts=projection.historical_task_contexts} in
  let richer=Capture.create ~runtime_keepers_dir:(Capture.runtime_keepers_dir original)
    ~extent:(Capture.extent original) ~boundaries:live.boundaries ~positions:(Capture.positions original)
    ~source ~counterparts:(Capture.counterparts original) ~external_before:(Capture.external_before original)
    ~external_prepared:(Capture.external_prepared original) ~expected_revision:(Capture.expected_revision original)
    ~range_id:(Capture.range_id original) ~official_range_id:(Capture.official_range_id original) input
    |> Result.map_error Capture.error_to_string |> get in
  let restored=restore_from_disk config richer in
  check bool "complete producer ToolResult JSON survives disk retention" true
    (List.exists (fun (message:Agent_core.Types.message) -> List.exists (function
      | Agent_core.Types.ToolResult {json;_} -> json=Some payload
      | Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _ | Image _ | Document _ | Audio _ -> false)
      message.content) (Capture.input restored).messages);
  expect_confirmed "the richer original against the checkpoint read from disk" live restored

let test_source_changes_do_not_replace_the_original () = with_fixture Mixed @@ fun config trace_id original ->
  let retained=Capture.to_json original in
  let before=read_live config trace_id in
  let runtime_keepers_dir=Workspace.keepers_runtime_dir config in
  let atom_before=P.read ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name in
  let official_before=Keeper_librarian_official_progress.read ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name in
  let session_dir=Keeper_fs.keeper_session_dir config trace_id in
  let checkpoint_path=C.agent_core_checkpoint_path ~session_dir ~session_id:trace_id in
  Fs_compat.save_file_atomic_strict checkpoint_path "{}" |> get;
  Fs_compat.save_file_atomic_strict (F.path ~session_dir F.Main) "replaced source\n" |> get;
  Fs_compat.save_file_atomic_strict (F.path ~session_dir F.Internal) "replaced internal source\n" |> get;
  append_record config {B.recorded_at=Time_compat.now ();event=B.History_restarted {trace_id}};
  let restored=restore_from_disk config original in
  check bool "disk restoration retains the original without consulting replaced sources" true
    (retained=Capture.to_json restored);
  check bool "original immutable observation does not advance the actual cursor" true
    (P.read ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name=atom_before
     && Keeper_librarian_official_progress.read ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name=official_before);
  let after=read_live config trace_id in
  check bool "the replaced checkpoint no longer loads" true (after.messages=None);
  expect_unconfirmed "replaced official files" {after with messages=before.messages} restored

let () = Alcotest.run "durable source original capture" ["actual source retention",[
  test_case "checkpoint original survives strict disk roundtrip" `Quick (check_roundtrip Atoms);
  test_case "official Main and Internal originals survive strict disk roundtrip" `Quick (check_roundtrip Official);
  test_case "mixed original preserves source order and both receipt kinds" `Quick (check_roundtrip Mixed);
  test_case "changed receipts spans and malformed envelopes refuse" `Quick test_tampered_original_is_refused;
  test_case "every element the capture saw is bound before, in and after the range" `Quick
    test_every_element_the_capture_saw_is_bound;
  test_case "a refused row that turns readable is bound" `Quick test_a_refused_row_that_turns_readable_is_bound;
  test_case "a changed range is never confirmed against its sources" `Quick test_a_changed_range_is_never_confirmed;
  test_case "producer snapshot richer ToolResult JSON confirms against the disk checkpoint" `Quick
    test_richer_producer_snapshot_retains_complete_tool_json;
  test_case "later source replacement cannot substitute a retained original" `Quick
    test_source_changes_do_not_replace_the_original]]
