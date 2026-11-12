open Alcotest
open Masc
module T = Agent_core.Types
module B = Keeper_turn_boundaries
module S = Librarian_continuity_snapshot
module U = Yojson.Safe.Util
module Fixture = Exact_output_fixture

let write path text = Out_channel.with_open_bin path (fun oc -> output_string oc text)
let msg role text = T.make_message ~role [T.Text text]
let require_snapshot = function Ok value -> value | Error error -> fail (S.error_to_string error)

let keeper_name = "continuity-dispatch" and trace_id = "continuity-trace"
let covered = [msg T.User "Build the patch."; msg T.Assistant "The build passed."]
let working_state = "Build passed. Publication requires approval."
let pending = "Inspect the patch without publishing."

let overflow_reply =
  {|{"id":"overflow","model":"continuity-model","choices":[{"index":0,"message":{"role":"assistant","content":""},"finish_reason":"model_context_window_exceeded"}],"usage":{"prompt_tokens":1,"completion_tokens":0,"total_tokens":1}}|}

(* Two OpenAI-compatible peers on one lane: the first refuses every request
   as a context overflow unless [refused_behavior] says otherwise, the second
   answers. The body gets the workspace, the Eio net, and both peers. *)
let with_dispatch_fixture ?(refused_behavior = Fixture.Reply overflow_reply) body =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let runtime = Runtime.For_testing.snapshot () in
  let catalog = Llm_provider.Catalog_snapshot.current () in
  let base_path = Filename.temp_dir "continuity-dispatch-" "" in
  (* The accepted-range ledger is one table per process, keyed by Keeper,
     runtime and trace, which every case here shares: without a reset an
     earlier case's accepted range is a later case's front. *)
  Keeper_model_input_ledger.Table.For_testing.reset ();
  Config_dir_resolver.reset ();
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore runtime;
    (Llm_provider.Catalog_snapshot.publish catalog);
    Config_dir_resolver.reset ();
    Fs_compat.remove_tree base_path);
  let refused = Fixture.start_server ~sw ~net:env#net ~clock:env#clock refused_behavior in
  let accepted = Fixture.start_server ~sw ~net:env#net ~clock:env#clock
    (Fixture.Reply (Fixture.openai_response (`Assoc ["answer", `String "Await approval."]))) in
  let catalog_path = Filename.concat base_path "models.toml" in
  let row provider = Printf.sprintf
    "[[models]]\nmodel_id = \"continuity-model\"\nprovider_name = %S\nbase = \"openai_chat\"\nmax_context_tokens = 1048576\nmax_output_tokens = 128\nsupports_tools = true\nsupports_native_streaming = false\n" provider in
  write catalog_path (row "refused" ^ row "accepted");
  (match Llm_provider.Model_catalog.load_file catalog_path with
   | Ok catalog -> (Llm_provider.Catalog_snapshot.publish (Masc_test_deps.admit_catalogs ~models:(Some (catalog)) ~providers:(None))) | Error detail -> fail detail);
  let config_path = Filename.concat base_path "runtime.toml" in
  write config_path (Printf.sprintf {|[runtime]
default = "accepted.sample"
[providers.refused]
protocol = "openai-compatible-http"
endpoint = %S
[providers.accepted]
protocol = "openai-compatible-http"
endpoint = %S
[models.sample]
api-name = "continuity-model"
max-context = 1048576
streaming = false
[refused.sample]
[accepted.sample]
[runtime.lanes.continuity]
candidates = ["refused.sample", "accepted.sample"]
|} refused.base_url accepted.base_url);
  (match Runtime.init_default_degraded_report ~config_path with
   | Ok Runtime.Initialized -> ()
   | Ok (Runtime.Initialized_degraded _) -> fail "fixture catalog unavailable"
   | Error error -> fail (Runtime.strict_init_error_to_string error));
  let config = Workspace.default_config base_path in
  body ~sw ~net:env#net ~config ~base_path ~refused ~accepted

