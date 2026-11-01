open Alcotest
module Driver = Masc.Keeper_turn_driver_try_provider
module Host = Masc.Keeper_official_client_host
module Unread = Masc.Keeper_librarian_unread
module Frozen = Masc.Keeper_librarian_request_unread
module Snapshot = Masc.Librarian_continuity_snapshot
module Boundary = Masc.Keeper_turn_boundaries
module Front = Masc.Keeper_carried_front
module Window = Runtime_model_input_tail_window
module T = Agent_core.Types

let require = function Ok value -> value | Error detail -> fail detail
let trace_id="frozen-unread"
let message body=T.make_message ~role:T.User [T.Text body]
let source=[message "Original completed request.";message "Another completed request."]
let messages=source@[message "Current request."]
let digest_at=Window.atom_opening_digest messages
let hole=Unread.for_atom ~trace_id ~history_start_boundary_line:1 ~atom:0 ~message_in_atom:0
  ~messages:source ~reasons:[Masc.Keeper_librarian_input_refusal.Input_capacity] |> require
let later_hole=Unread.for_atom ~trace_id ~history_start_boundary_line:1 ~atom:1 ~message_in_atom:0
  ~messages:source ~reasons:[Masc.Keeper_librarian_input_refusal.Request_body_refused] |> require
let position : Masc.Keeper_librarian_progress.t =
  {position={trace_id;end_atom=1;last_atom_digest=Option.get (digest_at 0)};
   boundary_lines_seen=1}
let choose ?(snapshot=Ok None) ?(lines=fun () -> Ok []) memory =
  Driver.choose_continuity ~trace_id ~messages ~snapshot ~lines
    ~progress:(fun () -> Ok (Some position)) ~memory_unread:(fun () -> memory) |> fst
let measure message=String.length (Yojson.Safe.to_string (Agent_core.Checkpoint.message_to_json message))
let measure_native=Host.measure_message_bytes
let carrier messages=match List.filter Window.is_unread_context messages with
  | [message] -> message | [] | _ :: _ :: _ -> fail "expected exactly one unread carrier"
let carried_json message =
  let body=T.text_of_message message in
  let after=String.index body '\n'+1 in
  Yojson.Safe.from_string (String.sub body after (String.length body-after))
let check_carrier expected messages =
  check bool "exact frozen source coordinates, hashes and causes" true
    (carried_json (carrier messages)=Frozen.to_json expected)
let resume_has_carrier (delivery : Host.resume_delivery) messages =
  String_util.contains_substring delivery.prompt
    (Host.encode_history_message (carrier messages))
let compose ?accepted continuity history =
  Driver.For_testing.compose_carried_model_input ~continuity ~measure_message_bytes:measure
    ~front:None ~accepted ~history_digest_at:(Window.atom_opening_digest history)
    ~current_turn_results:Driver.Current_turn_verbatim ~base_path:(Filename.get_temp_dir_name ())
    ~demote_before:0 ~turn_boundary:(Front.Turn_boundary {end_atom=2}) history

let test_absorbed_freeze_and_forecast () =
  let ledger=ref [] and reads=ref 0 in
  let continuity,_=Driver.choose_continuity ~trace_id ~messages ~snapshot:(Ok None)
    ~lines:(fun () -> fail "no snapshot means no boundary scan")
    ~progress:(fun () -> ledger:=[hole];Ok (Some position))
    ~memory_unread:(fun () -> incr reads;Ok !ledger) in
  ledger:=[hole;later_hole];
  let accepted : Front.seed={first_atom=2;front=Model_input_front.At_atom (Option.get (digest_at 2));
    source=Front.Turn_record {turn=3}} in
  let result=compose ~accepted continuity messages in
  let expected=Frozen.of_results ~snapshot:(Ok []) ~memory:(Ok [hole]) in
  check_carrier expected result.projection.messages;
  check int "the turn reads unread evidence once after choosing progress" 1 !reads;
  let forecast=Masc.Keeper_next_request_forecast.carry ~measure ~continuity:(Some continuity)
    ~front:None ~accepted:(Some accepted) ~turn_start:(Front.Turn_boundary {end_atom=2})
    ~counted_tokens:None messages in
  check int "forecast charges the exact transmitted carrier bytes" result.transmitted_bytes forecast.transmitted_bytes;
  check int "accepted later front preserves the same atom vocabulary" 2 forecast.first_atom;
  check bool "pinned evidence does not create an atom" true
    (match Window.annotate [carrier result.projection.messages] with [_,Window.Pinned],0 -> true
     | _,_ -> false)

