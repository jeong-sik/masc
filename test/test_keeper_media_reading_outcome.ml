(** Source ports and retained-host carriers. Guest recipes are prepared only;
    these cases do not claim MCP, process, or remote execution. *)
open Alcotest
open Masc
module M = Keeper_media_reading
module Original = Keeper_media_reading_original
module Outbox = Keeper_client_tool_outbox
module H = Agent_core.History

let get show = function Ok value -> value | Error error -> fail (show error)
let strings value = get Fun.id value
let keeper = "media-outcome-fixture"
let mime = "application/pdf"
let raw = "original attachment bytes"
let identity = get (function M.Empty_id -> "id" | M.Empty_revision -> "revision")
    (M.reader_identity ~id:"fixture" ~revision:"v1")

let with_fixture f =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let base = Unix.realpath (Filename.temp_dir "media-outcome-" "") in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base);
  let media = Tool_blob_media_store.of_base_path ~base_path:base in
  let stored = get H.show_media_error (media.put ~media_type:mime ~raw) in
  f base media stored

let captured base media stored execution_id =
  let endpoint = Keeper_sandbox_remote.of_agent_socket
      ~base_path:base ~keeper_name:keeper ~remote_root:"/workspace"
      ~gh_config_dir:"/workspace/.config/gh" ~injected_env:[] ~env_allowlist:[]
      ~connect_timeout_sec:1 ~max_concurrent_sessions:1 ~container_name:"media-fixture"
      ~shim_path:"/usr/local/bin/masc-exec-shim"
      ~host_socket:(Filename.concat base "never-connected.sock")
      ~expected:{Keeper_guest_socket.uid=Unix.getuid ();gid=Unix.getgid ()} in
  let declaration : Runtime_schema.media_reader_decl =
    { id="fixture";revision="v1";kind=Document;media_types=[mime];adapter=Markitdown_mcp;
      command="reader";args=[] } in
  let request = get (fun _ -> "fixture preparation failed")
      (Keeper_sandbox_remote.Stdio_request.prepare ~timeout_sec:10. endpoint
        ~argv:[declaration.command] ~env:[||] ~cwd:None) in
  let launch = get (fun _ -> "fixture binding failed")
      (Keeper_sandbox_remote.Stdio_request.binding request ~base_path:base
        ~keeper_name:keeper ~expected_argv:[declaration.command]) in
  let own = get Original.error_to_string
      (Original.observe_owner ~base_path:base ~keeper_name:keeper) in
  let subject = get Original.error_to_string
      (Original.subject own ~kind:Document ~media_type:mime stored) in
  let source = get Original.error_to_string (Original.verify_source ~media_store:media subject) in
  get Original.error_to_string (Original.create ~execution_id ~source ~declaration ~launch
    ~causal_context:None ~task_id:None
    ~continuation_channel:(Keeper_continuation_channel.unrouted "fixture"))

let builtin ~media ~source_reader ~selections ~reads =
  M.projector ~media_store:media ~keeper_name:keeper ~source_reader
    ~resolve:(fun ~kind:_ ~media_type:_ ->
      incr selections;
      Ok (M.reader ~identity ~read:(fun ~bytes:_ -> incr reads; Ok "builtin text"))) ()

let test_owner_observation_precedes_cached_selection () = with_fixture (fun _base media stored ->
  let current = ref M.Use_builtin and observations = ref 0 in
  let selections = ref 0 and reads = ref 0 in
  let projector = builtin ~media ~selections ~reads
      ~source_reader:(fun ~kind:_ ~media_type:_ _ -> incr observations; !current) in
  let read () = M.read_stored projector ~kind:Document ~media_type:mime stored in
  (match read () with
   | M.Read _ -> ()
   | M.Pending _ | M.Unavailable _ -> fail "initial builtin reading failed");
  current := M.Owned (M.Unavailable (M.External_failed M.Declarations_unavailable));
  (match read () with
   | M.Unavailable failure -> check bool "current owned failure remains typed" true
       (failure = M.External_failed M.Declarations_unavailable)
   | M.Read _ | M.Pending _ -> fail "cached reading hid owner observation");
  check int "every call observes current originals" 2 !observations;
  check int "owned outcome bypasses selection" 1 !selections;
  check int "owned outcome bypasses extraction" 1 !reads)