(* One completed turn over [covered], written to the keeper's boundary log. *)
let record_completed_turn ~config =
  let position = match B.position_of_messages covered with
    | Ok position -> position | Error detail -> fail detail in
  let boundary : B.record = {recorded_at = 1.; event = B.Turn_ended
    { task_context = Masc.Keeper_turn_task_context.No_task;turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1;
     history_at_start = B.Fresh_history; position}} in
  let keepers_dir = Workspace.keepers_runtime_dir config in
  (match B.append ~keepers_dir ~keeper_id:keeper_name boundary with
   | Ok () -> () | Error error -> fail (B.append_error_to_string error));
  boundary

(* Runs one turn whose history is [covered] plus this turn's input, and
   returns the attempt errors the lane reported, newest first. *)
let dispatch ?carried_front_seed ?history_at_start ?(initial_messages = covered @ [msg T.User pending])
    ?(agent_core_tools = []) ?(on_error = fun () -> ())
    ~sw ~net ~base_path () =
  let errors = ref [] in
  (match Keeper_turn_driver.run_named ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id = trace_id }) ~raw_trace:None ~walk_owner:Masc.Keeper_turn_driver.One_shot_walk ~system_prompt:"Continuity dispatch fixture."
      ~runtime_id:"continuity" ~keeper_name ~base_path ~media_store:(Tool_blob_media_store.of_base_path ~base_path)
      ?carried_front_seed ?history_at_start ~initial_messages ~agent_core_tools
      ~goal:"Report progress."
      ~on_runtime_attempt_error:(fun ~runtime_id ~attempt:_ ~dispatch:_ error ->
        errors := (runtime_id, error) :: !errors;on_error ())
      ~sw ~net () with
   | Ok _ -> () | Error error -> fail (Agent_core.Error.to_string error));
  !errors

let request_messages server = Fixture.request_bodies server |> List.hd
  |> Yojson.Safe.from_string |> U.member "messages" |> U.to_list