let capture ?(snapshot_trace_id=trace_id) ?(working_state="Completed context.") () =
  let trace_id=snapshot_trace_id in
  let unread=Unread.for_atom ~trace_id ~history_start_boundary_line:1 ~atom:0 ~message_in_atom:0
    ~messages:source ~reasons:[Masc.Keeper_librarian_input_refusal.Input_capacity] |> require in
  let position=Boundary.position_of_messages source |> require in
  let lines=[1,Ok {Boundary.recorded_at=1.;event=Boundary.Turn_ended
    {task_context=Masc.Keeper_turn_task_context.No_task;
     turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:1;history_at_start=Boundary.Fresh_history;position}}] in
  let snapshot=Snapshot.capture ~unread_messages:[unread] ~trace_id ~lines ~messages:source
    ~working_state |> Result.map_error Snapshot.error_to_string |> require in
  snapshot,lines

let test_independent_unknown_and_stale_snapshot () =
  let snapshot,lines=capture () in
  let summarized=choose ~snapshot:(Ok (Some snapshot)) ~lines:(fun () -> Ok lines) (Error "ledger unreadable") in
  let expected=Frozen.of_results ~snapshot:(Ok [hole]) ~memory:(Error "ledger unreadable") in
  check_carrier expected (compose summarized messages).projection.messages;
  let stale_snapshot,_=capture ~snapshot_trace_id:"previous-trace" () in
  check bool "a valid foreign snapshot cannot restore this trace" true
    (Result.is_error (Snapshot.restore ~trace_id ~lines ~messages:source stale_snapshot));
  let stale=choose ~snapshot:(Ok (Some stale_snapshot))
    ~lines:(fun () -> Ok lines) (Ok [later_hole]) in
  check_carrier (Frozen.of_results ~snapshot:(Ok stale_snapshot.unread_messages) ~memory:(Ok [later_hole]))
    (compose stale messages).projection.messages;
  let unavailable=choose ~snapshot:(Error "snapshot unreadable") (Ok [hole]) in
  check_carrier (Frozen.of_results ~snapshot:(Error "snapshot unreadable") ~memory:(Ok [hole]))
    (compose unavailable messages).projection.messages

let test_candidate_baseline_keeps_original_source () =
  let continuity=choose (Ok [hole]) in
  let rendered=message "Candidate-specific rendering of the original media."::List.tl messages in
  let rebound=Driver.continuity_for_attempt ~messages:rendered continuity in
  Driver.validate_continuity ~messages:rendered rebound
    |> Result.map_error Agent_core.Error.to_string |> require;
  check_carrier (Driver.request_unread continuity) (compose rebound rendered).projection.messages;
  check bool "canonical source hash is never a degraded candidate hash" false
    (hole.source=Unread.Atom {trace_id;history_start_boundary_line=1;atom=0;message_in_atom=0;
      message_sha256=Unread.message_digest (List.hd rendered)})

let official_front continuity = Driver.librarian_position ~messages continuity
  |> Result.map_error Agent_core.Error.to_string |> require
let start_projection front ~capacity history =
  Host.start_range_projection ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id = "frozen-fixture" }) ~measure_message_bytes:measure_native ~capacity_bytes:capacity
    ~unbounded_capacity_bytes:max_int ~reserved_bytes:0 ~librarian_front:(fun _ -> Ok front)
    ~turn_start:(Front.Turn_boundary {end_atom=2}) ~keeper_name:"frozen-fixture"
    ~runtime_id:"fixture.native" history

let test_capacity_floor_keeps_evidence () =
  let front=official_front (choose (Ok [hole])) in
  let pinned=Frozen.attach ~role:T.System front.unread messages in
  let empty,capacity=Window.project_from_atom ~allow_empty_history:true ~measure_message_bytes:measure_native
    ~first_atom:(snd (Window.annotate messages)) pinned in
  let sent=start_projection front ~capacity messages |> Result.map_error Agent_core.Error.to_string |> require in
  check_carrier front.unread sent;
  check bool "zero-history floor stays empty while evidence remains" true
    (List.for_all (fun message -> not (List.mem message messages)) sent
     && empty.dropped_atoms=empty.atom_count);
  let required=measure_native (carrier pinned) in
  match start_projection front ~capacity:(required-1) messages with
  | Error _ -> () | Ok _ -> fail "capacity cut silently discarded mandatory unread evidence"

