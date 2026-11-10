(** Boot-time transcript tail recovery over persisted keepers. *)

open Alcotest
open Masc

module Recovery = Keeper_transcript_tail_recovery

let make_meta name =
  match Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String name ]) with
  | Ok meta -> meta
  | Error detail -> failf "keeper meta fixture failed: %s" detail
;;

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_workspace f =
  let root = Filename.temp_file "transcript-tail-" "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Workspace.default_config root in
  ignore (Workspace.init config ~agent_name:None);
  Fun.protect
    ~finally:(fun () ->
      ignore (Workspace.reset config);
      remove_tree root)
    (fun () -> f config)
;;

let checkpoint ~trace_id ~name ~turn_count messages : Agent_core.Checkpoint.t =
  { provider_binding = None; version = Agent_core.Checkpoint.checkpoint_version
  ; session_id = trace_id
  ; agent_name = name
  ; model = "fixture-model"
  ; system_prompt = None
  ; messages
  ; usage = Agent_core.Types.empty_usage
  ; turn_count
  ; created_at = 1.0
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
  ; pending_input = None
  ; mcp_sessions = []
  ; working_context = None
  }
;;

let text role value = Agent_core.Types.make_message ~role [ Agent_core.Types.Text value ]

let request id =
  Agent_core.Types.make_message
    ~role:Agent_core.Types.Assistant
    [ Agent_core.Types.ToolUse { id; name = "read_file"; input = `Assoc [] } ]
;;

let answer id =
  Agent_core.Types.make_message
    ~role:Agent_core.Types.Tool
    [ Agent_core.Types.ToolResult
        { tool_use_id = id
        ; content = "read"
        ; outcome = Agent_core.Types.Tool_succeeded
        ; json = None
        ; content_blocks = None
        }
    ]
;;

(* A persisted keeper with an empty session directory: its trace id and the
   directory. *)
let persisted_keeper config name =
  let meta = make_meta name in
  (match Keeper_meta_store.replace_snapshot config meta with
   | Ok () -> ()
   | Error detail -> failf "keeper meta persistence failed: %s" detail);
  let trace_id = Keeper_id.Trace_id.to_string meta.Keeper_meta_contract.runtime.trace_id in
  let session_dir = Filename.concat (Keeper_fs.session_base_dir config) trace_id in
  Unix.mkdir session_dir 0o700;
  trace_id, session_dir
;;

let save ~session_dir ~boundary checkpoint =
  match
    Keeper_checkpoint_store.save_agent_core_classified
      ~session_dir
      ~history_retained:0
      ~boundary
      checkpoint
  with
  | Ok (Keeper_checkpoint_store.Saved _) -> ()
  | Ok (Keeper_checkpoint_store.Stale_noop _) -> fail "the fixture save was stale"
  | Error detail -> failf "fixture save: %s" detail
;;

let canonical_bytes ~session_dir ~trace_id =
  In_channel.with_open_bin
    (Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:trace_id)
    In_channel.input_all
;;

(* Removes the bundle of the first closed turn the head names, so the history
   can no longer be read whole. *)
let remove_first_turn_bundle ~session_dir ~trace_id =
  (match
     Agent_core.Checkpoint_objects.head_of_string (canonical_bytes ~session_dir ~trace_id)
   with
   | Error error -> fail (Agent_core.Checkpoint_objects.load_error_to_string error)
   | Ok (head : Agent_core.Checkpoint_objects.head) ->
     (match head.history.turns with
      | [] -> fail "the fixture has no closed turn"
      | (first : Agent_core.Checkpoint_objects.turn) :: _ ->
        Sys.remove (Keeper_checkpoint_object_store.path ~session_dir first.bundle)));
  match Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:trace_id with
  | Error (_ : Keeper_checkpoint_store.checkpoint_load_error) -> ()
  | Ok _ -> fail "the fixture still loads whole"
;;

let only_outcome (report : Recovery.report) =
  match report.outcomes with
  | [ ((_ : string), outcome) ] -> outcome
  | outcomes -> failf "unexpected outcomes: %d" (List.length outcomes)
;;

(* A turn that called a tool and got its result. *)
let closed_turn =
  [ text Agent_core.Types.User "q1"
  ; request "call-done"
  ; answer "call-done"
  ; text Agent_core.Types.Assistant "a1"
  ]
;;

(* A persisted keeper whose trace has no canonical checkpoint -- an
   official-client lane, or a trace whose checkpoint a purge moved aside --
   has no open tool cycle to close. The session directory exists, as it does
   for such a keeper on a live workspace, and holds no checkpoint. *)
let test_a_keeper_without_a_canonical_checkpoint_has_nothing_to_recover () =
  with_workspace @@ fun config ->
  let name = "no-checkpoint" in
  let meta = make_meta name in
  (match Keeper_meta_store.replace_snapshot config meta with
   | Ok () -> ()
   | Error detail -> failf "keeper meta persistence failed: %s" detail);
  let session_dir =
    Filename.concat
      (Keeper_fs.session_base_dir config)
      (Keeper_id.Trace_id.to_string meta.Keeper_meta_contract.runtime.trace_id)
  in
  Unix.mkdir session_dir 0o700;
  let report = Recovery.recover_open_tails config in
  check int "one keeper examined" 1 report.Recovery.examined;
  check int "no recovery failure" 0 report.Recovery.failed;
  match report.Recovery.outcomes with
  | [ (reported, Recovery.Already_dispatchable) ] ->
    check string "the keeper is reported" name reported
  | [ (_, Recovery.Checkpoint_unavailable _) ] ->
    fail "a missing checkpoint is not a load failure"
  | outcomes -> failf "unexpected outcomes: %d" (List.length outcomes)
;;

(* A canonical the build before the last [checkpoint_version] bump wrote, whose
   history ends in a tool call with no result. The next turn starts fresh and
   does not replay it, so there is nothing to close: every boot leaves the
   file as it is and counts no failure. *)
let test_a_superseded_checkpoint_has_nothing_to_recover () =
  with_workspace @@ fun config ->
  let name = "superseded-checkpoint" in
  let meta = make_meta name in
  (match Keeper_meta_store.replace_snapshot config meta with
   | Ok () -> ()
   | Error detail -> failf "keeper meta persistence failed: %s" detail);
  let trace_id = Keeper_id.Trace_id.to_string meta.Keeper_meta_contract.runtime.trace_id in
  let session_dir = Filename.concat (Keeper_fs.session_base_dir config) trace_id in
  Unix.mkdir session_dir 0o700;
  let checkpoint =
    checkpoint ~trace_id ~name ~turn_count:1 [ text Agent_core.Types.User "q"; request "call-open" ]
  in
  let earlier =
    match Agent_core.Checkpoint.to_json checkpoint with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) ->
              if String.equal key "version"
              then key, `Int (Agent_core.Checkpoint.checkpoint_version - 1)
              else key, value)
           fields)
    | _ -> fail "a checkpoint document is a JSON object"
  in
  let path = Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:trace_id in
  let bytes = Yojson.Safe.to_string earlier in
  (match Fs_compat.save_file_atomic path bytes with
   | Ok () -> ()
   | Error detail -> failf "superseded fixture: %s" detail);
  (match Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:trace_id with
   | Error (Keeper_checkpoint_store.Superseded_version _) -> ()
   | Error error -> fail (Keeper_checkpoint_store.checkpoint_load_error_to_string error)
   | Ok _ -> fail "the superseded fixture still loads");
  let boot label =
    let report = Recovery.recover_open_tails config in
    check int (label ^ ": no recovery failure") 0 report.Recovery.failed;
    check int (label ^ ": nothing closed") 0 report.Recovery.closed;
    match report.Recovery.outcomes with
    | [ (_, Recovery.Already_dispatchable) ] -> ()
    | [ (_, Recovery.Checkpoint_unavailable error) ] ->
      failf "%s: %s" label (Keeper_checkpoint_store.saved_history_ref_error_to_string error)
    | outcomes -> failf "%s: unexpected outcomes: %d" label (List.length outcomes)
  in
  boot "first boot";
  boot "next boot";
  check string "the superseded file is left in place" bytes
    (In_channel.with_open_bin path In_channel.input_all)