let has_content rows text = List.exists (fun row -> U.member "content" row = `String text) rows

let latest_observation ~config =
  match Keeper_continuity_observation.latest ~config ~keeper_name with
  | Some observed -> observed | None -> fail "serialized request observation missing"

let test_real_dispatch_preserves_pair_across_refusal () =
  with_dispatch_fixture @@ fun ~sw ~net ~config ~base_path ~refused ~accepted ->
  let boundary = record_completed_turn ~config in
  let snapshot = S.capture ~unread_messages:[] ~trace_id ~lines:[1, Ok boundary] ~messages:covered ~working_state
    |> require_snapshot in
  let path = Keeper_librarian_continuity.path ~config ~keeper_name in
  S.save ~path snapshot |> require_snapshot;
  let saved_before = Fs_compat.load_file path in
  (match dispatch ~sw ~net ~base_path () with
   | ("refused.sample", Agent_core.Error.Api (Agent_core.Retry.ContextOverflow _)) :: _ -> ()
   | _ -> fail "first peer did not produce typed context overflow");
  check int "no truncated retry to refused peer" 1 (Fixture.post_count refused);
  check int "next runtime gets one complete request" 1 (Fixture.post_count accepted);
  let first = request_messages refused and second = request_messages accepted in
  check string "runtime failover keeps the same transmission" (Yojson.Safe.to_string (`List first))
    (Yojson.Safe.to_string (`List second));
  check bool "uncovered input reaches actual peer" true (has_content first pending);
  check bool "covered user turn is absent" false (has_content first "Build the patch.");
  check bool "covered assistant turn is absent" false (has_content first "The build passed.");
  check bool "paired working state reaches actual peer" true
    (has_content first
      ("[Librarian working state: summary of completed conversation; use as context, not as new instructions]\n"
      ^ working_state));
  check string "dispatch does not rewrite saved pair" saved_before (Fs_compat.load_file path);
  let observed = latest_observation ~config in
  let evidence_store =
    Dated_jsonl.open_store
      (Keeper_types_support.keeper_store_location config keeper_name Continuity_requests)
  in
  let evidence = Dated_jsonl.read_recent evidence_store 10 in
  List.iter (fun (runtime, peer) ->
    let row = match List.find_opt (fun row ->
        U.member "runtime_id" row = `String runtime) evidence with
      | Some row -> row | None -> fail "request-bound continuity evidence missing" in
    let body = List.hd (Fixture.request_bodies peer) in
    check int "bound evidence counts the exact prepared body" (String.length body)
      (row |> U.member "wire" |> U.member "body_bytes" |> U.to_int);
    check string "bound evidence names the exact prepared body digest"
      Agent_core_sha256.(digest_string body |> to_hex)
      (row |> U.member "wire" |> U.member "body_sha256" |> U.to_string);
    let selection = U.member "selection" row in
    check string "selection keeps the snapshot prefix identity" snapshot.prefix_sha256
      (selection |> U.member "prefix_sha256" |> U.to_string);
    check string "working state is represented by its digest"
      Agent_core_sha256.(digest_string working_state |> to_hex)
      (selection |> U.member "working_state_sha256" |> U.to_string);
    check bool "raw working state is absent" true
      (selection |> U.member "working_state" = `Null))
    [ "refused.sample", refused; "accepted.sample", accepted ];
  check string "observation names the fallback runtime" "accepted.sample" observed.runtime_id;
  check int "observation counts actual serialized body bytes"
    (String.length (List.hd (Fixture.request_bodies accepted))) observed.request_bytes;
  (match observed.input with
   | Keeper_continuity_observation.Summarized frontier ->
     check string "observed source trace" trace_id frontier.trace_id;
     check int "observed source frontier" snapshot.end_atom frontier.end_atom
   | _ -> fail "actual request was not attributed to its saved context");
  Keeper_continuity_observation.forget ~config ~keeper_name;
  check bool "cleanup removes process observation" true
    (Option.is_none (Keeper_continuity_observation.latest ~config ~keeper_name))
;;

(* A cumulative ledger changes after the first request has actually failed.
   The fallback must carry the original request's observations and hashes,
   rather than combining its old cursor with newly loaded evidence. *)
let test_real_dispatch_freezes_unread_across_refusal () =
  with_dispatch_fixture @@ fun ~sw ~net ~config ~base_path ~refused ~accepted ->
  let module Unread = Keeper_librarian_unread in
  let module Frozen = Keeper_librarian_request_unread in
  let require = function Ok value -> value | Error detail -> fail detail in
  let hole atom reason = Unread.for_atom ~trace_id ~history_start_boundary_line:1
    ~atom ~message_in_atom:0 ~messages:covered ~reasons:[reason] |> require in
  let original=hole 0 Keeper_librarian_input_refusal.Input_capacity in
  let later=hole 1 Keeper_librarian_input_refusal.Request_body_refused in
  let boundary=record_completed_turn ~config in
  let snapshot=S.capture ~unread_messages:[original] ~trace_id ~lines:[1,Ok boundary]
    ~messages:covered ~working_state |> require_snapshot in
  let path=Keeper_librarian_continuity.path ~config ~keeper_name in
  S.save ~path snapshot |> require_snapshot;
  let saved_before=Fs_compat.load_file path in
  let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  (* Prepare and change valid persisted fixture evidence through the public
     path/codec. This scenario exercises request reads, not hole publication. *)
  let append_fixture_holes holes=Keeper_memory_os_aggregate_lock.with_lock ~keepers_dir ~keeper_id:keeper_name
    (fun () ->
      let previous=Keeper_memory_os_current.read_unread_messages ~keepers_dir ~keeper_id:keeper_name |> require in
      let merged=Unread.merge previous holes |> require in
      let ledger_path=Keeper_memory_os_current.unread_ledger_path ~keepers_dir ~keeper_id:keeper_name in
      Fs_compat.save_file_atomic_strict ledger_path
        (Yojson.Safe.to_string (`Assoc ["schema_version",`Int 1;
          "unread_messages",Unread.list_to_json merged])) |> require) in
  append_fixture_holes [original];
  let transitions=ref 0 in
  let on_error ()=incr transitions;append_fixture_holes [later] in
  (match dispatch ~on_error ~sw ~net ~base_path () with
   | ("refused.sample",Agent_core.Error.Api (Agent_core.Retry.ContextOverflow _)) :: _ -> ()
   | _ -> fail "the real first peer did not return a typed size refusal");
  check int "one terminal refusal precedes the fallback" 1 !transitions;
  check int "first request reached the refusing peer" 1 (Fixture.post_count refused);
  check int "second request reached the fallback peer" 1 (Fixture.post_count accepted);
  let frozen=Frozen.of_results ~snapshot:(Ok [original]) ~memory:(Ok [original]) in
  let carrier=match Frozen.text frozen with
    | Ok (Some text) -> text
    | Ok None -> fail "missing unread fixture"
    | Error detail -> fail detail in
  let store=Dated_jsonl.open_store
    (Keeper_types_support.keeper_store_location config keeper_name Continuity_requests) in
  let evidence=Dated_jsonl.read_recent store 10 in
  List.iter (fun (runtime,peer) ->
    let rows=request_messages peer in
    check bool "actual wire preserves the same frozen unread evidence" true (has_content rows carrier);
    check bool "the exact unread original is absent from raw history" false
      (has_content rows "Build the patch.");
    let row=match List.find_opt (fun row -> U.member "runtime_id" row=`String runtime) evidence with
      | Some row -> row | None -> fail "frozen request diagnostic missing" in
    check string "diagnostic uses the unread observation schema" "masc.continuity-request.v3"
      (row |> U.member "schema" |> U.to_string);
    check bool "diagnostic binds precisely the sent frozen observation" true
      (U.member "unread" row=Frozen.to_json frozen);
    let body=List.hd (Fixture.request_bodies peer) in
    check int "diagnostic counts the actual body bytes" (String.length body)
      (row |> U.member "wire" |> U.member "body_bytes" |> U.to_int);
    check string "diagnostic hashes the actual body bytes" Agent_core_sha256.(digest_string body |> to_hex)
      (row |> U.member "wire" |> U.member "body_sha256" |> U.to_string))
    ["refused.sample",refused;"accepted.sample",accepted];
  let ledger=Keeper_memory_os_current.read_unread_messages ~keepers_dir ~keeper_id:keeper_name |> require in
  check bool "the real store changed between candidates" true (List.mem later ledger);
  check int "both exact original holes remain in the cumulative store" 2 (List.length ledger);
  check string "read-only dispatch preserves snapshot bytes" saved_before (Fs_compat.load_file path);
  Keeper_continuity_observation.forget ~config ~keeper_name
;;

(* The turn goes out from where the last completed turn ended, carrying only
   its own input, and the request is attributed to a start without a
   snapshot. *)
let check_dispatched_from_the_turn_start ~config ~accepted =
  check int "the answering peer gets one request" 1 (Fixture.post_count accepted);
  let rows = request_messages accepted in
  check bool "this turn's input goes out" true (has_content rows pending);
  check bool "the completed turn stays home" false (has_content rows "Build the patch.");
  check bool "the completed reply stays home" false (has_content rows "The build passed.");
  let observed = latest_observation ~config in
  (match observed.input with
   | Keeper_continuity_observation.Without_snapshot -> ()
   | _ -> fail "request was not attributed to a start without a snapshot");
  Keeper_continuity_observation.forget ~config ~keeper_name
;;

(* #37762: a snapshot file this process cannot read is no front. The turn is
   not refused before dispatch as an invalid configuration. *)
let test_unreadable_snapshot_dispatches_from_the_turn_start () =
  with_dispatch_fixture @@ fun ~sw ~net ~config ~base_path ~refused:_ ~accepted ->
  let (_ : B.record) = record_completed_turn ~config in
  write (Keeper_librarian_continuity.path ~config ~keeper_name) {|{"trace_id": 7}|};
  let (_ : (string * Agent_core.Error.t) list) = dispatch ~sw ~net ~base_path () in
  check_dispatched_from_the_turn_start ~config ~accepted
;;

(* #37762: a saved snapshot whose covered-prefix digest no longer matches the
   history is stale (Prefix_changed), not an invalid configuration. *)
let test_changed_prefix_dispatches_from_the_turn_start () =
  with_dispatch_fixture @@ fun ~sw ~net ~config ~base_path ~refused:_ ~accepted ->
  let boundary = record_completed_turn ~config in
  let snapshot = S.capture ~unread_messages:[] ~trace_id ~lines:[1, Ok boundary] ~messages:covered ~working_state
    |> require_snapshot in
  let path = Keeper_librarian_continuity.path ~config ~keeper_name in
  S.save ~path snapshot |> require_snapshot;
  let altered = Yojson.Safe.from_file path |> U.to_assoc |> List.map (fun (key, value) ->
    if String.equal key "prefix_sha256" then key, `String (String.make 64 'f') else key, value) in
  write path (Yojson.Safe.to_string (`Assoc altered));
  let (_ : (string * Agent_core.Error.t) list) = dispatch ~sw ~net ~base_path () in
  check_dispatched_from_the_turn_start ~config ~accepted