let test_summary_fallback_and_resume () =
  let snapshot,lines=capture ~working_state:(String.make 10000 's') () in
  let front=official_front (choose ~snapshot:(Ok (Some snapshot)) ~lines:(fun () -> Ok lines) (Ok [hole])) in
  let plain={front with Driver.point=Driver.Librarian_progress {end_atom=snapshot.end_atom}} in
  let range front=Host.carried_start_range ~keeper_name:"frozen-fixture" ~runtime_id:"fixture.native"
    ~carried_front_seed:None ~librarian_front:front ~own_first_atom:0
    ~turn_start:(Front.Turn_boundary {end_atom=2}) messages in
  let plain_range=range plain in
  let labelled,atom_count=Window.annotate plain_range.messages in
  let _,floor_bytes=Window.project_from_atom ~allow_empty_history:true
    ~measure_message_bytes:measure_native ~first_atom:atom_count plain_range.messages in
  let atom_bytes=List.fold_left (fun count (message,label) ->
    match label with Window.Pinned -> count
    | Window.Atom _ -> count+measure_native message) 0 labelled in
  (* The public window reserves its omission preamble before considering
     history, even when this User-first range ultimately needs no preamble. *)
  let budget=floor_bytes+atom_bytes in
  let compose front =
    let carried=range front in
    Window.project_with_drop ~measure_message_bytes:measure_native ~capacity_bytes:budget ~reserved_bytes:0 carried.messages
    |> Result.map_error Window.budget_error_to_core_error
    |> Result.map (fun (projection : Window.projection) -> {Host.carried;sent=projection.messages;
      atoms_kept=projection.atom_count-projection.dropped_atoms}) in
  let plain_composed=compose plain |> Result.map_error Agent_core.Error.to_string |> require in
  check int "the admissible budget retains every atom without the summary" atom_count plain_composed.atoms_kept;
  check_carrier front.unread plain_composed.sent;
  check bool "the same budget cannot carry the oversized working state" true
    (Result.is_error (compose front));
  let composed=Host.compose_librarian_range ~keeper_name:"frozen-fixture" ~runtime_id:"fixture.native"
    ~compose front |> Result.map_error Agent_core.Error.to_string |> require in
  check_carrier front.unread composed.sent;
  check bool "summary may be left out without losing unread evidence" false
    (List.exists Window.is_working_state composed.sent);
  check int "summary omission retains the same original atoms" plain_composed.atoms_kept composed.atoms_kept;
  let start=Host.resume_prompt ~goal:"current goal" ~held:[] composed.sent in
  let changed=Frozen.of_results ~snapshot:(Ok [hole]) ~memory:(Ok [hole;later_hole]) in
  let changed_messages=Frozen.attach ~role:T.System changed composed.sent in
  check_carrier changed changed_messages;
  let next=Host.resume_prompt ~goal:"current goal" ~held:start.held_context changed_messages in
  check bool "a new unread record is sent to the resumed native session" true
    (resume_has_carrier next changed_messages);
  let unchanged=Host.resume_prompt ~goal:"current goal" ~held:next.held_context changed_messages in
  check string "an unchanged held context is acknowledged once" "current goal" unchanged.prompt;
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  Config_dir_resolver.reset ();
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let base_path=Filename.temp_dir "frozen-unread-session-" "" in
  Eio.Switch.on_release sw (fun () ->
    Config_dir_resolver.reset ();
    Fs_compat.remove_tree base_path);
  let module Store=Masc.Keeper_official_client_session_store in
  let tool_surface_sha256=Agent_core_sha256.(digest_string "native tool surface" |> to_hex) in
  let frontier : Store.context_frontier={message_count=List.length composed.sent;
    delivery=Store.Prepared_start_context;acknowledged_turn=None;held_context=[]} in
  let keeper_name="frozen-fixture" and session_id="native-session" and turn_id="native-turn" in
  let claimed=Store.claim_with_context_frontier ~context_frontier:(Some frontier)
    ~base_path ~keeper_name ~expected:None ~client_kind:Store.Codex ~owner_epoch:(Store.process_epoch ())
    ~runtime_id:"fixture.native" ~tool_surface_sha256 ~updated_at:1. |> require in
  let active=Store.mark_active ~base_path ~keeper_name ~expected:claimed ~session_id ~updated_at:2. |> require in
  let starting=Store.mark_turn_starting ~base_path ~keeper_name ~expected:active ~session_id ~updated_at:2.5 |> require in
  let inflight=Store.mark_turn_started ~base_path ~keeper_name ~expected:starting ~session_id ~turn_id
    ~turn_count:1 ~updated_at:3. |> require in
  let settled=Store.settle_holding ~held_context:next.held_context ~base_path ~keeper_name
    ~expected:inflight ~session_id ~turn_id ~updated_at:4. |> require in
  let loaded=Store.load ~base_path ~keeper_name |> Result.map_error Store.read_error_to_string |> require in
  check bool "native unread identity survives actual store write and reload" true (loaded=Some settled);
  let plan : Store.claim_plan={previous_settlement=Some {session_id;turn_id};turn_count=2;
    required_tool_surface_sha256=None} in
  check bool "only acknowledged settlement exposes held unread identity" true
    (Store.held_context_for_resume plan ~expected:loaded=next.held_context)

