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

let view ?front snapshot messages =
  let _, lines = capture_source source in
  let continuity = match Driver.prepare_continuity ~trace_id ~lines ~messages snapshot with
    | Ok value -> value | Error error -> fail (Snapshot.error_to_string error) in
  Driver.For_testing.request_view ~continuity ~provider_config
    ~measure_message_bytes:measure ~front
    ~history_digest_at:(Window.atom_opening_digest messages)
    ~current_turn_results:Driver.Current_turn_verbatim
    ~base_path:(Filename.get_temp_dir_name ()) ~demote_before:max_int
    ~turn_boundary:(Front.Turn_boundary { end_atom = snapshot.Snapshot.end_atom })
    ~materialize:(fun ~pending:_ _ -> fail "unsummarized history entered tool demotion") messages
;;

let wire (view : Driver.request_view) = match view.wire with
  | Ok messages -> messages
  | Error error -> fail (Agent_core.Llm_provider.Reasoning_history_projection.error_to_string error)
;;

let without_working_state messages =
  let is_working (m : T.message) =
    m.metadata = Runtime_model_input_tail_window.working_state_metadata
  in
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

(* A seed range reaches behind this turn, so an earlier turn's tool body in
   it goes out as a marker at the turn boundary, as it does with no
   continuity. Before, a turn with no Librarian point sent those bodies raw
   every time its range grew back over them. *)