;;

(* RFC librarian-lifecycle §4.10, rule 1, through the driver's own attempt
   and lane answer: a Librarian read position at atom 2 of a six-atom
   history whose last completed turn ended at atom 6, and a turn record
   whose accepted start is atom 4. The first request opens at that accepted
   start and the peer refuses it as a context overflow; the lane resends
   once to the same peer from the turn boundary, not from the recorded
   start, and the peer answers. *)
let test_a_librarian_behind_refusal_resends_from_the_boundary () =
  with_dispatch_fixture
    ~refused_behavior:
      (Fixture.Replies
         [ overflow_reply
         ; Fixture.openai_response (`Assoc [ "answer", `String "Resent from the boundary." ])
         ])
  @@ fun ~sw ~net ~config ~base_path ~refused ~accepted ->
  let completed =
    [ msg T.User "ask 0"; msg T.Assistant "answer 0"
    ; msg T.User "ask 1"; msg T.Assistant "answer 1"
    ; msg T.User "ask 2"; msg T.Assistant "answer 2" ]
  in
  let initial_messages = completed @ [ msg T.User pending ] in
  let keepers_dir = Workspace.keepers_runtime_dir config in
  let position = match B.position_of_messages completed with
    | Ok position -> position | Error detail -> fail detail in
  (match B.append ~keepers_dir ~keeper_id:keeper_name
     {recorded_at = 1.; event = B.Turn_ended
        { task_context = Masc.Keeper_turn_task_context.No_task;turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1;
         history_at_start = B.Fresh_history; position}} with
   | Ok () -> () | Error error -> fail (B.append_error_to_string error));
  let digest_at = Runtime_model_input_tail_window.atom_opening_digest initial_messages in
  (match
     Keeper_librarian_progress.write ~keepers_dir ~keeper_id:keeper_name
       { position = { trace_id; end_atom = 2; last_atom_digest = Option.get (digest_at 1) }
       ; boundary_lines_seen = 1 }
   with
   | Ok () -> () | Error error -> fail (Keeper_librarian_progress.write_error_to_string error));
  let recorded : Keeper_carried_front.seed =
    { first_atom = 4; front = Model_input_front.At_atom (Option.get (digest_at 4))
    ; source = Keeper_carried_front.Turn_record { turn = 1 } } in
  let carried_front_seed () =
    { Keeper_carried_front.seed = Some recorded; refused_start = None; unreadable = None; boundary_error = None } in
  let (_ : (string * Agent_core.Error.t) list) =
    dispatch ~carried_front_seed ~initial_messages ~sw ~net ~base_path () in
  check int "the refused peer is asked twice" 2 (Fixture.post_count refused);
  check int "the next peer is not reached" 0 (Fixture.post_count accepted);
  let sent n = Fixture.request_bodies refused |> Fun.flip List.nth n
    |> Yojson.Safe.from_string |> U.member "messages" |> U.to_list in
  let first = sent 0 and resent = sent 1 in
  check bool "the first request opens at the recorded start" true (has_content first "ask 2");
  check bool "and not at the Librarian point" false (has_content first "ask 1");
  check bool "the resend carries this turn's input" true (has_content resent pending);
  check bool "the resend opens at the turn boundary, not the recorded start" false
    (has_content resent "ask 2")
