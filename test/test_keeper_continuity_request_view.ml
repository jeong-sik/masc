open Alcotest
module Driver = Masc.Keeper_turn_driver_try_provider

(* [Driver.For_testing.request_view] over a store that holds no media: these
   histories carry text and tool blocks only. *)
let request_view ?continuity ?completed_arguments ?held_window ?tools ~provider_config
    ~measure_message_bytes ~front ~accepted ~history_digest_at ~current_turn_results
    ~base_path ~turn_boundary ~materialize messages =
  match
    Driver.For_testing.request_view ?continuity ?completed_arguments ?held_window ?tools
      ~prepare_request_media:(fun _selected -> Ok (fun messages -> Ok messages))
      ~provider_config ~measure_message_bytes
      ~measure_wire_bytes:(Masc.Keeper_model_input_wire_bytes.measurer ~config:provider_config)
      ~front ~accepted ~history_digest_at
      ~current_turn_results ~base_path ~turn_boundary ~materialize
      ~to_wire:(Agent_core.History.to_wire_message (Agent_core.History.Memory_store.create ())) messages
  with
  | Ok view -> view
  | Error error -> Alcotest.fail (Agent_core.Error.to_string error)

module Snapshot = Masc.Librarian_continuity_snapshot
module Boundary = Masc.Keeper_turn_boundaries
module Front = Masc.Keeper_carried_front
module Point = Masc.Keeper_covered_point
module Window = Runtime_model_input_tail_window
module T = Agent_core.Types

let trace_id = "continuity-request"
let working_state = "Build passed. Publication still requires user approval."
let message role content = T.make_message ~role content
let text role body = message role [T.Text body]
let pinned = text T.System "Do not publish without approval."
let source = [pinned; text T.User "Build the patch."; text T.Assistant "The build passed."]