let test_observe_and_effect_ports_are_distinct () = with_fixture (fun _base media stored ->
  let observations = ref 0 and effects = ref 0 in
  let selections = ref 0 and reads = ref 0 in
  let source_reader ~kind:_ ~media_type:_ _ =
    incr observations; M.Owned (M.Unavailable (M.External_failed M.Reader_not_started)) in
  let projector = builtin ~media ~source_reader ~selections ~reads in
  let blocks, _ = M.project projector ~needs_projection:(fun _ -> true)
      [Agent_core.Types.document_block ~media_type:mime ~source:(Agent_core.Types.Stored stored)] in
  check int "history only uses the observational port" 1 !observations;
  check int "history has not entered the effect port" 0 !effects;
  check bool "history carries explicit unavailable data" true
    (match blocks with
     | [block] ->
       (match (block : Agent_core.Types.content_block) with
        | Text text -> String_util.contains_substring text "reader_not_started"
        | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _
        | ToolResult _ | ToolReference _ | Image _ | Audio _ | Document _ -> false)
     | [] | _ :: _ :: _ -> false);
  let read_effect ~kind:_ ~media_type:_ _ =
    incr effects; M.Owned (M.Unavailable (M.External_failed (M.Approval_rejected "approval"))) in
  ignore (M.read_stored ~source_reader:read_effect projector ~kind:Document ~media_type:mime stored);
  check int "only explicit retained preparation can invoke its effect port" 1 !effects;
  check int "neither owned path selects a builtin reader" 0 !selections;
  check int "neither owned path extracts bytes" 0 !reads)

