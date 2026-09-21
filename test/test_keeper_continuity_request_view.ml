open Alcotest
module Driver = Masc.Keeper_turn_driver_try_provider
module Snapshot = Masc.Librarian_continuity_snapshot
module Boundary = Masc.Keeper_turn_boundaries
module Front = Masc.Keeper_carried_front
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

let test_uncompressed_history_ignores_old_front_and_demotion () =
  let messages = source @ [text T.User "Fresh unsummarized work"] @ tool_pair () in
  let front_digest = Window.atom_opening_digest messages 3 |> Option.get in
  let front : Front.seed = {first_atom = 3; front_digest; source = Front.Ledger} in
  let projected = Driver.For_testing.request_view ~continuity:Driver.uncompressed_history
    ~provider_config ~measure_message_bytes:measure ~front:(Some front)
    ~history_digest_at:(Window.atom_opening_digest messages) ~last_resort:true
    ~base_path:(Filename.get_temp_dir_name ()) ~demote_before:max_int
    ~materialize:(fun ~pending:_ _ -> fail "fresh history entered demotion") messages in
  check string "every current-history message reaches the wire" (encode messages)
    (encode (wire projected));
  check int "older front cannot discard unsummarized history" 0 projected.composed.projection.dropped_atoms;
  check int "last resort cannot demote fresh history" 0 projected.composed.demote_before;
  (match projected.composed.origin with
   | Front.Whole_history -> () | _ -> fail "uncompressed history attributed to an old front");
  (match Driver.validate_continuity ~messages:[] Driver.uncompressed_history with
   | Ok () -> () | Error _ -> fail "uncompressed path borrowed stale prefix obligations")
;;

let () = run "continuity request projection"
  ["request", [test_case "actual wire and tool append" `Quick test_actual_wire_and_tool_append;
               test_case "old front and last resort" `Quick test_old_front_and_last_resort_do_not_drop_unread;
               test_case "all covered" `Quick test_all_covered_keeps_only_working_and_pinned;
               test_case "covered prefix validation per request" `Quick test_each_request_validates_frozen_covered_messages;
               test_case "fresh uncompressed history" `Quick test_uncompressed_history_ignores_old_front_and_demotion]]