;;

(* RFC librarian-lifecycle §4.10, rule 8, through the driver's own attempt
   and lane answer. The last completed turn ended at atom 6. A later turn
   saved "ask 3" and "answer 3" and failed, so it wrote no end line, and
   this turn began at atom 8. The turn record's accepted start is the turn
   boundary 6, so the first request opens there and rule 1 has no later
   start to try; no tool result is left to demote. The lane resends once to
   the same peer from where this turn began, and the peer answers. *)
let test_a_refused_boundary_resends_from_where_this_turn_began () =
  with_dispatch_fixture
    ~refused_behavior:
      (Fixture.Replies
         [ overflow_reply
         ; Fixture.openai_response (`Assoc [ "answer", `String "Resent from this turn's start." ])
         ])
  @@ fun ~sw ~net ~config ~base_path ~refused ~accepted ->
  let completed =
    [ msg T.User "ask 0"; msg T.Assistant "answer 0"
    ; msg T.User "ask 1"; msg T.Assistant "answer 1"
    ; msg T.User "ask 2"; msg T.Assistant "answer 2" ]
  in
  let failed_turn = [ msg T.User "ask 3"; msg T.Assistant "answer 3" ] in
  let initial_messages = completed @ failed_turn @ [ msg T.User pending ] in
  let keepers_dir = Workspace.keepers_runtime_dir config in
  let position = match B.position_of_messages completed with
    | Ok position -> position | Error detail -> fail detail in
  (match B.append ~keepers_dir ~keeper_id:keeper_name
     {recorded_at = 1.; event = B.Turn_ended
        { task_context = Masc.Keeper_turn_task_context.No_task;turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1;
         history_at_start = B.Fresh_history; position}} with
   | Ok () -> () | Error error -> fail (B.append_error_to_string error));
  let digest_at = Runtime_model_input_tail_window.atom_opening_digest initial_messages in
  (match
     Keeper_librarian_progress.write ~keepers_dir ~keeper_id:keeper_name
       { position = { trace_id; end_atom = 2; last_atom_digest = Option.get (digest_at 1) }
       ; boundary_lines_seen = 1 }
   with
   | Ok () -> () | Error error -> fail (Keeper_librarian_progress.write_error_to_string error));
  let recorded : Keeper_carried_front.seed =
    { first_atom = 6; front = Model_input_front.At_atom (Option.get (digest_at 6))
    ; source = Keeper_carried_front.Turn_record { turn = 1 } } in
  let carried_front_seed () =
    { Keeper_carried_front.seed = Some recorded; refused_start = None; unreadable = None; boundary_error = None } in
  let history_at_start = B.history_at_start_of_messages (completed @ failed_turn) in
  let (_ : (string * Agent_core.Error.t) list) =
    dispatch ~carried_front_seed ~history_at_start ~initial_messages ~sw ~net ~base_path () in
  check int "the refused peer is asked twice" 2 (Fixture.post_count refused);
  check int "the next peer is not reached" 0 (Fixture.post_count accepted);
  let sent n = Fixture.request_bodies refused |> Fun.flip List.nth n
    |> Yojson.Safe.from_string |> U.member "messages" |> U.to_list in
  let first = sent 0 and resent = sent 1 in
  check bool "the first request opens at the turn boundary" true (has_content first "ask 3");
  check bool "and not before it" false (has_content first "answer 2");
  check bool "the resend carries this turn's input" true (has_content resent pending);
  check bool "the resend opens where this turn began, past the failed turn" false
    (has_content resent "answer 3")