let test_custom_projection_cannot_replace_evidence () =
  let frozen=Frozen.of_results ~snapshot:(Ok []) ~memory:(Ok [hole]) in
  let stale=Frozen.of_results ~snapshot:(Ok []) ~memory:(Ok [later_hole]) in
  let project history=Ok (Frozen.attach ~role:T.System stale
    (List.filter (fun message -> not (Window.is_unread_context message)) history)) in
  let sent=Host.project_source ~input_source:(Masc.Keeper_request_source.Keeper_history {trace_id})
    ~unread:frozen (Some project)
    (Frozen.attach ~role:T.System frozen messages) |> Result.map_error Agent_core.Error.to_string |> require in
  check_carrier frozen sent

let test_completion_review_keeps_the_projected_original () =
  let historical=Frozen.of_results ~snapshot:(Ok []) ~memory:(Ok [hole]) in
  let original=messages @ Frozen.attach ~role:T.System historical [] in
  let unavailable=Frozen.of_results ~snapshot:(Error "none") ~memory:(Error "none") in
  let appended=message "caller-projected context" in
  let calls=ref 0 in
  let project history=incr calls;Ok (history @ [appended]) in
  let sent=Host.project_source ~input_source:Masc.Keeper_request_source.Completion_review
    ~unread:unavailable (Some project) original
    |> Result.map_error Agent_core.Error.to_string |> require in
  check bool "original unread-tagged evidence and projected output stay exact" true
    (List.map Agent_core.Checkpoint.message_to_json sent
     = List.map Agent_core.Checkpoint.message_to_json (original @ [appended]));
  check int "caller projection runs once" 1 !calls;
  match Host.project_source ~input_source:Masc.Keeper_request_source.Completion_review
      ~unread:unavailable (Some (fun _ -> Error (Agent_core.Error.Internal "projection refused"))) original with
  | Error (Agent_core.Error.Internal detail) -> check string "projection error is preserved" "projection refused" detail
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok _ -> fail "a refused projection must stay refused"

let test_native_empty_replaces_held_evidence () =
  let first=official_front (choose (Ok [hole])) in
  let initial=start_projection first ~capacity:max_int messages
    |> Result.map_error Agent_core.Error.to_string |> require in
  let started=Host.resume_prompt ~goal:"current goal" ~held:[] initial in
  let empty=official_front (choose (Ok [])) in
  let cleared=start_projection empty ~capacity:max_int messages
    |> Result.map_error Agent_core.Error.to_string |> require in
  check_carrier Frozen.empty cleared;
  let next=Host.resume_prompt ~goal:"current goal" ~held:started.held_context cleared in
  check bool "a resumed thread receives an explicit latest empty observation" true
    (resume_has_carrier next cleared);
  check bool "the stale held unread digest is replaced" false
    (next.held_context=started.held_context);
  let unchanged=Host.resume_prompt ~goal:"current goal" ~held:next.held_context cleared in
  check string "the acknowledged empty observation is not resent" "current goal" unchanged.prompt;
  let unobserved=Host.read_librarian_front None messages
    |> Result.map_error Agent_core.Error.to_string |> require in
  let unknown=start_projection unobserved ~capacity:max_int messages
    |> Result.map_error Agent_core.Error.to_string |> require in
  let expected=Frozen.of_results ~snapshot:(Error "no reader") ~memory:(Error "no reader") in
  check_carrier expected unknown;
  let resumed=Host.resume_prompt ~goal:"current goal" ~held:next.held_context unknown in
  check bool "missing observation updates the native session to unknown, never empty" true
    (resume_has_carrier resumed unknown);
  let carrier_bytes=measure_native (carrier cleared) in
  match start_projection empty ~capacity:(carrier_bytes-1) messages with
  | Error _ -> ()
  | Ok _ -> fail "the clearing carrier was inserted after input capacity accounting"

