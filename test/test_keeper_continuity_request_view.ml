open Alcotest
module Driver = Masc.Keeper_turn_driver_try_provider
module Snapshot = Masc.Librarian_continuity_snapshot
module Boundary = Masc.Keeper_turn_boundaries
module Front = Masc.Keeper_carried_front
module Progress = Masc.Keeper_librarian_progress
module Window = Runtime_model_input_tail_window
module T = Agent_core.Types

let trace_id = "continuity-request"
let working_state = "Build passed. Publication still requires user approval."
let message role content = T.make_message ~role content
let text role body = message role [T.Text body]
let pinned = text T.System "Do not publish without approval."
let source = [pinned; text T.User "Build the patch."; text T.Assistant "The build passed."]

let capture_source source =
  let position = match Boundary.position_of_messages source with
    | Ok position -> position | Error detail -> fail detail in
  let lines = [1, Ok { Boundary.recorded_at = 1.; event = Boundary.Turn_ended
    { turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1;
      history_at_start = Boundary.Fresh_history; position } }] in
  match Snapshot.capture ~trace_id ~lines ~messages:source ~working_state with
  | Ok snapshot -> snapshot, lines | Error error -> fail (Snapshot.error_to_string error)
;;
let snapshot () = fst (capture_source source)

let provider_config = Agent_core.Llm_provider.Provider_config.make
  ~kind:Agent_core.Llm_provider.Provider_config.OpenAI_compat
  ~model_id:"continuity-fixture" ~base_url:"https://provider.example" ()
let measure m = String.length (Yojson.Safe.to_string (Agent_core.Checkpoint.message_to_json m))
let encode messages = Yojson.Safe.to_string (`List (List.map Agent_core.Checkpoint.message_to_json messages))

let view ?front ?(last_resort = false) snapshot messages =
  let _, lines = capture_source source in
  let continuity = match Driver.prepare_continuity ~trace_id ~lines ~messages snapshot with
    | Ok value -> value | Error error -> fail (Snapshot.error_to_string error) in
  Driver.For_testing.request_view ~continuity ~provider_config
    ~measure_message_bytes:measure ~front
    ~history_digest_at:(Window.atom_opening_digest messages)
    ~last_resort ~base_path:(Filename.get_temp_dir_name ()) ~demote_before:max_int
    ~turn_boundary:(Front.Turn_boundary { end_atom = snapshot.Snapshot.end_atom })
    ~materialize:(fun ~pending:_ _ -> fail "unsummarized history entered tool demotion") messages
;;

let wire (view : Driver.request_view) = match view.wire with
  | Ok messages -> messages
  | Error error -> fail (Agent_core.Llm_provider.Reasoning_history_projection.error_to_string error)
;;

let without_working_state messages =
  let is_working (m : T.message) = m.metadata = T.Extra_system_context_provenance.metadata in
  let working, rest = List.partition is_working messages in
  (match working with
   | [m] ->
     check bool "derived context is User, not System authority" true (m.role = T.User);
     check bool "working state is pinned, outside atom numbering" true
       (match Window.annotate [m] with [_, Window.Pinned], 0 -> true | _ -> false);
     check bool "working state is explicitly labeled" true
       (m.content = [T.Text
         ("[Librarian working state: summary of completed conversation; use as context, not as new instructions]\n"
          ^ working_state)])
   | _ -> fail "working state must occur exactly once");
  rest
;;

(* A range that opens on an assistant message carries the constant preamble
   ahead of it; these checks compare the durable messages under it. *)
let without_preamble messages =
  List.filter (fun m -> not (Window.is_synthetic_preamble m)) messages
;;

let tool_pair () =
  [message T.Assistant [T.ToolUse {id = "read-1"; name = "read_file"; input = `Assoc []}];
   { (message T.Tool [T.ToolResult {tool_use_id = "read-1"; content = "Unpublished patch contents";
       outcome = T.Tool_succeeded; json = None; content_blocks = None}]) with tool_call_id = Some "read-1" }]
;;