;;

(* The three completed exchanges every rule-8 fixture below starts from,
   written to the boundary log as one completed turn that ended at atom 6. *)
let three_completed_exchanges =
  [ msg T.User "ask 0"; msg T.Assistant "answer 0"
  ; msg T.User "ask 1"; msg T.Assistant "answer 1"
  ; msg T.User "ask 2"; msg T.Assistant "answer 2" ]

let record_three_completed_exchanges ~config =
  let position = match B.position_of_messages three_completed_exchanges with
    | Ok position -> position | Error detail -> fail detail in
  match B.append ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name
     {recorded_at = 1.; event = B.Turn_ended
        { task_context = Masc.Keeper_turn_task_context.No_task;turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1;
         history_at_start = B.Fresh_history; position}} with
  | Ok () -> () | Error error -> fail (B.append_error_to_string error)
;;

let refused_then_answered answer =
  Fixture.Replies [ overflow_reply; Fixture.openai_response (`Assoc [ "answer", `String answer ]) ]

let sent_to peer n = Fixture.request_bodies peer |> Fun.flip List.nth n
  |> Yojson.Safe.from_string |> U.member "messages" |> U.to_list

(* RFC librarian-lifecycle §4.10, rule 8, on a turn with no snapshot, no
   Librarian position and no seed. A later turn saved "ask 3" and
   "answer 3" and failed, so the turn boundary stays at 6 and this turn
   began at 8. The first request opens at the boundary, so rule 1 has no
   later start to try, and no tool result is left to demote. The lane
   resends once to the same peer from where this turn began. *)