let test_managed_policy_keeps_frozen_request_evidence () =
  let key=Prompt_names.keeper_context_librarian_unread in
  require (Prompt_registry.set_override key "MANAGED_UNREAD_OBSERVATION");
  Fun.protect ~finally:(fun () -> Prompt_registry.clear_prompt_override key) @@ fun () ->
  let continuity=choose ~snapshot:(Error "unknown snapshot") (Ok [hole]) in
  let expected=Driver.request_unread continuity in
  let http=(compose continuity messages).projection.messages in
  check_carrier expected http;
  check bool "actual HTTP request consumes the managed policy" true
    (String_util.contains_substring (T.text_of_message (carrier http)) "MANAGED_UNREAD_OBSERVATION");
  let official=start_projection (official_front continuity) ~capacity:max_int messages
    |> Result.map_error Agent_core.Error.to_string |> require in
  check_carrier expected official;
  let delivered=Host.resume_prompt ~goal:"Current goal" ~held:[] official in
  check bool "actual official request consumes the same managed policy" true
    (String_util.contains_substring delivered.prompt "MANAGED_UNREAD_OBSERVATION");
  check bool "an override without JSON variables cannot omit frozen evidence" true
    (resume_has_carrier delivered official)

let test_missing_policy_carries_evidence_and_explicit_error () =
  let continuity=choose ~snapshot:(Error "unknown snapshot") (Ok [hole]) in
  let expected=Driver.request_unread continuity in
  let old=Frozen.attach ~role:T.System Frozen.empty ~include_empty:true messages in
  let empty_dir=Filename.temp_dir "unread-empty-prompts" "" in
  Prompt_registry.clear ();
  Prompt_registry.set_markdown_dir empty_dir;
  Fun.protect ~finally:(fun () ->
    Prompt_registry.clear ();
    Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
    Unix.rmdir empty_dir) @@ fun () ->
  check bool "text resolution reports a missing policy" true (Result.is_error (Frozen.text expected));
  let check_error messages =
    check_carrier expected messages;
    check bool "adapter exposes the policy error on the exact carrier" true
      (match List.assoc_opt "masc.librarian_unread_guidance_error" (carrier messages).T.metadata with
       | Some (`String detail) -> String.length detail > 0
       | Some _ | None -> false) in
  check_error (compose continuity messages).projection.messages;
  let official=Host.project_source
    ~input_source:(Masc.Keeper_request_source.Keeper_history {trace_id})
    ~unread:expected None old
    |> Result.map_error Agent_core.Error.to_string |> require in
  check_error official;
  check int "replacement removes the stale observation even without guidance" 1
    (List.length (List.filter Window.is_unread_context official));
  let delivered=Host.resume_prompt ~goal:"Continue" ~held:[] official in
  check bool "unknown snapshot and exact unread coordinates reach the official request" true
    (resume_has_carrier delivered official);
  let cleared=Frozen.attach ~include_empty:true ~role:T.System Frozen.empty official in
  check_carrier Frozen.empty cleared;
  check int "ordinary known-empty omission still retires an earlier carrier" 0
    (List.length (List.filter Window.is_unread_context
      (Frozen.attach ~role:T.User Frozen.empty official)))

let ()=
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  run "frozen librarian unread requests" ["request",[
  test_case "managed policy retains frozen evidence in HTTP and official requests" `Quick test_managed_policy_keeps_frozen_request_evidence;
  test_case "missing policy carries evidence with an explicit diagnostic" `Quick test_missing_policy_carries_evidence_and_explicit_error;
  test_case "absorbed cursor precedes one frozen ledger read and forecast" `Quick test_absorbed_freeze_and_forecast;
  test_case "snapshot and Memory uncertainty remain independent" `Quick test_independent_unknown_and_stale_snapshot;
  test_case "candidate rendering preserves canonical source hashes" `Quick test_candidate_baseline_keeps_original_source;
  test_case "capacity zero-history floor preserves evidence" `Quick test_capacity_floor_keeps_evidence;
  test_case "summary omission and native resume preserve evidence" `Quick test_summary_fallback_and_resume;
  test_case "custom official projection cannot replace evidence" `Quick test_custom_projection_cannot_replace_evidence;
  test_case "completion review keeps its own unread-tagged evidence" `Quick test_completion_review_keeps_the_projected_original;
  test_case "native known-empty and unavailable replace held evidence" `Quick test_native_empty_replaces_held_evidence]]