;;

(* The turn a process death interrupted: its request has no result. The boot
   appends one, and the next boot finds nothing to do. *)
let test_a_request_that_awaits_results_is_closed () =
  with_workspace @@ fun config ->
  let name = "open-tail" in
  let trace_id, session_dir = persisted_keeper config name in
  save
    ~session_dir
    ~boundary:Agent_core.Checkpoint_objects.Turn_closes
    (checkpoint ~trace_id ~name ~turn_count:1 closed_turn);
  let interrupted = closed_turn @ [ text Agent_core.Types.User "q2"; request "call-open" ] in
  save
    ~session_dir
    ~boundary:Agent_core.Checkpoint_objects.Turn_continues
    (checkpoint ~trace_id ~name ~turn_count:2 interrupted);
  let report = Recovery.recover_open_tails config in
  check int "one keeper closed" 1 report.Recovery.closed;
  check int "one result appended" 1 report.Recovery.tool_results_appended;
  check int "no recovery failure" 0 report.Recovery.failed;
  (match only_outcome report with
   | Recovery.Closed { tool_use_ids } ->
     check (list string) "the request without a result" [ "call-open" ] tool_use_ids
   | Recovery.Already_dispatchable -> fail "the open request was left as it was"
   | Recovery.Unparseable _ | Recovery.Meta_unavailable _ | Recovery.Checkpoint_unavailable _
   | Recovery.Commit_rejected _ -> fail "the open request was not closed");
  (match Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:trace_id with
   | Error error -> fail (Keeper_checkpoint_store.checkpoint_load_error_to_string error)
   | Ok stored ->
     check int "one message appended" (List.length interrupted + 1) (List.length stored.messages);
     (match Keeper_transcript_unit.validate_provider_transcript stored.messages with
      | Ok () -> ()
      | Error error ->
        fail (Keeper_transcript_unit.show_provider_transcript_error error)));
  let after_first_boot = canonical_bytes ~session_dir ~trace_id in
  let next = Recovery.recover_open_tails config in
  check int "the next boot closes nothing" 0 next.Recovery.closed;
  (match only_outcome next with
   | Recovery.Already_dispatchable -> ()
   | Recovery.Closed _ | Recovery.Unparseable _ | Recovery.Meta_unavailable _
   | Recovery.Checkpoint_unavailable _ | Recovery.Commit_rejected _ ->
     fail "the next boot did not find the history closed");
  check string "the next boot writes nothing" after_first_boot
    (canonical_bytes ~session_dir ~trace_id)