let test_a_refused_boundary_without_a_snapshot_resends_from_where_this_turn_began () =
  with_dispatch_fixture ~refused_behavior:(refused_then_answered "Resent without a snapshot.")
  @@ fun ~sw ~net ~config ~base_path ~refused ~accepted ->
  record_three_completed_exchanges ~config;
  let failed_turn = [ msg T.User "ask 3"; msg T.Assistant "answer 3" ] in
  let initial_messages = three_completed_exchanges @ failed_turn @ [ msg T.User pending ] in
  let history_at_start = B.history_at_start_of_messages (three_completed_exchanges @ failed_turn) in
  let (_ : (string * Agent_core.Error.t) list) =
    dispatch ~history_at_start ~initial_messages ~sw ~net ~base_path () in
  check int "the refused peer is asked twice" 2 (Fixture.post_count refused);
  check int "the next peer is not reached" 0 (Fixture.post_count accepted);
  let first = sent_to refused 0 and resent = sent_to refused 1 in
  check bool "the first request opens at the turn boundary" true (has_content first "ask 3");
  check bool "and not before it" false (has_content first "answer 2");
  check bool "the resend carries this turn's input" true (has_content resent pending);
  check bool "the resend opens where this turn began, past the failed turn" false
    (has_content resent "answer 3");
  (match (latest_observation ~config).input with
   | Keeper_continuity_observation.Without_snapshot -> ()
   | _ -> fail "the resend was not attributed to a start without a snapshot");
  Keeper_continuity_observation.forget ~config ~keeper_name
;;

(* The reader a Keeper opens a marker with. Composition demotes a result
   only for a Keeper that offers it ([Keeper_recovery_transmission.require_reader]);
   no request here calls it. *)
let artifact_reader ~base_path =
  let schema = Keeper_runtime_schemas_toml.artifact_read in
  Tool_bridge.agent_core_tool_of_masc_with_execution_env
    ~base_path
    ~descriptor:(Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Concurrent)
    ~model_projection:(fun () -> Tool_output.bounded_inline_model_projection)
    ~name:schema.name ~description:schema.description ~input_schema:schema.input_schema
    (fun _ _ -> fail "no request calls the reader")
    |> Result.get_ok
;;