(* The Memory writer's read end at [end_atom], with the working state it
   committed ([state], the fixture's by default). *)
let read_end ?(state = Some working_state) end_atom =
  Driver.Covered { Driver.end_atom; working_state = state }
;;

(* Every atom of [source] is read. *)
let source_end = snd (Window.annotate source)

(* The boundary log's one completed turn over [source]. *)
let boundary_lines source =
  let position = match Boundary.position_of_messages source with
    | Ok position -> position | Error detail -> fail detail in
  [1, Ok { Boundary.recorded_at = 1.; event = Boundary.Turn_ended
    { task_context = Masc.Keeper_turn_task_context.No_task; turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1;
      history_at_start = Boundary.Fresh_history; position } }]
;;

let provider_config = Agent_core.Llm_provider.Provider_config.make
  ~kind:Agent_core.Llm_provider.Provider_config.OpenAI_compat
  ~model_id:"continuity-fixture" ~base_url:"https://provider.example" ()
let measure m = String.length (Yojson.Safe.to_string (Agent_core.Checkpoint.message_to_json m))
let encode messages = Yojson.Safe.to_string (`List (List.map Agent_core.Checkpoint.message_to_json messages))

(* A request over [messages] whose writer read all of [source]. *)
let view ?front ?held_window messages =
  request_view ?held_window ~continuity:(read_end source_end) ~provider_config
    ~measure_message_bytes:measure ~accepted:None ~front
    ~history_digest_at:(Window.atom_opening_digest messages)
    ~current_turn_results:Driver.Current_turn_verbatim
    ~base_path:(Filename.get_temp_dir_name ())
    ~turn_boundary:(Front.Turn_boundary { end_atom = source_end })
    ~materialize:(fun ~pending:_ _ -> fail "unsummarized history entered tool demotion") messages
;;

(* The messages the dialect's projection keeps, in history form. *)
let wire (view : Driver.request_view) = match view.transmitted with
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

(* A seed range reaches behind this turn, and an earlier turn's tool body in
   it goes out exactly as the range first sent it: rewriting it when the turn
   boundary moves would change the prefix the provider cached. *)
let test_without_a_read_end_a_seed_range_sends_earlier_tool_bodies_as_sent () =
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
  let front : Front.seed = {first_atom = 0; front = Model_input_front.At_atom front_digest; source = Front.Ledger} in
  let planned = ref 0 in
  let seeded =
    request_view ~continuity:Driver.No_read_end
      ~provider_config ~measure_message_bytes:measure ~accepted:None ~front:(Some front)
      ~history_digest_at ~current_turn_results:Driver.Current_turn_verbatim
      ~base_path:(Filename.get_temp_dir_name ())
      ~turn_boundary:(Front.Turn_boundary { end_atom = completed_end })
      ~materialize:(fun ~pending messages -> planned := List.length pending; messages)
      messages in
  (match seeded.composed.origin with
   | Front.Carried Front.Ledger -> ()
   | _ -> fail "the range did not open on the seed");
  check int "nothing is demoted at the turn boundary" 0 seeded.composed.demote_before;
  check int "no tool body is planned as a marker" 0 !planned;
  check bool "the earlier turn's tool body goes raw" true
    (List.exists (fun (m : T.message) -> List.exists (function
       | T.ToolResult result -> String.equal result.content earlier_body
       | _ -> false) m.content) (wire seeded))
;;

let test_actual_wire_and_tool_append () =
  let current = text T.User "Inspect the unpublished patch." in
  let initial = source @ [current] in
  let first = view initial in
  check string "first wire has exact raw suffix" (encode [pinned; current])
    (encode (without_working_state (wire first)));
  let exchange = tool_pair () in
  let second = view (initial @ exchange) in
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
  let suffix = [text T.User "First pending request"] @ tool_pair ()
    @ [text T.User "Second pending request"] in
  let messages = source @ suffix in
  let front_digest = Window.atom_opening_digest messages 4 |> Option.get in
  let front : Front.seed = {first_atom = 4; front = Model_input_front.At_atom front_digest; source = Front.Ledger} in
  let projected = view ~front messages in
  check string "old advanced ledger cannot discard pending work" (encode (pinned :: suffix))
    (encode (without_working_state (wire projected)));
  check int "a read-end range demotes nothing" 0 projected.composed.demote_before;
  (match projected.composed.origin with
   | Front.Covered {end_atom = 2} -> ()
   | _ -> fail "request attribution lost the exact read end")
;;

let test_all_covered_keeps_only_working_and_pinned () =
  let projected = view source in
  check string "last covered atom is not retained by clamp" (encode [pinned])
    (encode (without_working_state (wire projected)));
  check int "exclusive end can equal atom count" projected.composed.projection.atom_count
    projected.composed.projection.dropped_atoms
;;

(* Without a read end the range starts at the seed when one is valid for
   this history, and only with none at the end of the last completed turn
   (RFC keeper-context-window-in-tokens §13.4). A keeper whose writer has
   read nothing yet keeps carrying the earlier turns its ledger front holds. *)
let test_without_a_read_end_the_range_starts_at_the_turn_start () =
  let this_turn = [text T.User "Fresh unsummarized work"] @ tool_pair () in
  let messages = source @ this_turn in
  let completed_end = snd (Window.annotate source) in
  let project ?front ~turn_boundary () =
    request_view ~continuity:Driver.No_read_end
      ~provider_config ~measure_message_bytes:measure ~accepted:None ~front
      ~history_digest_at:(Window.atom_opening_digest messages) ~current_turn_results:Driver.Current_turn_verbatim
      ~base_path:(Filename.get_temp_dir_name ()) ~turn_boundary
      ~materialize:(fun ~pending:_ _ -> fail "unsummarized history entered demotion") messages in
  (* A seed older than the turn boundary: the earlier turn's assistant atom
     goes out with this turn, and the origin names the seed's source. *)
  let seed_atom = 1 in
  let front_digest = Window.atom_opening_digest messages seed_atom |> Option.get in
  let front : Front.seed = {first_atom = seed_atom; front = Model_input_front.At_atom front_digest; source = Front.Ledger} in
  let seeded =
    project ~front ~turn_boundary:(Front.Turn_boundary { end_atom = completed_end }) () in
  check int "the seed, not the turn boundary, opens the range" seed_atom
    seeded.composed.projection.dropped_atoms;
  check string "the earlier turn's atom reaches the wire with this turn"
    (encode (pinned :: text T.Assistant "The build passed." :: this_turn))
    (encode (without_preamble (wire seeded)));
  check int "a seed range demotes nothing at the turn boundary" 0
    seeded.composed.demote_before;
  (match seeded.composed.origin with
   | Front.Carried Front.Ledger -> ()
   | _ -> fail "the origin does not name the seed's source");
  check bool "a valid seed is not reported as outlived" true
    (Option.is_none seeded.composed.outlived_seed);
  (* A seed whose atom this history opens with another message is dropped
     and the range falls back to the turn boundary. *)
  let other_digest = Window.atom_opening_digest messages 0 |> Option.get in
  let stale : Front.seed = {first_atom = seed_atom; front = Model_input_front.At_atom (other_digest); source = Front.Ledger} in
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
   | _ -> fail "the origin does not name the unknown turn start")
;;

let read_end_view continuity messages =
  request_view ~continuity ~provider_config ~measure_message_bytes:measure
    ~accepted:None ~front:None ~history_digest_at:(Window.atom_opening_digest messages) ~current_turn_results:Driver.Current_turn_verbatim
    ~base_path:(Filename.get_temp_dir_name ())
    (* Unread under a read end: the range starts at the read end itself. *)
    ~turn_boundary:(Front.Turn_boundary { end_atom = 0 })
    ~materialize:(fun ~pending:_ _ -> fail "read history entered demotion") messages
;;

(* A read end with no working state: the request starts there, and nothing
   summarizes what lies before it. A read end at the end of the history
   leaves only the pinned messages. *)
let test_a_read_end_alone_starts_there () =
  let fresh = text T.User "Fresh unsummarized work" in
  let messages = source @ [fresh] @ tool_pair () in
  let _, atom_count = Window.annotate messages in
  let projected = read_end_view (read_end ~state:None 1) messages in
  (match projected.composed.origin with
   | Front.Covered {end_atom = 1} -> ()
   | _ -> fail "the request was not attributed to the read end");
  check int "the read atom is not sent again" 1 projected.composed.projection.dropped_atoms;
  let sent = wire projected in
  check bool "the pinned message stays" true (List.mem pinned sent);
  check bool "the read atom is gone" false (List.mem (text T.User "Build the patch.") sent);
  check bool "the unread atom is sent" true (List.mem fresh sent);
  check bool "no working state is invented" false
    (List.exists Runtime_model_input_tail_window.is_working_state sent);
  let at_end = read_end_view (read_end ~state:None atom_count) messages in
  check int "every atom is dropped" atom_count at_end.composed.projection.dropped_atoms;
  check bool "no history atom is on the wire" false (List.mem fresh (wire at_end));
  check bool "the pinned message still is" true (List.mem pinned (wire at_end))
;;

(* What the view says becomes the turn's continuity (RFC
   librarian-call-only-proposes §11.1). Only a read end that is a place in
   this history is one, and only it carries the working state. With no
   view, nothing read, or a read end that is no place here, the request
   starts at the seed or at the turn's boundary, and the note says why. *)
let test_the_view_gives_the_continuity () =
  let messages = source @ [text T.User "Fresh unsummarized work"] in
  let state = Some working_state in
  let read place = Driver.continuity_of_read (Ok { Point.place; working_state = state }) in
  (match read (Point.Covered { end_atom = 1 }) with
   | Driver.Covered { Driver.end_atom = 1; working_state = Some said }, None ->
     check string "the read end carries the committed working state" working_state said
   | _ -> fail "a read end in this history was not the continuity");
  (match read Point.Nothing_read with
   | Driver.No_read_end, Some Driver.Nothing_read -> ()
   | _ -> fail "a writer that read nothing gave a read end");
  (match read (Point.Front_unresolved (Point.Other_trace { covered = "another-trace" })) with
   | Driver.No_read_end, Some (Driver.Read_end_unresolved (Point.Other_trace _)) -> ()
   | _ -> fail "a read end on another trace gave a read end");
  (match Driver.continuity_of_read (Error `Booting) with
   | Driver.No_read_end, Some (Driver.No_view `Booting) -> ()
   | _ -> fail "a writer still opening its store gave a read end");
  (match Driver.continuity_of_read (Error (`Stopped Masc.Librarian_store.Memory_unreadable)) with
   | Driver.No_read_end, Some (Driver.No_view (`Stopped Masc.Librarian_store.Memory_unreadable)) -> ()
   | _ -> fail "a stopped store gave a read end");
  (match (read_end_view (fst (read Point.Nothing_read)) messages).composed.origin with
   | Front.Turn_start { end_atom = 0 } -> ()
   | _ -> fail "a turn with no read end did not start at its own boundary")
;;

(* The forecast asks the driver's own chooser, so every start the driver
   can take shows up in the forecast unchanged: the origin, the atom the
   range opens on and its bytes. The first three cases hold a seed this
   history still opens with the same message, so a forecast that tried the
   seed before the Librarian point would name the seed where the driver
   names the read end. *)
let test_the_forecast_takes_the_drivers_start () =
  let fresh = text T.User "Fresh unsummarized work" in
  let messages = source @ [fresh] in
  let digest_at = Window.atom_opening_digest messages in
  let held_seed : Front.seed =
    {first_atom = 0; front = Model_input_front.At_atom (Option.get (digest_at 0)); source = Front.Ledger} in
  let outlived_seed : Front.seed =
    {first_atom = 0; front = Model_input_front.At_atom ("not-the-opening-message"); source = Front.Ledger} in
  let with_state = read_end source_end in
  let alone = read_end ~state:None 1 in
  let boundary = Front.Turn_boundary { end_atom = 2 } in
  let unknown = Front.Turn_boundary_unknown { reason = "boundary read failed: fixture" } in
  (* The start the provider last accepted, as the turn record keeps it
     (RFC librarian-lifecycle §4.10, rule 2): past the read end, so both
     the driver and the forecast open there. *)
  let accepted : Front.seed =
    {first_atom = 2; front = Model_input_front.At_atom (Option.get (digest_at 2)); source = Front.Turn_record { turn = 3 }} in
  let cases =
    [ "a read end with its working state", with_state, Some held_seed, None, boundary,
      (function Front.Covered { end_atom = 2 } -> true | _ -> false);
      "a read end alone", alone, Some held_seed, None, boundary,
      (function Front.Covered { end_atom = 1 } -> true | _ -> false);
      "an accepted start past the read end", alone, Some held_seed, Some accepted, boundary,
      (function
        | Front.Past_librarian_point
            { librarian_end_atom = 1; source = Front.Turn_record { turn = 3 } } -> true
        | _ -> false);
      "a held seed", Driver.No_read_end, Some held_seed, None, boundary,
      (function Front.Carried Front.Ledger -> true | _ -> false);
      "an outlived seed", Driver.No_read_end, Some outlived_seed, None, boundary,
      (function Front.Turn_start { end_atom = 2 } -> true | _ -> false);
      "the turn boundary", Driver.No_read_end, None, None, boundary,
      (function Front.Turn_start { end_atom = 2 } -> true | _ -> false);
      "an unknown boundary", Driver.No_read_end, None, None, unknown,
      (function Front.Turn_start_unknown _ -> true | _ -> false) ]
  in
  List.iter (fun (name, continuity, front, accepted, turn_boundary, expected) ->
    let driver =
      request_view ~continuity ~provider_config
        ~measure_message_bytes:measure ~accepted ~front ~history_digest_at:digest_at
        ~current_turn_results:Driver.Current_turn_verbatim
        ~base_path:(Filename.get_temp_dir_name ()) ~turn_boundary
        ~materialize:(fun ~pending:_ messages -> messages) messages in
    let forecast =
      Masc.Keeper_next_request_forecast.carry ~measure ~continuity:(Some continuity) ~accepted ~front
        ~turn_start:turn_boundary ~this_turn_start:None
        ~counted_tokens:None messages in
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

(* A window that stays carries the working state it carried when it
   opened, whatever the read end's says now, and none when it opened with
   none.
   A window that opened anywhere else carries the read end's. *)
let test_a_window_that_stays_keeps_its_working_state () =
  let messages = source @ [ text T.User "Publish it now." ] in
  let opened_at = source_end in
  let carried ?held_window () =
    List.filter_map
      (fun (m : T.message) ->
         if m.metadata = Runtime_model_input_tail_window.working_state_metadata
         then Some m.content
         else None)
      (wire (view ?held_window messages))
  in
  let held ~at working_state =
    { Driver.window_opened_at = at; markers_before = 0; working_state }
  in
  let opened_with = "[Librarian working state: the summary the window opened with]" in
  let current = [ [ T.Text (Driver.working_state_text working_state) ] ] in
  check bool "a window that stays carries the text it opened with" true
    (carried ~held_window:(held ~at:opened_at (Some opened_with)) ()
     = [ [ T.Text opened_with ] ]);
  check bool "and none when it opened with none" true
    (carried ~held_window:(held ~at:opened_at None) () = []);
  check bool "a window that opened elsewhere carries the read end's" true
    (carried ~held_window:(held ~at:(opened_at + 1) (Some opened_with)) () = current);
  check bool "with nothing held, the read end's" true (carried () = current)
;;

(* RFC librarian-lifecycle §4.10: a read end is still the Librarian point
   when the provider last accepted a later start. The range opens at that
   start and the working state still rides ahead of it, once; the atoms
   between the read end and the accepted start are not sent. *)
let test_a_start_past_the_read_end_keeps_the_working_state () =
  let skipped = text T.User "Fresh unsummarized work" in
  let accepted_atom = text T.Assistant "The accepted range opens here." in
  let current = text T.User "This turn's input." in
  let messages = source @ [skipped; accepted_atom; current] in
  let digest_at = Window.atom_opening_digest messages in
  let summarized = read_end source_end in
  let accepted : Front.seed =
    {first_atom = 3; front = Model_input_front.At_atom (Option.get (digest_at 3)); source = Front.Turn_record { turn = 5 }} in
  let projected =
    request_view ~continuity:summarized ~provider_config
      ~measure_message_bytes:measure ~accepted:(Some accepted) ~front:None
      ~history_digest_at:digest_at ~current_turn_results:Driver.Current_turn_verbatim
      ~base_path:(Filename.get_temp_dir_name ())
      ~turn_boundary:(Front.Turn_boundary { end_atom = 4 })
      ~materialize:(fun ~pending:_ messages -> messages) messages in
  (match projected.composed.origin with
   | Front.Past_librarian_point
       { librarian_end_atom; source = Front.Turn_record { turn = 5 } } ->
     check int "the gap opens at the read end" source_end librarian_end_atom
   | _ -> fail "the request was not attributed to the start past the read end");
  check int "the range opens at the accepted start" 3 projected.composed.projection.dropped_atoms;
  let sent = without_working_state (wire projected) in
  check bool "the skipped atom is not sent" false (List.mem skipped sent);
  check bool "the accepted atom is sent" true (List.mem accepted_atom sent);
  check bool "this turn's input is sent" true (List.mem current sent);
  (* The review's case: the last turn had no fitting snapshot and started at
     the read position R, which was accepted; this turn a snapshot with the
     earlier cut S fits. The request starts at R, and the atoms from S to R
     are ones the Librarian has read, so there is no gap. *)
  let gap ~read_position =
    Option.map
      (fun (g : Front.librarian_gap) -> g.gap_start_atom, g.gap_end_atom)
      (Front.librarian_gap ~snapshot_cut:(Some source_end)
         ~read_position ~accepted_start:accepted.first_atom)
  in
  check (option (pair int int)) "a read position at the accepted start leaves no gap" None
    (gap ~read_position:(Some 3));
  check (option (pair int int)) "a read position behind the cut leaves the cut to the start"
    (Some (source_end, 3)) (gap ~read_position:(Some 1));
  check (option (pair int int)) "no read position leaves the cut to the start"
    (Some (source_end, 3)) (gap ~read_position:None)
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

(* With [Finished_turns_verbatim], the [request_view] default, a completed
   exchange still in the range goes out raw on every ordinary request; only
   the resend that answers a size refusal sends the refused request's bodies
   as markers, the unfinished exchange's included (#28845).
   The driver asks for [Finished_turns_as_markers] when the reader is
   offered; [test_keeper_model_input_demotion] covers that request. *)
let test_completed_bodies_go_raw_until_a_size_refusal () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "completed-bodies-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) @@ fun () ->
  let store = Tool_blob_store.create ~base_path in
  let older_body = String.make 8000 'o' and current_body = String.make 8000 'c' in
  let older = exchange "older" older_body in
  let completed = source @ older in
  let current = [text T.User "Approval is still required."] @ exchange "unfinished" current_body in
  let messages = completed @ current in
  let original = encode messages in
  let completed_end = snd (Window.annotate completed) in
  (* The writer is one turn behind: it read [source], so the request
     carries the completed "older" exchange and this turn. *)
  let behind = read_end source_end in
  let carried = pinned :: (older @ current) in
  let refused = Driver.Current_turn_demoted { refused_atom_count = snd (Window.annotate messages) } in
  let project ?(base_path = base_path) ?(continuity = Some behind)
      ?(current_turn_results = Driver.Current_turn_verbatim) () =
    request_view ?continuity
      ~provider_config ~measure_message_bytes:measure ~accepted:None ~front:None
      ~history_digest_at:(Window.atom_opening_digest messages) ~current_turn_results
      ~base_path ~turn_boundary:(Front.Turn_boundary { end_atom = completed_end })
      ~materialize:(fun ~pending messages ->
        (Masc.Keeper_model_input_demotion.materialize ~store
          ~addresses:(Masc.Keeper_model_input_demotion.create_address_memo ())
          ~pending messages).messages) messages |> wire in
  let ordinary = project () |> without_working_state in
  check bool "a range opening on the older exchange's assistant carries the preamble" true
    (List.exists Window.is_synthetic_preamble ordinary);
  check string "an ordinary request carries the completed exchange raw" (encode carried)
    (encode (without_preamble ordinary));
  let resent = project ~current_turn_results:refused () |> without_working_state |> without_preamble in
  check int "the resend omits no message" (List.length carried) (List.length resent);
  check bool "non-tool obligations are unchanged" true (List.mem (List.hd current) resent);
  List.iter (fun (id, body) ->
    match Tool_output.decode_from_agent_core (body_for id resent) with
    | Tool_output.Decoded reference ->
      (match Tool_blob_store.fetch store ~sha256:reference.sha256 with
       | Ok (Some bytes) -> check string (id ^ ": the reference retrieves the exact original") body bytes
       | _ -> fail (id ^ ": the materialized reference is not readable"))
    | _ -> fail (id ^ ": the refused request's body did not leave as a marker"))
    ["older", older_body; "unfinished", current_body];
  check string "a resend with no store keeps the exact raw source" (encode carried)
    (encode (project ~base_path:"" ~current_turn_results:refused ()
             |> without_working_state |> without_preamble));
  (* No read end and no seed: the range starts at the completed boundary, so
     this turn goes raw. *)
  check string "without a read end only this turn goes, raw" (encode (pinned :: current))
    (encode (project ~continuity:(Some Driver.No_read_end) ()));
  let summarized = project ~continuity:(Some (read_end completed_end)) () |> without_working_state in
  check string "covered prefix excluded, unfinished suffix intact" (encode (pinned :: current))
    (encode summarized);
  check string "durable source values unchanged" original (encode messages)
;;

let test_failed_externalization_keeps_raw_body () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "externalization-write-failure-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) @@ fun () ->
  let obstacle = open_out (Filename.concat base_path ".masc") in close_out obstacle;
  let blocked = exchange "blocked" (String.make 8000 'b') in
  let completed = source @ blocked in
  let this_turn = [text T.User "Next turn."] in
  let messages = completed @ this_turn in
  let completed_end = snd (Window.annotate completed) in
  let behind = read_end source_end in
  let reverted = ref 0 in
  let projected = request_view
    ~continuity:behind ~provider_config ~measure_message_bytes:measure
    ~accepted:None ~front:None ~history_digest_at:(Window.atom_opening_digest messages)
    ~current_turn_results:(Driver.Current_turn_demoted { refused_atom_count = snd (Window.annotate messages) })
    ~base_path ~turn_boundary:(Front.Turn_boundary { end_atom = completed_end })
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
  let lines = boundary_lines completed in
  let resumed = completed @ [text T.User "Still awaiting approval"]
    @ exchange "resumed-unfinished" (String.make 8000 'u') in
  let endpoint = snd (Window.annotate completed) in
  let completed_end lines messages =
    Snapshot.checkpoint_prefix_range ~trace_id ~lines ~messages
    |> Result.map (fun (range : Masc.Keeper_librarian_range.range) -> range.end_atom) in
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

let () = run "continuity request projection"
  ["request", [test_case "completed boundary protects resumed work" `Quick test_completed_boundary_protects_resumed_work;
        test_case "completed bodies go raw until a size refusal" `Quick test_completed_bodies_go_raw_until_a_size_refusal;
        test_case "failed blob write retains raw body" `Quick test_failed_externalization_keeps_raw_body;
        test_case "actual wire and tool append" `Quick test_actual_wire_and_tool_append;
        test_case "old front" `Quick test_an_old_front_does_not_drop_unread;
        test_case "all covered" `Quick test_all_covered_keeps_only_working_and_pinned;
        test_case "without a read end the range starts at the seed, else the turn start" `Quick
          test_without_a_read_end_the_range_starts_at_the_turn_start;
        test_case "without a read end a seed range sends earlier tool bodies as sent" `Quick
          test_without_a_read_end_a_seed_range_sends_earlier_tool_bodies_as_sent;
        test_case "a read end alone starts there" `Quick test_a_read_end_alone_starts_there;
        test_case "the view gives the continuity" `Quick test_the_view_gives_the_continuity;
        test_case "the forecast takes the driver's start" `Quick test_the_forecast_takes_the_drivers_start;
        test_case "a start past the read end keeps the working state" `Quick
          test_a_start_past_the_read_end_keeps_the_working_state;
        test_case "a window that stays keeps its working state" `Quick
          test_a_window_that_stays_keeps_its_working_state]]