let test_without_snapshot_seed_demotes_earlier_tool_bodies () =
  let earlier_body = String.make 4_000 'o' in
  let earlier =
    [ pinned; text T.User "Read the old log.";
      message T.Assistant [T.ToolUse {id = "old-1"; name = "read_file"; input = `Assoc []}];
      { (message T.Tool [T.ToolResult {tool_use_id = "old-1"; content = earlier_body;
          outcome = T.Tool_succeeded; json = None; content_blocks = None}])
        with tool_call_id = Some "old-1" };
      text T.Assistant "Read the log." ] in
  let this_turn = [text T.User "Continue from the log."] in
  let messages = earlier @ this_turn in
  let completed_end = snd (Window.annotate earlier) in
  let history_digest_at = Window.atom_opening_digest messages in
  let front_digest = history_digest_at 0 |> Option.get in
  let front : Front.seed = {first_atom = 0; front_digest; source = Front.Ledger} in
  let planned = ref 0 in
  let seeded =
    Driver.For_testing.request_view ~continuity:Driver.without_snapshot
      ~provider_config ~measure_message_bytes:measure ~front:(Some front)
      ~history_digest_at ~current_turn_results:Driver.Current_turn_verbatim
      ~base_path:(Filename.get_temp_dir_name ()) ~demote_before:completed_end
      ~turn_boundary:(Front.Turn_boundary { end_atom = completed_end })
      ~materialize:(fun ~pending messages -> planned := List.length pending; messages)
      messages in
  (match seeded.composed.origin with
   | Front.Carried Front.Ledger -> ()
   | _ -> fail "the range did not open on the seed");
  check int "the seed range demotes at the turn boundary" completed_end
    seeded.composed.demote_before;
  check int "the earlier turn's tool body is planned as a marker" 1 !planned
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

let test_an_old_front_does_not_drop_unread () =
  let snapshot = snapshot () in
  let suffix = [text T.User "First pending request"] @ tool_pair ()
    @ [text T.User "Second pending request"] in
  let messages = source @ suffix in
  let front_digest = Window.atom_opening_digest messages 4 |> Option.get in
  let front : Front.seed = {first_atom = 4; front_digest; source = Front.Ledger} in
  let projected = view ~front snapshot messages in
  check string "old advanced ledger cannot discard pending work" (encode (pinned :: suffix))
    (encode (without_working_state (wire projected)));
  check int "a snapshot range demotes nothing" 0 projected.composed.demote_before;
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

(* Without a snapshot the range starts at the seed when one is valid for
   this history, and only with none at the end of the last completed turn
   (RFC keeper-context-window-in-tokens §13.4). A keeper whose Librarian has
   no point yet keeps carrying the earlier turns its ledger front holds. *)
let test_without_snapshot_starts_at_the_turn_start () =
  let this_turn = [text T.User "Fresh unsummarized work"] @ tool_pair () in
  let messages = source @ this_turn in
  let completed_end = snd (Window.annotate source) in
  let project ?front ~turn_boundary () =
    Driver.For_testing.request_view ~continuity:Driver.without_snapshot
      ~provider_config ~measure_message_bytes:measure ~front
      ~history_digest_at:(Window.atom_opening_digest messages) ~current_turn_results:Driver.Current_turn_verbatim
      ~base_path:(Filename.get_temp_dir_name ()) ~demote_before:completed_end ~turn_boundary
      ~materialize:(fun ~pending:_ _ -> fail "unsummarized history entered demotion") messages in
  (* A seed older than the turn boundary: the earlier turn's assistant atom
     goes out with this turn, and the origin names the seed's source. *)
  let seed_atom = 1 in
  let front_digest = Window.atom_opening_digest messages seed_atom |> Option.get in
  let front : Front.seed = {first_atom = seed_atom; front_digest; source = Front.Ledger} in
  let seeded =
    project ~front ~turn_boundary:(Front.Turn_boundary { end_atom = completed_end }) () in
  check int "the seed, not the turn boundary, opens the range" seed_atom
    seeded.composed.projection.dropped_atoms;
  check string "the earlier turn's atom reaches the wire with this turn"
    (encode (pinned :: text T.Assistant "The build passed." :: this_turn))
    (encode (without_preamble (wire seeded)));
  check int "a seed range demotes at the turn boundary, not past it" completed_end
    seeded.composed.demote_before;
  (match seeded.composed.origin with
   | Front.Carried Front.Ledger -> ()
   | _ -> fail "the origin does not name the seed's source");
  check bool "a valid seed is not reported as outlived" true
    (Option.is_none seeded.composed.outlived_seed);
  (* A seed whose atom this history opens with another message is dropped
     and the range falls back to the turn boundary. *)
  let other_digest = Window.atom_opening_digest messages 0 |> Option.get in
  let stale : Front.seed = {first_atom = seed_atom; front_digest = other_digest; source = Front.Ledger} in
  let dropped =
    project ~front:stale ~turn_boundary:(Front.Turn_boundary { end_atom = completed_end }) () in
  check int "a seed this history does not hold falls back to the turn boundary" completed_end
    dropped.composed.projection.dropped_atoms;
  (match dropped.composed.origin with
   | Front.Turn_start {end_atom} when end_atom = completed_end -> ()
   | _ -> fail "a dropped seed still named the origin");
  (match dropped.composed.outlived_seed with
   | Some (_, Front.Front_message_differs) -> ()
   | _ -> fail "the dropped seed and its reason were not reported");
  (* No seed: the turn boundary opens the range. *)
  let project ~turn_boundary = project ?front:None ~turn_boundary () in
  let fresh = project ~turn_boundary:(Front.Turn_boundary { end_atom = 0 }) in
  check string "on a fresh history every message reaches the wire" (encode messages)
    (encode (wire fresh));
  check int "a fresh history with no seed drops nothing" 0 fresh.composed.projection.dropped_atoms;
  check int "last resort cannot demote fresh history" 0 fresh.composed.demote_before;
  (match fresh.composed.origin with
   | Front.Turn_start {end_atom = 0} -> () | _ -> fail "a fresh history not attributed to its turn start");
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
  let before =
    match Log.Ring.recent ~limit:1 () with
    | [] -> -1
    | entry :: _ -> entry.Log.Ring.seq
  in
  (match Driver.turn_start ~config ~keeper_name ~trace_id:"t" ~messages:source with
   | Front.Turn_boundary_unknown _ -> ()
   | Front.Turn_boundary { end_atom } ->
     fail (Printf.sprintf "an unreadable boundary store answered atom %d" end_atom));
  (* Reading decides nothing: the request whose range it opens reports it. *)
  check int "reading the unknown start logs no warning" 0
    (Log.Ring.recent ~since_seq:before ~min_level:(Log.level_to_int Log.Warn) ()
     |> List.filter (fun (entry : Log.Ring.entry) ->
       Option.equal String.equal entry.keeper_name (Some keeper_name))
     |> List.length)
;;

(* A boundary log whose end lines no longer match the history -- the history
   was rewritten or renumbered after they were written -- is an unknown start,
   not the start: 0 would send the whole history, the provider would refuse
   it, and the failed turn would write no end line to fix the next one. A log
   with no end line of this trace is a first turn, and that one is 0. *)
let test_turn_start_is_unknown_when_no_end_line_matches_the_history () =
  let base_path = Filename.temp_dir "turn-start-unmatched-" "" in
  let config = Masc.Workspace.default_config base_path in
  let keeper_name = "renumbered" in
  let keepers_dir = Masc.Workspace.keepers_runtime_dir config in
  (match Driver.turn_start ~config ~keeper_name ~trace_id ~messages:source with
   | Front.Turn_boundary { end_atom = 0 } -> ()
   | Front.Turn_boundary { end_atom } ->
     fail (Printf.sprintf "a log with no end line answered atom %d" end_atom)
   | Front.Turn_boundary_unknown { reason } ->
     fail ("a log with no end line answered unknown: " ^ reason));
  let position = match Boundary.position_of_messages source with
    | Ok position -> position | Error detail -> fail detail in
  mkdir_p (Filename.concat keepers_dir keeper_name);
  (match Boundary.append ~keepers_dir ~keeper_id:keeper_name
     { Boundary.recorded_at = 1.; event = Boundary.Turn_ended
         { turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1;
           history_at_start = Boundary.Fresh_history; position } } with
   | Ok () -> () | Error error -> fail (Boundary.append_error_to_string error));
  let rewritten = [pinned; text T.User "Rebuild the patch."; text T.Assistant "The rebuild passed."] in
  (match Driver.turn_start ~config ~keeper_name ~trace_id ~messages:rewritten with
   | Front.Turn_boundary_unknown _ -> ()
   | Front.Turn_boundary { end_atom } ->
     fail (Printf.sprintf "an end line that matches nothing answered atom %d" end_atom))
;;

let progress ~trace_id ~end_atom ~last_atom_digest : Progress.t =
  { position = { Progress.trace_id; end_atom; last_atom_digest }; boundary_lines_seen = 1 }
;;

let absorbed_view continuity messages =
  Driver.For_testing.request_view ~continuity ~provider_config ~measure_message_bytes:measure
    ~front:None ~history_digest_at:(Window.atom_opening_digest messages) ~current_turn_results:Driver.Current_turn_verbatim
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
    (List.exists Runtime_model_input_tail_window.is_working_state sent);
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

(* The forecast asks the driver's own chooser, so every start the driver
   can take shows up in the forecast unchanged: the origin, the atom the
   range opens on and its bytes. The first three cases hold a seed this
   history still opens with the same message, so a forecast that tried the
   seed before the Librarian point would name the seed where the driver
   names the snapshot or the read position. *)
let test_the_forecast_takes_the_drivers_start () =
  let fresh = text T.User "Fresh unsummarized work" in
  let messages = source @ [fresh] in
  let digest_at = Window.atom_opening_digest messages in
  let held_seed : Front.seed =
    {first_atom = 0; front_digest = Option.get (digest_at 0); source = Front.Ledger} in
  let outlived_seed : Front.seed =
    {first_atom = 0; front_digest = "not-the-opening-message"; source = Front.Ledger} in
  let snapshot, lines = capture_source source in
  let summarized = match Driver.prepare_continuity ~trace_id ~lines ~messages snapshot with
    | Ok continuity -> continuity | Error error -> fail (Snapshot.error_to_string error) in
  let absorbed =
    match Driver.absorbed_history ~trace_id ~messages
            (progress ~trace_id ~end_atom:1 ~last_atom_digest:(Option.get (digest_at 0))) with
    | Some (_, continuity) -> continuity
    | None -> fail "a position that matches this history was refused" in
  let boundary = Front.Turn_boundary { end_atom = 2 } in
  let unknown = Front.Turn_boundary_unknown { reason = "boundary read failed: fixture" } in
  let cases =
    [ "a fitting snapshot", summarized, Some held_seed, boundary,
      (function Front.Librarian_snapshot _ -> true | _ -> false);
      "the read position", absorbed, Some held_seed, boundary,
      (function Front.Librarian_progress { end_atom = 1 } -> true | _ -> false);
      "a held seed", Driver.without_snapshot, Some held_seed, boundary,
      (function Front.Carried Front.Ledger -> true | _ -> false);
      "an outlived seed", Driver.without_snapshot, Some outlived_seed, boundary,
      (function Front.Turn_start { end_atom = 2 } -> true | _ -> false);
      "the turn boundary", Driver.without_snapshot, None, boundary,
      (function Front.Turn_start { end_atom = 2 } -> true | _ -> false);
      "an unknown boundary", Driver.without_snapshot, None, unknown,
      (function Front.Turn_start_unknown _ -> true | _ -> false) ]
  in
  List.iter (fun (name, continuity, front, turn_boundary, expected) ->
    let driver =
      Driver.For_testing.request_view ~continuity ~provider_config
        ~measure_message_bytes:measure ~front ~history_digest_at:digest_at
        ~current_turn_results:Driver.Current_turn_verbatim
        ~base_path:(Filename.get_temp_dir_name ()) ~demote_before:0 ~turn_boundary
        ~materialize:(fun ~pending:_ messages -> messages) messages in
    let forecast =
      Masc.Keeper_next_request_forecast.carry ~measure ~continuity:(Some continuity) ~front
        ~turn_start:turn_boundary ~counted_tokens:None messages in
    check bool (name ^ ": the driver takes the start this case names") true
      (expected driver.composed.origin);
    check bool (name ^ ": the forecast names the driver's origin") true
      (forecast.origin = driver.composed.origin);
    check int (name ^ ": from the same atom")
      driver.composed.projection.dropped_atoms forecast.first_atom;
    check int (name ^ ": with the same bytes")
      driver.composed.transmitted_bytes forecast.transmitted_bytes)
    cases
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
      ~history_digest_at:(Window.atom_opening_digest messages) ~current_turn_results:Driver.Current_turn_verbatim
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
  check string "unfinished tool body remains raw" current_body
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
  (* No snapshot and no seed: the range starts at the completed boundary, so
     this turn goes raw and there is no completed body left to demote. *)
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
    ~current_turn_results:Driver.Current_turn_verbatim ~base_path ~demote_before:completed_end ~turn_boundary:(Front.Turn_boundary { end_atom = completed_end })
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
  check bool "mismatching completed atom is an unmatched history, not the start" true
    (completed_end lines mismatched = Error Snapshot.Unmatched_history);
  let baseline = List.map (fun (line, record) -> line,
    Result.map (fun (record : Boundary.record) ->
      match record.event with
      | Boundary.Turn_ended fields ->
        {record with event = Boundary.Turn_ended {fields with history_at_start = Boundary.Continued_history}}
      | _ -> record) record) lines in
  check bool "verified baseline endpoint can externalize exact older bodies" true
    (completed_end baseline resumed = Ok endpoint)
;;

(* A snapshot that cannot be used is one that does not fit, never a refused
   turn (#37762): a refused turn runs no Librarian round, so nothing would
   ever replace the snapshot. The covered bytes changing under unchanged atom
   openers, a snapshot file that cannot be read, and a boundary log that
   cannot be read each start at the Librarian's position when it is a place
   in this history, else at the turn's own boundary. *)
let test_an_unusable_snapshot_starts_without_it () =
  let covered = [pinned; text T.User "Inspect the patch"] @ tool_pair () in
  let snapshot, lines = capture_source covered in
  let rewritten = List.map (fun (m : T.message) ->
    {m with content = List.map (function
      | T.ToolResult result -> T.ToolResult {result with content = "Rewritten result"}
      | block -> block) m.content}) covered in
  let fresh = text T.User "Continue with the review" in
  let messages = rewritten @ [fresh] in
  (match Driver.prepare_continuity ~trace_id ~lines ~messages snapshot with
   | Error Snapshot.Prefix_changed -> ()
   | Ok _ | Error _ -> fail "the fixture does not change the covered bytes under the same openers");
  let end_atom = snapshot.Snapshot.end_atom in
  let digest_at = Window.atom_opening_digest messages in
  let position =
    progress ~trace_id ~end_atom ~last_atom_digest:(Option.get (digest_at (end_atom - 1))) in
  let select
        ?(read_lines = fun () -> Ok lines)
        ?(read_progress = fun () -> Ok (Some position))
        snapshot
    =
    Driver.continuity_for_request ~keeper_name:"continuity-fixture" ~trace_id ~messages
      ~snapshot ~lines:read_lines ~progress:read_progress
  in
  let origin continuity = (absorbed_view continuity messages).composed.origin in
  let starts_at_the_position label continuity =
    match origin continuity with
    | Front.Librarian_progress {end_atom = at} -> check int label end_atom at
    | _ -> fail (label ^ ": the request did not start at the Librarian's position")
  in
  starts_at_the_position "changed covered bytes start at the position"
    (select (Ok (Some snapshot)));
  (match origin (select ~read_progress:(fun () -> Ok None) (Ok (Some snapshot))) with
   | Front.Turn_start _ -> ()
   | _ -> fail "with no position the request did not start at the turn's own boundary");
  (match origin (select ~read_progress:(fun () -> Error "unreadable") (Ok (Some snapshot))) with
   | Front.Turn_start _ -> ()
   | _ -> fail "an unreadable position did not fall back to the turn's own boundary");
  starts_at_the_position "an unreadable snapshot starts at the position"
    (select ~read_lines:(fun () -> fail "the boundary log was read for a snapshot that was not")
       (Error "snapshot file is not JSON"));
  starts_at_the_position "an unreadable boundary log starts at the position"
    (select ~read_lines:(fun () -> Error "boundary log cannot be read") (Ok (Some snapshot)));
  (* A refused line after the snapshot's boundary stops the range
     (Range_stopped): no later restart settles it. *)
  let stopped_lines = lines @ [2, Error (Boundary.Not_json "torn append")] in
  (match Driver.prepare_continuity ~trace_id ~lines:stopped_lines ~messages snapshot with
   | Error (Snapshot.Range_stopped _) -> ()
   | Ok _ | Error _ -> fail "the fixture does not stop the range on a refused line");
  starts_at_the_position "a stopped range starts at the position"
    (select ~read_lines:(fun () -> Ok stopped_lines) (Ok (Some snapshot)));
  starts_at_the_position "no saved snapshot starts at the position"
    (select ~read_lines:(fun () -> fail "the boundary log was read with no snapshot saved")
       (Ok None));
  (* The history moved on from the snapshot (the goo-yang-bong branch): an
     ordinary mismatch, and the position that fits this history is used. *)
  let moved = [pinned; text T.User "Start over on the docs"; text T.Assistant "Docs drafted."; fresh] in
  let moved_digest = Window.atom_opening_digest moved in
  (match Driver.prepare_continuity ~trace_id ~lines ~messages:moved snapshot with
   | Error (Snapshot.Trace_mismatch | Snapshot.History_changed | Snapshot.Uncovered_history
           | Snapshot.Unmatched_history) -> ()
   | Ok _ | Error _ -> fail "the fixture's moved history still fits the snapshot");
  (match
     (absorbed_view
        (Driver.continuity_for_request ~keeper_name:"continuity-fixture" ~trace_id
           ~messages:moved ~snapshot:(Ok (Some snapshot)) ~lines:(fun () -> Ok lines)
           ~progress:(fun () ->
             Ok (Some (progress ~trace_id ~end_atom:2
                         ~last_atom_digest:(Option.get (moved_digest 1))))))
        moved).composed.origin
   with
   | Front.Librarian_progress {end_atom = 2} -> ()
   | _ -> fail "a snapshot of a history that moved on did not fall back to the position");
  (match origin
           (Driver.continuity_for_request ~keeper_name:"continuity-fixture" ~trace_id
              ~messages:(covered @ [fresh]) ~snapshot:(Ok (Some snapshot))
              ~lines:(fun () -> Ok lines)
              ~progress:(fun () -> Ok None))
   with
   | Front.Librarian_snapshot _ -> ()
   | _ -> fail "a snapshot that fits was not used")
;;

(* The official-client lanes take the turn's one continuity choice as a
   position in the list they cut (#37619 review). The purge shape -- a
   snapshot that no longer fits, a read position that does -- gives those
   lanes the read position, as it gives the Agent Core lane; a fitting
   snapshot gives its working state; a list that no longer holds what the
   choice covered is an error, and the lane refuses its request with it. *)
let test_official_lanes_take_the_same_choice () =
  let snapshot, lines = capture_source source in
  let moved = [pinned; text T.User "Start over on the docs"; text T.Assistant "Docs drafted.";
               text T.User "Review the docs"] in
  let digest_at = Window.atom_opening_digest moved in
  let chosen =
    Driver.continuity_for_request ~keeper_name:"continuity-fixture" ~trace_id ~messages:moved
      ~snapshot:(Ok (Some snapshot)) ~lines:(fun () -> Ok lines)
      ~progress:(fun () ->
        Ok (Some (progress ~trace_id ~end_atom:2 ~last_atom_digest:(Option.get (digest_at 1)))))
  in
  (match Driver.librarian_position ~messages:moved chosen with
   | Ok (Driver.Librarian_progress {end_atom = 2}) -> ()
   | Ok _ -> fail "the purge shape did not hand the official lane the read position"
   | Error error -> fail (Agent_core.Error.to_string error));
  let current = source @ [text T.User "Continue the review"] in
  let fitting =
    Driver.continuity_for_request ~keeper_name:"continuity-fixture" ~trace_id ~messages:current
      ~snapshot:(Ok (Some snapshot)) ~lines:(fun () -> Ok lines) ~progress:(fun () -> Ok None)
  in
  (match Driver.librarian_position ~messages:current fitting with
   | Ok (Driver.Librarian_snapshot chosen_snapshot) ->
     check int "the snapshot's end" snapshot.Snapshot.end_atom chosen_snapshot.Snapshot.end_atom
   | Ok _ -> fail "a fitting snapshot did not reach the official lane"
   | Error error -> fail (Agent_core.Error.to_string error));
  let rewritten = List.map (fun (m : T.message) ->
    if m = text T.Assistant "The build passed." then text T.Assistant "Rewritten reply" else m) current in
  (match Driver.librarian_position ~messages:rewritten fitting with
   | Error _ -> ()
   | Ok _ -> fail "a list that no longer holds the covered messages kept the Librarian front");
  (match Driver.librarian_position ~messages:current Driver.without_snapshot with
   | Ok Driver.No_position -> ()
   | Ok _ | Error _ -> fail "no absorbed point was not handed over as no position")
;;

(* A snapshot the Librarian is rewriting from atom 0 is not used until its
   end reaches its target: used now, it would move the start back and send
   what lies after its end again. An ordinary snapshot behind the position is
   used, because the atoms after its end are the latest turns, and nothing
   else in the request carries them. *)
let test_a_rewriting_snapshot_waits_for_its_target () =
  let messages = source @ [text T.User "Second request"; text T.Assistant "Second answer"] in
  let turn_line line absolute_turn history =
    let position = match Boundary.position_of_messages history with
      | Ok position -> position | Error detail -> fail detail in
    line, Ok { Boundary.recorded_at = 1.; event = Boundary.Turn_ended
      { turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn;
        history_at_start = (if line = 1 then Boundary.Fresh_history else Boundary.Continued_history);
        position } } in
  let lines = [turn_line 1 1 source; turn_line 2 2 messages] in
  let capture catch_up_end_atom =
    match Snapshot.capture_checkpoint_prefix ~end_atom:2 ~catch_up_end_atom ~trace_id ~lines
            ~messages ~working_state () with
    | Ok snapshot -> snapshot | Error error -> fail (Snapshot.error_to_string error) in
  let digest_at = Window.atom_opening_digest messages in
  let position = progress ~trace_id ~end_atom:4 ~last_atom_digest:(Option.get (digest_at 3)) in
  let origin ?(progress = fun () -> Ok (Some position)) snapshot =
    let continuity =
      Driver.continuity_for_request ~keeper_name:"continuity-fixture" ~trace_id ~messages
        ~snapshot:(Ok (Some snapshot)) ~lines:(fun () -> Ok lines) ~progress in
    (absorbed_view continuity messages).composed.origin in
  let rewriting = capture (Some 4) in
  check (option int) "the fixture is catching up" (Some 4) rewriting.Snapshot.catch_up_end_atom;
  (match origin rewriting with
   | Front.Librarian_progress {end_atom = 4} -> ()
   | _ -> fail "a snapshot short of its catch-up target was used");
  (match origin ~progress:(fun () -> Ok None) rewriting with
   | Front.Turn_start _ -> ()
   | _ -> fail "with no position a snapshot short of its target was used");
  (match origin (capture None) with
   | Front.Librarian_snapshot {end_atom = 2; _} -> ()
   | _ -> fail "an ordinary snapshot behind the position was not used")
;;

(* A runtime that cannot see an image is handed a reading of it in the
   image's place, for that candidate alone (RFC-0265 media degrade). The
   atoms do not move and nothing is rewritten, so the choice still stands;
   only the bytes under the covered atoms differ. Held to the checkpoint's
   bytes, such a candidate had every request refused (#37812). Held to its
   own rendering, it composes, and a covered message that really changed
   still refuses. *)
let test_a_candidates_own_rendering_is_what_the_check_holds_it_to () =
  let looked = message T.User [T.Text "Look at this";
    T.Image {media_type = "image/png"; data = "https://example.invalid/shot.png";
             source_type = T.Url}] in
  let read_instead = message T.User [T.Text "Look at this";
    T.Text "[unread image URL: https://example.invalid/shot.png; this runtime cannot view the image]"] in
  let history = [pinned; looked; text T.Assistant "The build passed."] in
  let projected = [pinned; read_instead; text T.Assistant "The build passed."] in
  let snapshot, lines = capture_source history in
  let chosen =
    Driver.continuity_for_request ~keeper_name:"continuity-fixture" ~trace_id ~messages:history
      ~snapshot:(Ok (Some snapshot)) ~lines:(fun () -> Ok lines) ~progress:(fun () -> Ok None)
  in
  check int "the snapshot covers the atom the image is in" 2 snapshot.Snapshot.end_atom;
  (match Driver.validate_continuity ~messages:projected chosen with
   | Error _ -> ()
   | Ok () -> fail "the fixture does not reproduce the refusal it is about");
  let for_this_candidate = Driver.continuity_for_attempt ~messages:projected chosen in
  (match Driver.validate_continuity ~messages:projected for_this_candidate with
   | Ok () -> ()
   | Error error ->
     fail ("a candidate held to its own rendering was still refused: "
           ^ Agent_core.Error.to_string error));
  (match Driver.librarian_position ~messages:projected for_this_candidate with
   | Ok (Driver.Librarian_snapshot _) -> ()
   | Ok _ -> fail "the official lane did not get the snapshot it composes from"
   | Error error -> fail (Agent_core.Error.to_string error));
  let moved_in_flight =
    [pinned; read_instead; text T.Assistant "Rewritten while the attempt was in flight"] in
  (match Driver.validate_continuity ~messages:moved_in_flight for_this_candidate with
   | Error _ -> ()
   | Ok () -> fail "a covered message that changed in flight was not refused");
  (* The read position alone is held the same way: its digest is the opening
     message of the atom before it, which the reading replaced. *)
  let digest_at = Window.atom_opening_digest history in
  let absorbed =
    Driver.continuity_for_request ~keeper_name:"continuity-fixture" ~trace_id ~messages:history
      ~snapshot:(Ok None) ~lines:(fun () -> Ok lines)
      ~progress:(fun () ->
        Ok (Some (progress ~trace_id ~end_atom:1 ~last_atom_digest:(Option.get (digest_at 0)))))
  in
  (match Driver.validate_continuity ~messages:projected absorbed with
   | Error _ -> ()
   | Ok () -> fail "the read-position fixture does not reproduce the refusal");
  (match
     Driver.validate_continuity ~messages:projected
       (Driver.continuity_for_attempt ~messages:projected absorbed)
   with
   | Ok () -> ()
   | Error error ->
     fail ("a read position held to the candidate's rendering was refused: "
           ^ Agent_core.Error.to_string error))
;;

let () = run "continuity request projection"
  ["request", [test_case "completed boundary protects resumed work" `Quick test_completed_boundary_protects_resumed_work;
               test_case "small and wide actual body projection" `Quick test_small_externalizes_only_completed_bodies;
               test_case "failed blob write retains raw body" `Quick test_failed_externalization_keeps_raw_body;
               test_case "actual wire and tool append" `Quick test_actual_wire_and_tool_append;
               test_case "old front" `Quick test_an_old_front_does_not_drop_unread;
               test_case "all covered" `Quick test_all_covered_keeps_only_working_and_pinned;
               test_case "covered prefix validation per request" `Quick test_each_request_validates_frozen_covered_messages;
               test_case "without a snapshot the range starts at the seed, else the turn start" `Quick test_without_snapshot_starts_at_the_turn_start;
               test_case "without a snapshot a seed range demotes earlier tool bodies" `Quick test_without_snapshot_seed_demotes_earlier_tool_bodies;
               test_case "the reader says unknown when the boundary store is unreadable" `Quick test_turn_start_reader_says_unknown_when_the_store_is_unreadable;
               test_case "the reader says unknown when no end line matches the history" `Quick test_turn_start_is_unknown_when_no_end_line_matches_the_history;
               test_case "absorbed history starts at the Librarian's position" `Quick
                 test_absorbed_history_starts_at_the_librarians_position;
               test_case "the forecast takes the driver's start" `Quick
                 test_the_forecast_takes_the_drivers_start;
               test_case "an unusable snapshot starts without it" `Quick
                 test_an_unusable_snapshot_starts_without_it;
               test_case "official lanes take the same choice" `Quick
                 test_official_lanes_take_the_same_choice;
               test_case "a rewriting snapshot waits for its target" `Quick
                 test_a_rewriting_snapshot_waits_for_its_target;
               test_case "a candidate's own rendering is what the check holds it to" `Quick
                 test_a_candidates_own_rendering_is_what_the_check_holds_it_to]]