let test_pending_carrier_keeps_all_originals_and_freezes_once () = with_fixture (fun base media stored ->
  let first = captured base media stored "media-pending-one" in
  let second = captured base media stored "media-pending-two" in
  let a = M.original_reference first and b = M.original_reference second in
  let pending = M.Pending
      ({original=a;disposition=Awaiting_approval "approval-a"},
       [{original=b;disposition=Awaiting_host_replay "approval-b"};
        {original=b;disposition=Outcome_unknown};
        {original=a;disposition=Ambiguous_approvals ["approval-c";"approval-d"]};
        {original=a;disposition=Known_approval_missing
          {approval_id="missing";matching_approval_ids=["approval-e"]}};
        {original=b;disposition=Known_approval_mismatch
          {approval_id="mismatch";matching_approval_ids=["approval-f";"approval-g"]}};
        {original=b;disposition=Approval_consumed "consumed"};
        {original=a;disposition=Rejected_approval {approval_id="rejected";reason="do not run"}};
        {original=a;disposition=Request_not_sent}]) in
  let producer = strings (Outbox.host_producer ~base_path:base ~keeper_name:keeper
      ~runtime_label:"fixture" ~turn_count:1) in
  let response = strings (Outbox.host_response producer ~min_result_bytes:max_int
      ~success:false ~content:"original host tool failed"
      ~content_blocks:(Some [Llm_provider.Types.Document
        {media_type=mime;source=Base64 (Base64.encode_string raw)}])) in
  strings (Outbox.retain_host_result producer ~invocation_index:0 ~call_id:"original-call"
    ~tool_name:"Read" ~arguments:(Outbox.Known (`Assoc [])) ~response);
  let calls = ref 0 and current = ref pending in
  let projector = M.projector ~media_store:media ~keeper_name:keeper
      ~resolve:(fun ~kind:_ ~media_type:_ -> fail "pending originals cannot select a reader") () in
  let read_media = Keeper_turn_driver.For_testing.retained_media_reader
      ~source_reader:(fun ~kind:_ ~media_type:_ _ -> incr calls; M.Owned !current)
      ~input_source:(Keeper_request_source.Keeper_history {trace_id="fixture"}) projector in
  let run = Outbox.run_carrier ~base_path:base ~keeper_name:keeper ~read_media
      ~artifact_reader_available:true ~viewer:Outbox.Unowned_only in
  let snapshot, carrier = strings (Outbox.run_carrier_load run) in
  let contexts = Outbox.carrier_context carrier in
  let rows = match List.rev contexts with
    | json :: _ -> Yojson.Safe.Util.(Yojson.Safe.from_string json
        |> member "retained_tool_result_readings" |> to_list)
    | [] -> fail "missing retained reading rows" in
  let row = match rows with [row] -> row | [] | _ :: _ :: _ -> fail "expected one original host attachment" in
  let open Yojson.Safe.Util in
  check string "host call identity is preserved" "original-call" (row |> member "call_id" |> to_string);
  check bool "the complete mixed pending outcome survives" true
    (Yojson.Safe.equal (M.outcome_to_json pending) (row |> member "reading"));
  let observations = row |> member "reading" |> member "observations" |> to_list in
  check (list string) "distinct approval IDs and unknown remain separate"
    ["approval-a";"approval-b";"missing";"mismatch";"consumed";"rejected"]
    (List.filter_map (fun value -> match value |> member "approval_id" with
       | `String id -> Some id
       | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _ -> None) observations);
  check (list (list string)) "ambiguous and mismatched approvals keep every matching ID"
    [["approval-c";"approval-d"];["approval-e"];["approval-f";"approval-g"]]
    (List.filter_map (fun value -> match value |> member "matching_approval_ids" with
       | `List ids -> Some (List.map to_string ids)
       | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ -> None) observations);
  check (list string) "unknown, denied, consumed and no-send remain distinct facts"
    ["awaiting_approval";"awaiting_host_replay";"outcome_unknown";
     "reconciliation_required";"reconciliation_required";"reconciliation_required";
     "approval_consumed";"approval_rejected";"request_not_sent"]
    (List.map (fun value -> value |> member "state" |> to_string) observations);
  current := M.Unavailable (M.External_failed M.Declarations_unavailable);
  let retry_snapshot, retry_carrier = strings (Outbox.run_carrier_load run) in
  check bool "same run keeps its exact carrier" true (retry_carrier == carrier);
  check bool "same run keeps its exact receipt snapshot" true (retry_snapshot == snapshot);
  check int "carrier retry never invokes the reader again" 1 !calls;
  check int "reading does not acknowledge the original host receipt" 1
    (List.length (Outbox.receipt_ids snapshot)))

let document ?(media_type=mime) source =
  Agent_core.Types.document_block ~media_type ~source:(Agent_core.Types.Stored source)

let nested_result ~text blocks : Agent_core.Types.content_block =
  ToolResult {tool_use_id="prepared-media-call";content=text;
    outcome=Tool_succeeded;json=Some (`Assoc ["original_result", `Bool true]);
    content_blocks=Some blocks}

let prepared_blocks prepared blocks =
  get M.preparation_error_to_string (M.project_prepared prepared blocks)

let test_prepared_pending_is_one_immutable_observation () = with_fixture (fun base media stored ->
  let original = captured base media stored "selected-pending" in
  let pending = M.Pending
      ({original=M.original_reference original;disposition=Awaiting_approval "first-approval"},
       [{original=M.original_reference original;
         disposition=Ambiguous_approvals ["second-approval";"third-approval"]}]) in
  let current = ref pending and effects = ref 0 and observations = ref 0 in
  let selections = ref 0 and reads = ref 0 in
  let projector = builtin ~media ~selections ~reads
      ~source_reader:(fun ~kind:_ ~media_type:_ _ -> incr observations; M.Use_builtin) in
  let stored_block = document stored in
  let nested = nested_result ~text:"original result" [stored_block] in
  let audio_selected = ref false in
  let prepared = M.prepare projector
      ~source_reader:(fun ~kind:_ ~media_type:_ _ -> incr effects; M.Owned !current)
      ~needs_projection:(function M.Document -> true | Audio -> !audio_selected)
      [[stored_block;nested];[stored_block]] in
  check int "one selected identity reaches its owner only once" 1 !effects;
  check int "explicit preparation uses the admitted port" 0 !observations;
  check int "pending originals bypass builtin selection" 0 !selections;
  current := M.Unavailable (M.External_failed M.Declarations_unavailable);
  audio_selected := true;
  let audio = Agent_core.Types.audio_block ~media_type:"audio/wav"
      ~source:(Agent_core.Types.Stored stored) in
  let input = [Agent_core.Types.Text "changed argument context";
    nested_result ~text:"materialized result marker" [stored_block];audio] in
  let first, counts = prepared_blocks prepared input in
  let second, _ = prepared_blocks prepared input in
  check bool "reconstruction reuses the complete captured pending outcome" true (first = second);
  check (list (pair string int)) "captured modality decisions stay fixed"
    ["document",1] counts;
  (match first with
   | [Agent_core.Types.Text "changed argument context"; ToolResult result; kept_audio] ->
     check string "result materialization is preserved" "materialized result marker" result.content;
     check string "tool identity stays with its media" "prepared-media-call" result.tool_use_id;
     check bool "tool outcome and JSON remain unchanged" true
       (result.outcome=Tool_succeeded && result.json=Some (`Assoc ["original_result",`Bool true]));
     check bool "unselected audio remains canonical" true (kept_audio=audio);
     (match result.content_blocks with
      | Some [Text text] -> check bool "all original and approval identities survive"
          true (String_util.contains_substring text (Yojson.Safe.to_string (M.outcome_to_json pending)))
      | _ -> fail "nested selected media was not projected")
   | _ -> fail "prepared projection changed the selected bundle structure");
  check int "pure reconstruction never invokes the owner again" 1 !effects;
  check int "pure reconstruction never reads a builtin source" 0 !reads)

let test_prepared_sources_use_complete_identity_and_refuse_new_sources () =
  with_fixture (fun _base media stored ->
    let other_length = get H.stored_error_to_string
        (H.stored ~sha256:stored.sha256 ~bytes:(stored.bytes+1)) in
    let other_digest = H.stored_of_raw "different selected source" in
    let document_block = document stored in
    let audio_block = Agent_core.Types.audio_block ~media_type:mime
        ~source:(Agent_core.Types.Stored stored) in
    let selected = [document_block; document ~media_type:"application/alternate" stored;
      document other_length; document other_digest; audio_block; document_block] in
    let calls = ref [] and current = ref (M.Unavailable (M.External_failed M.Reader_not_started)) in
    let projector = M.projector ~media_store:media ~keeper_name:keeper
        ~resolve:(fun ~kind:_ ~media_type:_ -> fail "owned unavailable results must not select a reader") () in
    let prepared = M.prepare projector ~needs_projection:(fun _ -> true)
        ~source_reader:(fun ~kind ~media_type source ->
          calls := (kind,media_type,source.H.sha256,source.bytes) :: !calls;
          M.Owned !current) [selected] in
    check int "kind, MIME, length and digest each distinguish a source" 5 (List.length !calls);
    current := M.Unavailable (M.External_failed M.Declarations_unavailable);
    let blocks, _ = prepared_blocks prepared selected in
    check bool "unavailable results keep their captured reason" true
      (List.for_all (function Agent_core.Types.Text text ->
        String_util.contains_substring text "reader_not_started"
        && not (String_util.contains_substring text "reader_declarations_unavailable")
        | _ -> false) blocks);
    let unseen = H.stored_of_raw "not selected in this request" in
    (match M.project_prepared prepared [document unseen] with
     | Error (M.Source_not_prepared {kind;media_type;source}) ->
       check bool "missing source remains typed and exact" true
         (kind=M.Document && media_type=mime && source=unseen)
     | Ok _ -> fail "an unprepared source entered the request");
    check int "an unprepared source does not invoke or retry any reader" 5 (List.length !calls))

let test_prepared_success_retains_original_request_reference () = with_fixture (fun base media stored ->
  let original = captured base media stored "selected-success" in
  let reading = get (fun _ -> "nonempty original reading required")
      (M.reading_of_original ~original ~text:"reading from retained SDK reply") in
  let current = ref (M.Read reading) and calls = ref 0 in
  let projector = M.projector ~media_store:media ~keeper_name:keeper
      ~source_reader:(fun ~kind:_ ~media_type:_ _ -> incr calls; M.Owned !current)
      ~resolve:(fun ~kind:_ ~media_type:_ -> fail "owned reading cannot select a builtin reader") () in
  let blocks = [document stored] in
  let prepared = M.prepare projector ~needs_projection:(fun _ -> true) [blocks] in
  let observed, _ = M.project projector ~needs_projection:(fun _ -> true) blocks in
  current := M.Unavailable (M.External_failed M.Declarations_unavailable);
  let frozen, _ = prepared_blocks prepared blocks in
  let again, _ = prepared_blocks prepared blocks in
  check bool "history and prepared history share the attributed representation" true
    (observed=frozen && frozen=again);
  let original_json = Yojson.Safe.Util.member "original_request" (M.outcome_to_json (M.Read reading)) in
  (match frozen with
   | [Agent_core.Types.Text text] ->
     check bool "history preserves request, original digest and execution reference" true
       (String_util.contains_substring text (Yojson.Safe.to_string original_json));
     check bool "history preserves the interpreted content" true
       (String_util.contains_substring text reading.text)
   | _ -> fail "prepared successful reading was not projected");
  check int "only preparation and explicit observation consult the owner" 2 !calls)

let () = run "keeper_media_reading_outcome"
  ["owner boundary",[
    test_case "owned observation precedes builtin memo" `Quick test_owner_observation_precedes_cached_selection;
    test_case "history observe and retained effect ports stay distinct" `Quick test_observe_and_effect_ports_are_distinct;
    test_case "mixed pending carrier retains identities and freezes once" `Quick
      test_pending_carrier_keeps_all_originals_and_freezes_once;
    test_case "selected pending outcome is immutable across reconstruction" `Quick
      test_prepared_pending_is_one_immutable_observation;
    test_case "prepared source identity and missing source are explicit" `Quick
      test_prepared_sources_use_complete_identity_and_refuse_new_sources;
    test_case "successful prepared history retains its original request" `Quick
      test_prepared_success_retains_original_request_reference]]