;;

let check_left_as_it_is label config ~session_dir ~trace_id =
  let before = canonical_bytes ~session_dir ~trace_id in
  let report = Recovery.recover_open_tails config in
  check int (label ^ ": nothing closed") 0 report.Recovery.closed;
  check int (label ^ ": no recovery failure") 0 report.Recovery.failed;
  check int (label ^ ": nothing unparseable") 0 report.Recovery.unparseable;
  (match only_outcome report with
   | Recovery.Already_dispatchable -> ()
   | Recovery.Checkpoint_unavailable error ->
     failf "%s: %s" label (Keeper_checkpoint_store.saved_history_ref_error_to_string error)
   | Recovery.Closed _ | Recovery.Unparseable _ | Recovery.Meta_unavailable _
   | Recovery.Commit_rejected _ -> failf "%s: the history was not left as it is" label);
  check string (label ^ ": the canonical is as it was") before
    (canonical_bytes ~session_dir ~trace_id)
;;

let test_a_history_whose_requests_are_answered_is_left_as_it_is () =
  with_workspace @@ fun config ->
  let name = "answered" in
  let trace_id, session_dir = persisted_keeper config name in
  save
    ~session_dir
    ~boundary:Agent_core.Checkpoint_objects.Turn_closes
    (checkpoint ~trace_id ~name ~turn_count:1 closed_turn);
  check_left_as_it_is "a closed turn" config ~session_dir ~trace_id;
  (* The open turn of a keeper that was answering, not calling. *)
  save
    ~session_dir
    ~boundary:Agent_core.Checkpoint_objects.Turn_continues
    (checkpoint ~trace_id ~name ~turn_count:2 (closed_turn @ [ text Agent_core.Types.User "q2" ]));
  check_left_as_it_is "an open turn without a request" config ~session_dir ~trace_id
;;