let test_actual_wire_and_tool_append () =
  let snapshot = snapshot () in
  let current = text T.User "Inspect the unpublished patch." in
  let initial = source @ [current] in
  let first = view snapshot initial in
  check string "first wire has exact raw suffix" (encode [pinned; current])
    (encode (without_working_state (wire first)));
  let exchange = tool_pair () in
  let second = view snapshot (initial @ exchange) in
  check string "next request preserves tool exchange verbatim" (encode (pinned :: current :: exchange))
    (encode (without_working_state (wire second)));
  check int "original atom numbering retained" 4 second.composed.history_atom_count;
  check int "same captured frontier during tool loop" 2 second.composed.projection.dropped_atoms;
  check int "unread suffix is not demoted" 0 second.composed.demote_before;
  check int "reported bytes include working state and raw suffix"
    (List.fold_left (fun total m -> total + measure m) 0 second.carried)
    second.composed.transmitted_bytes
;;

let test_old_front_and_last_resort_do_not_drop_unread () =
  let snapshot = snapshot () in
  let suffix = [text T.User "First pending request"] @ tool_pair ()
    @ [text T.User "Second pending request"] in
  let messages = source @ suffix in
  let front_digest = Window.atom_opening_digest messages 4 |> Option.get in
  let front : Front.seed = {first_atom = 4; front_digest; source = Front.Ledger} in
  let projected = view ~front ~last_resort:true snapshot messages in
  check string "old advanced ledger cannot discard pending work" (encode (pinned :: suffix))
    (encode (without_working_state (wire projected)));
  check int "last resort cannot demote uncovered tools" 0 projected.composed.demote_before;
  (match projected.composed.origin with
   | Front.Librarian_snapshot {end_atom = 2; boundary_line = 1} -> ()
   | _ -> fail "request attribution lost exact snapshot frontier")
;;

let test_all_covered_keeps_only_working_and_pinned () =
  let projected = view (snapshot ()) source in
  check string "last covered atom is not retained by clamp" (encode [pinned])
    (encode (without_working_state (wire projected)));
  check int "exclusive end can equal atom count" projected.composed.projection.atom_count
    projected.composed.projection.dropped_atoms
;;

let test_each_request_validates_frozen_covered_messages () =
  let covered = [pinned; text T.User "Inspect the patch"] @ tool_pair () in
  let snapshot, lines = capture_source covered in
  let continuity = match Driver.prepare_continuity ~trace_id ~lines ~messages:covered snapshot with
    | Ok continuity -> continuity | Error error -> fail (Snapshot.error_to_string error) in
  let accepted messages = match Driver.validate_continuity ~messages continuity with
    | Ok () -> () | Error _ -> fail "unchanged covered prefix was refused" in
  accepted covered;
  accepted (covered @ [text T.User "Continue without publishing"] @ tool_pair ());
  (* Equality is by immutable values, not physical object identity. *)
  accepted (List.map (fun (m : T.message) -> {m with content = List.map Fun.id m.content}) covered);
  accepted (text T.System "Updated current instructions" :: List.tl covered);
  let refused messages = match Driver.validate_continuity ~messages continuity with
    | Error (Agent_core.Error.Config (Agent_core.Error.InvalidConfig {field = "librarian.continuity"; _})) -> ()
    | _ -> fail "changed covered prefix did not fail with typed continuity error" in
  refused [pinned; text T.User "Inspect the patch"];
  refused (List.map (fun (m : T.message) ->
    {m with content = List.map (function
      | T.ToolResult result -> T.ToolResult {result with content = "Rewritten result"}
      | block -> block) m.content}) covered);
  (match Driver.prepare_continuity ~trace_id:"another-trace" ~lines ~messages:covered snapshot with
   | Error Snapshot.Trace_mismatch -> () | _ -> fail "dispatch accepted another trace's snapshot")
;;