(* RFC librarian-lifecycle §4.10, rule 6 before rule 8. The failed turn
   saved "ask 3", a tool call and its large result, and "answer 3". The
   first request opens at the turn boundary and is refused. Rule 6 answers
   first: the resend still opens at the boundary, so "ask 3" rides, and the
   result's body leaves as a marker. Rule 8 is not reached. *)
let test_a_refused_boundary_demotes_before_it_moves_past_the_failed_turn () =
  with_dispatch_fixture ~refused_behavior:(refused_then_answered "Resent with markers.")
  @@ fun ~sw ~net ~config ~base_path ~refused ~accepted ->
  record_three_completed_exchanges ~config;
  let call_id = "call-failed-turn" in
  let body = "failed-turn result " ^ String.make 8_000 'x' in
  let failed_turn =
    [ msg T.User "ask 3"
    ; T.make_message ~role:T.Assistant
        [ T.ToolUse { id = call_id; name = "fixture_tool"; input = `Assoc [] } ]
    ; T.make_message ~role:T.Tool ~tool_call_id:call_id
        [ T.ToolResult
            { tool_use_id = call_id; content = body; outcome = T.Tool_succeeded
            ; json = None; content_blocks = None } ]
    ; msg T.Assistant "answer 3" ]
  in
  let initial_messages = three_completed_exchanges @ failed_turn @ [ msg T.User pending ] in
  let history_at_start = B.history_at_start_of_messages (three_completed_exchanges @ failed_turn) in
  let (_ : (string * Agent_core.Error.t) list) =
    dispatch ~history_at_start ~initial_messages
      ~agent_core_tools:[ artifact_reader ~base_path ] ~sw ~net ~base_path () in
  check int "the refused peer is asked twice" 2 (Fixture.post_count refused);
  check int "the next peer is not reached" 0 (Fixture.post_count accepted);
  let result_content rows =
    match List.filter (fun row -> U.member "role" row = `String "tool") rows with
    | [ row ] -> U.member "content" row |> U.to_string
    | _ -> fail "the request does not carry the failed turn's one tool result"
  in
  let first = sent_to refused 0 and resent = sent_to refused 1 in
  check string "the first request carries the body" body (result_content first);
  check bool "the resend still opens at the turn boundary" true (has_content resent "ask 3");
  check bool "the resend carries this turn's input" true (has_content resent pending);
  (match Tool_output.decode_from_agent_core (result_content resent) with
   | Tool_output.Decoded reference ->
     (match Tool_blob_store.fetch (Tool_blob_store.create ~base_path)
              ~sha256:reference.Tool_output.sha256 with
      | Ok (Some bytes) -> check string "the marker opens the body" body bytes
      | Ok None | Error _ -> fail "the marker's body is not stored")
   | Tool_output.Not_marker | Tool_output.Invalid_marker _ ->
     fail "the resend does not carry the body as a marker")
;;

let () = run "continuity HTTP dispatch"
  ["real peer", [test_case "saved pair survives provider refusal and failover" `Quick
    test_real_dispatch_preserves_pair_across_refusal;
    test_case "snapshot and Memory unread freeze across actual failover" `Quick
      test_real_dispatch_freezes_unread_across_refusal];
   "unusable snapshot", [
    test_case "an unreadable snapshot file dispatches from the turn start" `Quick
      test_unreadable_snapshot_dispatches_from_the_turn_start;
    test_case "a snapshot whose covered prefix changed dispatches from the turn start" `Quick
      test_changed_prefix_dispatches_from_the_turn_start];
   "Librarian behind", [
    test_case "a size refusal resends from the turn boundary" `Quick
      test_a_librarian_behind_refusal_resends_from_the_boundary;
    test_case "a refused boundary resends from where this turn began" `Quick
      test_a_refused_boundary_resends_from_where_this_turn_began;
    test_case "a refused boundary without a snapshot resends from where this turn began" `Quick
      test_a_refused_boundary_without_a_snapshot_resends_from_where_this_turn_began;
    test_case "a refused boundary demotes before it moves past the failed turn" `Quick
      test_a_refused_boundary_demotes_before_it_moves_past_the_failed_turn]]