let test_a_history_without_a_request_is_left_as_it_is () =
  with_workspace @@ fun config ->
  let name = "no-request" in
  let trace_id, session_dir = persisted_keeper config name in
  save
    ~session_dir
    ~boundary:Agent_core.Checkpoint_objects.Turn_closes
    (checkpoint ~trace_id ~name ~turn_count:1
       [ text Agent_core.Types.User "q"; text Agent_core.Types.Assistant "a" ]);
  check_left_as_it_is "every message read" config ~session_dir ~trace_id
;;

(* The last request has its results in the last turn, so the turn before it is
   not read: its bundle is gone and the boot still answers. *)
let test_an_answered_end_is_told_without_the_turns_before_it () =
  with_workspace @@ fun config ->
  let name = "answered-end" in
  let trace_id, session_dir = persisted_keeper config name in
  save
    ~session_dir
    ~boundary:Agent_core.Checkpoint_objects.Turn_closes
    (checkpoint ~trace_id ~name ~turn_count:1 closed_turn);
  let second_turn =
    [ text Agent_core.Types.User "q2"
    ; request "call-second"
    ; answer "call-second"
    ; text Agent_core.Types.Assistant "a2"
    ]
  in
  save
    ~session_dir
    ~boundary:Agent_core.Checkpoint_objects.Turn_closes
    (checkpoint ~trace_id ~name ~turn_count:2 (closed_turn @ second_turn));
  remove_first_turn_bundle ~session_dir ~trace_id;
  check_left_as_it_is "the last turn alone" config ~session_dir ~trace_id
;;

(* A request that awaits results sends the boot to the whole history, which
   cannot be read: nothing is appended to a history it has not read. *)
let test_an_unanswered_end_is_decided_by_the_whole_history () =
  with_workspace @@ fun config ->
  let name = "unanswered-end" in
  let trace_id, session_dir = persisted_keeper config name in
  save
    ~session_dir
    ~boundary:Agent_core.Checkpoint_objects.Turn_closes
    (checkpoint ~trace_id ~name ~turn_count:1 closed_turn);
  save
    ~session_dir
    ~boundary:Agent_core.Checkpoint_objects.Turn_continues
    (checkpoint ~trace_id ~name ~turn_count:2
       (closed_turn @ [ text Agent_core.Types.User "q2"; request "call-open" ]));
  remove_first_turn_bundle ~session_dir ~trace_id;
  let before = canonical_bytes ~session_dir ~trace_id in
  let report = Recovery.recover_open_tails config in
  check int "nothing closed" 0 report.Recovery.closed;
  check int "one recovery failure" 1 report.Recovery.failed;
  (match only_outcome report with
   | Recovery.Checkpoint_unavailable (_ : Keeper_checkpoint_store.Saved_history.ref_error) -> ()
   | Recovery.Already_dispatchable -> fail "the open request was not seen"
   | Recovery.Closed _ -> fail "a result was appended to a history that was not read"
   | Recovery.Unparseable _ | Recovery.Meta_unavailable _ | Recovery.Commit_rejected _ ->
     fail "the unreadable history was reported as something else");
  check string "the canonical is as it was" before (canonical_bytes ~session_dir ~trace_id)
;;

let () =
  run
    "keeper_transcript_tail_recovery"
    [ ( "recover_open_tails"
      , [ test_case
            "a keeper without a canonical checkpoint has nothing to recover"
            `Quick
            test_a_keeper_without_a_canonical_checkpoint_has_nothing_to_recover
        ; test_case
            "a superseded checkpoint has nothing to recover"
            `Quick
            test_a_superseded_checkpoint_has_nothing_to_recover
        ; test_case
            "a request that awaits results is closed"
            `Quick
            test_a_request_that_awaits_results_is_closed
        ] )
    ; ( "a history read from its end"
      , [ test_case
            "a history whose requests are answered is left as it is"
            `Quick
            test_a_history_whose_requests_are_answered_is_left_as_it_is
        ; test_case
            "a history without a request is left as it is"
            `Quick
            test_a_history_without_a_request_is_left_as_it_is
        ; test_case
            "an answered end is told without the turns before it"
            `Quick
            test_an_answered_end_is_told_without_the_turns_before_it
        ; test_case
            "an unanswered end is decided by the whole history"
            `Quick
            test_an_unanswered_end_is_decided_by_the_whole_history
        ] )
    ]
;;