(* Without a snapshot the range starts at the end of the last completed turn
   (RFC keeper-context-window-in-tokens §13.4). An older eviction front does
   not move it either way: on a fresh history everything goes, and on a
   history with completed turns only this turn's own atoms go. *)
let test_without_snapshot_starts_at_the_turn_start () =
  let this_turn = [text T.User "Fresh unsummarized work"] @ tool_pair () in
  let messages = source @ this_turn in
  let front_digest = Window.atom_opening_digest messages 3 |> Option.get in
  let front : Front.seed = {first_atom = 3; front_digest; source = Front.Ledger} in
  let project ~turn_boundary = Driver.For_testing.request_view ~continuity:Driver.without_snapshot
    ~provider_config ~measure_message_bytes:measure ~front:(Some front)
    ~history_digest_at:(Window.atom_opening_digest messages) ~last_resort:true
    ~base_path:(Filename.get_temp_dir_name ()) ~demote_before:max_int ~turn_boundary
    ~materialize:(fun ~pending:_ _ -> fail "fresh history entered demotion") messages in
  let fresh = project ~turn_boundary:(Front.Turn_boundary { end_atom = 0 }) in
  check string "on a fresh history every message reaches the wire" (encode messages)
    (encode (wire fresh));
  check int "an older front cannot discard unsummarized history" 0 fresh.composed.projection.dropped_atoms;
  check int "last resort cannot demote fresh history" 0 fresh.composed.demote_before;
  (match fresh.composed.origin with
   | Front.Turn_start {end_atom = 0} -> () | _ -> fail "a fresh history attributed to an old front");
  let completed_end = snd (Window.annotate source) in
  let continued = project ~turn_boundary:(Front.Turn_boundary { end_atom = completed_end }) in
  check int "with completed turns the range starts where the last one ended" completed_end
    continued.composed.projection.dropped_atoms;
  check string "only this turn's own atoms reach the wire, the pinned message in place"
    (encode (pinned :: this_turn)) (encode (wire continued));
  (match continued.composed.origin with
   | Front.Turn_start {end_atom} when end_atom = completed_end -> ()
   | _ -> fail "the origin does not name the turn start");
  (* A boundary at or past the newest atom: the range still carries that atom
     and the origin names the boundary, not the atom it opened on. *)
  let _, atom_count = Window.annotate messages in
  let past_the_end = project ~turn_boundary:(Front.Turn_boundary { end_atom = atom_count + 5 }) in
  check int "a boundary past the newest atom still carries that atom" (atom_count - 1)
    past_the_end.composed.projection.dropped_atoms;
  (match past_the_end.composed.origin with
   | Front.Turn_start {end_atom} when end_atom = atom_count + 5 -> ()
   | _ -> fail "the origin does not name the boundary past the end");
  (* An unknown boundary: the range opens on the newest atom alone and the
     origin carries the reader's reason (§13.4). *)
  let reason = "boundary read failed: fixture" in
  let unknown = project ~turn_boundary:(Front.Turn_boundary_unknown { reason }) in
  check int "an unknown turn start opens on the newest atom alone" (atom_count - 1)
    unknown.composed.projection.dropped_atoms;
  (match unknown.composed.origin with
   | Front.Turn_start_unknown { reason = said } when String.equal said reason -> ()
   | _ -> fail "the origin does not name the unknown turn start");
  (match Driver.validate_continuity ~messages:[] Driver.without_snapshot with
   | Ok () -> () | Error _ -> fail "the snapshot-less path borrowed stale prefix obligations")
;;

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then (mkdir_p (Filename.dirname dir); Sys.mkdir dir 0o755)
;;

(* The reader answers Turn_boundary_unknown, not 0, when the boundary store
   cannot be read: here the log's path is a directory. *)
let test_turn_start_reader_says_unknown_when_the_store_is_unreadable () =
  let base_path = Filename.temp_dir "turn-start-unknown-" "" in
  let config = Masc.Workspace.default_config base_path in
  let keeper_name = "reader" in
  mkdir_p (Filename.concat
    (Filename.concat (Masc.Workspace.keepers_runtime_dir config) keeper_name) "turn-boundaries.jsonl");
  (match Driver.turn_start ~config ~keeper_name ~trace_id:"t" ~messages:source with
   | Front.Turn_boundary_unknown _ -> ()
   | Front.Turn_boundary { end_atom } ->
     fail (Printf.sprintf "an unreadable boundary store answered atom %d" end_atom))
;;

let progress ~trace_id ~end_atom ~last_atom_digest : Progress.t =
  { position = { Progress.trace_id; end_atom; last_atom_digest }; boundary_lines_seen = 1 }
;;

let absorbed_view continuity messages =
  Driver.For_testing.request_view ~continuity ~provider_config ~measure_message_bytes:measure
    ~front:None ~history_digest_at:(Window.atom_opening_digest messages) ~last_resort:false
    ~base_path:(Filename.get_temp_dir_name ()) ~demote_before:max_int
    (* Unread under a position: the range starts at the position itself. *)
    ~turn_boundary:(Front.Turn_boundary { end_atom = 0 })
    ~materialize:(fun ~pending:_ _ -> fail "absorbed history entered demotion") messages
;;

(* A saved continuity snapshot that no longer fits, and a Librarian position
   that does: the request starts at the position, nothing summarizes what
   lies before it, and a position of another trace, over a message this
   history does not hold, or past its end is no front at all. *)
let test_absorbed_history_starts_at_the_librarians_position () =
  let fresh = text T.User "Fresh unsummarized work" in
  let messages = source @ [fresh] @ tool_pair () in
  let _, atom_count = Window.annotate messages in
  let digest_at = Window.atom_opening_digest messages in
  let read_one = progress ~trace_id ~end_atom:1 ~last_atom_digest:(Option.get (digest_at 0)) in
  let end_atom, continuity = match Driver.absorbed_history ~trace_id ~messages read_one with
    | Some value -> value | None -> fail "a position that matches this history was refused" in
  check int "the position is the front" 1 end_atom;
  let projected = absorbed_view continuity messages in
  (match projected.composed.origin with
   | Front.Librarian_progress {end_atom = 1} -> ()
   | _ -> fail "the request was not attributed to the Librarian's position");
  check int "the read atom is not sent again" 1 projected.composed.projection.dropped_atoms;
  let sent = wire projected in
  check bool "the pinned message stays" true (List.mem pinned sent);
  check bool "the absorbed atom is gone" false (List.mem (text T.User "Build the patch.") sent);
  check bool "the unread atom is sent" true (List.mem fresh sent);
  check bool "no working state is invented" false
    (List.exists (fun (m : T.message) -> m.metadata = T.Extra_system_context_provenance.metadata) sent);
  (match Driver.validate_continuity ~messages continuity with
   | Ok () -> () | Error _ -> fail "the position it was built from failed its own check");
  let read_all =
    progress ~trace_id ~end_atom:atom_count ~last_atom_digest:(Option.get (digest_at (atom_count - 1))) in
  (match Driver.absorbed_history ~trace_id ~messages read_all with
   | Some (end_atom, at_end) ->
     check int "a Librarian that read everything stands at the end" atom_count end_atom;
     let projected = absorbed_view at_end messages in
     check int "every atom is dropped" atom_count projected.composed.projection.dropped_atoms;
     check bool "no history atom is on the wire" false (List.mem fresh (wire projected));
     check bool "the pinned message still is" true (List.mem pinned (wire projected))
   | None -> fail "a position at the end of this history was refused");
  check bool "another trace's position is no front" true
    (Option.is_none (Driver.absorbed_history ~trace_id:"another-trace" ~messages read_one));
  check bool "a position over a message this history does not hold is no front" true
    (Option.is_none (Driver.absorbed_history ~trace_id ~messages
       (progress ~trace_id ~end_atom:1 ~last_atom_digest:"not-the-opening-message")));
  check bool "a position past this history is no front" true
    (Option.is_none (Driver.absorbed_history ~trace_id ~messages
       (progress ~trace_id ~end_atom:(atom_count + 1) ~last_atom_digest:(Option.get (digest_at 0)))));
  let changed = List.map (fun (m : T.message) ->
    if m = text T.User "Build the patch." then text T.User "Rewritten under the position" else m) messages in
  (match Driver.validate_continuity ~messages:changed continuity with
   | Error _ -> () | Ok () -> fail "a history that changed under the position passed its check")
;;

let exchange id body =
  [message T.Assistant [T.ToolUse {id; name = "read_file"; input = `Assoc []}];
   { (message T.Tool [T.ToolResult {tool_use_id = id; content = body;
       outcome = T.Tool_succeeded; json = None; content_blocks = None}]) with tool_call_id = Some id }]
;;

let body_for id messages =
  List.find_map (fun (m : T.message) -> List.find_map (function
    | T.ToolResult result when result.tool_use_id = id -> Some result.content
    | _ -> None) m.content) messages |> Option.get
;;

let test_small_externalizes_only_completed_bodies () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "input-policy-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) @@ fun () ->
  let store = Tool_blob_store.create ~base_path in
  let older_body = String.make 8000 'o' and current_body = String.make 8000 'c' in
  let older = exchange "older" older_body in
  let completed = source @ older in
  let current = [text T.User "Approval is still required."] @ exchange "unfinished" current_body in
  let messages = completed @ current in
  let original = encode messages in
  let completed_end = snd (Window.annotate completed) in
  (* The Librarian is one turn behind: its snapshot covers [source], so the
     request carries the completed "older" exchange and this turn. That is
     where a completed body is still on the wire to demote. *)
  let behind =
    let snapshot, lines = capture_source source in
    match Driver.prepare_continuity ~trace_id ~lines ~messages snapshot with
    | Ok value -> value | Error error -> fail (Snapshot.error_to_string error) in
  let carried = pinned :: (older @ current) in
  let project ?(base_path = base_path) ?(continuity = Some behind) policy =
    Driver.For_testing.request_view ~input_policy:policy ?continuity
      ~provider_config ~measure_message_bytes:measure ~front:None
      ~history_digest_at:(Window.atom_opening_digest messages) ~last_resort:true
      ~base_path ~demote_before:completed_end ~turn_boundary:(Front.Turn_boundary { end_atom = completed_end })
      ~materialize:(fun ~pending messages ->
        (Masc.Keeper_model_input_demotion.materialize ~store
          ~addresses:(Masc.Keeper_model_input_demotion.create_address_memo ())
          ~pending messages).messages) messages |> wire in
  let small = project Small |> without_working_state in
  check bool "a range opening on the older exchange's assistant carries the preamble" true
    (List.exists Window.is_synthetic_preamble small);
  let small = without_preamble small in
  check string "Small without continuity also protects unfinished work" current_body
    (body_for "unfinished" (project ~continuity:None Small));
  check int "externalization does not omit messages" (List.length carried) (List.length small);
  check string "unfinished tool body remains raw even after refusal" current_body
    (body_for "unfinished" small);
  check bool "non-tool obligations are unchanged" true
    (List.mem (List.hd current) small);
  (match Tool_output.decode_from_agent_core (body_for "older" small) with
   | Tool_output.Decoded reference ->
     (match Tool_blob_store.fetch store ~sha256:reference.sha256 with
      | Ok (Some bytes) -> check string "reference retrieves exact original" older_body bytes
      | _ -> fail "materialized reference is not readable")
   | _ -> fail "small policy did not externalize completed tool body");
  check string "wide keeps exact raw source" (encode carried)
    (encode (project Wide |> without_working_state |> without_preamble));
  check string "disabled store/reader path keeps exact raw source" (encode carried)
    (encode (project ~base_path:"" Small |> without_working_state |> without_preamble));
  (* No snapshot at all: the range starts at the completed boundary, so this
     turn goes raw and there is no completed body left to demote. *)
  check string "without a snapshot only this turn goes, raw" (encode (pinned :: current))
    (encode (project ~continuity:(Some Driver.without_snapshot) Small));
  let snapshot, lines = capture_source completed in
  let continuity = match Driver.prepare_continuity ~trace_id ~lines ~messages snapshot with
    | Ok value -> value | Error error -> fail (Snapshot.error_to_string error) in
  let summarized = project ~continuity:(Some continuity) Small |> without_working_state in
  check string "covered prefix excluded, unfinished suffix intact" (encode (pinned :: current))
    (encode summarized);
  check string "durable source values unchanged" original (encode messages)
;;

let test_failed_externalization_keeps_raw_body () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "input-policy-write-failure-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) @@ fun () ->
  let obstacle = open_out (Filename.concat base_path ".masc") in close_out obstacle;
  let blocked = exchange "blocked" (String.make 8000 'b') in
  let completed = source @ blocked in
  let this_turn = [text T.User "Next turn."] in
  let messages = completed @ this_turn in
  let completed_end = snd (Window.annotate completed) in
  let behind =
    let snapshot, lines = capture_source source in
    match Driver.prepare_continuity ~trace_id ~lines ~messages snapshot with
    | Ok value -> value | Error error -> fail (Snapshot.error_to_string error) in
  let reverted = ref 0 in
  let projected = Driver.For_testing.request_view ~input_policy:Small
    ~continuity:behind ~provider_config ~measure_message_bytes:measure
    ~front:None ~history_digest_at:(Window.atom_opening_digest messages)
    ~last_resort:false ~base_path ~demote_before:completed_end ~turn_boundary:(Front.Turn_boundary { end_atom = completed_end })
    ~materialize:(fun ~pending messages ->
      let outcome = Masc.Keeper_model_input_demotion.materialize
        ~store:(Tool_blob_store.create ~base_path)
        ~addresses:(Masc.Keeper_model_input_demotion.create_address_memo ()) ~pending messages in
      reverted := outcome.reverted; outcome.messages) messages in
  check int "failed blob write reverted" 1 !reverted;
  check string "failed store never leaves a dangling marker" (encode (pinned :: (blocked @ this_turn)))
    (encode (wire projected |> without_working_state |> without_preamble))
;;

let test_completed_boundary_protects_resumed_work () =
  let completed = source @ exchange "completed" (String.make 8000 'd') in
  let _, lines = capture_source completed in
  let resumed = completed @ [text T.User "Still awaiting approval"]
    @ exchange "resumed-unfinished" (String.make 8000 'u') in
  let endpoint = snd (Window.annotate completed) in
  let completed_end lines messages = Driver.completed_history_end ~trace_id ~lines ~messages in
  check bool "seed can contain resumed work beyond completed boundary" true
    (snd (Window.annotate resumed) > endpoint);
  check bool "typed completed endpoint excludes all resumed work" true
    (completed_end lines resumed = Ok endpoint);
  check bool "absence of source evidence never guesses seed length" true
    (completed_end [] resumed = Error Snapshot.Uncovered_history);
  let restarted = lines @ [2, Ok { Boundary.recorded_at = 2.;
    event = Boundary.History_restarted {trace_id} }] in
  check bool "restart invalidates older completed endpoint" true
    (completed_end restarted resumed = Error Snapshot.Uncovered_history);
  let mismatched = List.map (fun (m : T.message) ->
    match m.content with
    | [T.ToolUse fields] when fields.id = "completed" ->
      {m with content = [T.ToolUse {fields with id = "changed"}]}
    | _ -> m) resumed in
  check bool "mismatching completed atom never authorizes demotion" true
    (Result.is_error (completed_end lines mismatched));
  let baseline = List.map (fun (line, record) -> line,
    Result.map (fun (record : Boundary.record) ->
      match record.event with
      | Boundary.Turn_ended fields ->
        {record with event = Boundary.Turn_ended {fields with history_at_start = Boundary.Continued_history}}
      | _ -> record) record) lines in
  check bool "verified baseline endpoint can externalize exact older bodies" true
    (completed_end baseline resumed = Ok endpoint)
;;

let () = run "continuity request projection"
  ["request", [test_case "completed boundary protects resumed work" `Quick test_completed_boundary_protects_resumed_work;
               test_case "small and wide actual body projection" `Quick test_small_externalizes_only_completed_bodies;
               test_case "failed blob write retains raw body" `Quick test_failed_externalization_keeps_raw_body;
               test_case "actual wire and tool append" `Quick test_actual_wire_and_tool_append;
               test_case "old front and last resort" `Quick test_old_front_and_last_resort_do_not_drop_unread;
               test_case "all covered" `Quick test_all_covered_keeps_only_working_and_pinned;
               test_case "covered prefix validation per request" `Quick test_each_request_validates_frozen_covered_messages;
               test_case "without a snapshot the range starts at the turn start" `Quick test_without_snapshot_starts_at_the_turn_start;
               test_case "the reader says unknown when the boundary store is unreadable" `Quick test_turn_start_reader_says_unknown_when_the_store_is_unreadable;
               test_case "absorbed history starts at the Librarian's position" `Quick
                 test_absorbed_history_starts_at_the_librarians_position]]
