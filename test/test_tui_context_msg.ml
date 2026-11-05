(* The Context inspector's answers are [Masc_tui_context_results.msg] and
   travel in [async_msg] as [Context_msg] (#48617). Every answer is a read
   that never waits for input. A reading lands only on the open pane that
   asked for it, and a part only while its read is current. *)

module Protocol = Masc_tui_async_protocol
module Context = Masc_tui_context_results
module Inspector = Masc_tui_context_inspector
module Fetched = Masc_tui_fetched
module Types = Masc_tui_types

let fresh () = Types.create_state ~workspace:"test" ~port:0 ~refresh_interval:0. ()

let part_key () =
  { Inspector.part_keeper = "omega"
  ; part_turn_ref = Ids.Turn_ref.make ~trace_id:"trace" ~absolute_turn:1
  ; part_item = { Inspector.index = 0; kind = Inspector.System_prompt; bytes = 0; sha256 = "" } }

(* Start the part read on the state's own source, as the pane does. *)
let start_part (state : Types.state) =
  match
    Fetched.start ~equal:Inspector.same_part_key state.context_inspector_part ~key:(part_key ())
  with
  | Fetched.Started (next, request) ->
      state.context_inspector_part <- next;
      request
  | Fetched.Already_loading -> Alcotest.fail "a fresh source reported a read in flight"

(* [name] matches every constructor, so a new answer does not compile until it
   is named here. [answers] is written by hand: a new answer goes there too. *)
let name : Context.msg -> string = function
  | Context.Context_inspector_loaded _ -> "reading"
  | Context.Context_inspector_part_loaded _ -> "part"

let answers () =
  [ Context.Context_inspector_loaded (0, "omega", Inspector.Request_failed "not read")
  ; Context.Context_inspector_part_loaded (start_part (fresh ()), Error "not read") ]

let test_every_answer_is_a_read () =
  List.iter
    (fun answer ->
      Alcotest.(check bool)
        (name answer ^ " is a read")
        true
        (Protocol.workspace_message_is_read (Protocol.Context_msg answer)))
    (answers ())

let test_no_answer_waits_for_input () =
  List.iter
    (fun answer ->
      Alcotest.(check bool)
        (name answer ^ " does not wait for input")
        false
        (Protocol.message_waits_for_input
           ~resource_read:(fun _ -> true)
           ~recovery_loaded:(fun _ -> true)
           (Protocol.Context_msg answer)))
    (answers ())

let reading_keeper (state : Types.state) = Option.map fst state.context_inspector_reading

let test_a_reading_lands_on_the_pane_that_asked () =
  let state = fresh () in
  state.context_inspector_open <- true;
  state.context_inspector_keeper <- Some "omega";
  state.context_inspector_loading <- true;
  let generation = state.context_inspector_generation in
  Context.apply state
    (Context.Context_inspector_loaded (generation + 1, "omega", Inspector.Request_failed "late"));
  Alcotest.(check (option string)) "a reading from another generation is dropped" None
    (reading_keeper state);
  Context.apply state
    (Context.Context_inspector_loaded (generation, "theta", Inspector.Request_failed "other"));
  Alcotest.(check (option string)) "a reading for another Keeper is dropped" None
    (reading_keeper state);
  Alcotest.(check bool) "a dropped reading leaves the pane loading" true
    state.context_inspector_loading;
  Context.apply state
    (Context.Context_inspector_loaded (generation, "omega", Inspector.Request_failed "failed"));
  Alcotest.(check (option string)) "the asked reading lands" (Some "omega") (reading_keeper state);
  Alcotest.(check bool) "a failed request is not loading" false state.context_inspector_loading

let part_failure (state : Types.state) =
  match Fetched.current state.context_inspector_part with
  | Some (_, Fetched.Failed reason) -> Some reason
  | Some (_, (Fetched.Absent | Fetched.Loading | Fetched.Ready _ | Fetched.Stale _)) | None -> None

let test_a_part_lands_while_its_read_is_current () =
  let state = fresh () in
  state.context_inspector_open <- true;
  state.context_inspector_keeper <- Some "omega";
  let request = start_part state in
  Context.apply state (Context.Context_inspector_part_loaded (request, Error "not read"));
  Alcotest.(check (option string)) "the asked part lands" (Some "not read") (part_failure state)

let test_a_closed_pane_takes_nothing () =
  let state = fresh () in
  state.context_inspector_open <- true;
  state.context_inspector_keeper <- Some "omega";
  let request = start_part state in
  Types.close_context_inspector state;
  Context.apply state
    (Context.Context_inspector_loaded
       (state.context_inspector_generation, "omega", Inspector.Request_failed "late"));
  Context.apply state (Context.Context_inspector_part_loaded (request, Error "late"));
  Alcotest.(check (option string)) "no reading lands" None (reading_keeper state);
  Alcotest.(check bool) "no part lands" true
    (Option.is_none (Fetched.current state.context_inspector_part))

let () =
  Alcotest.run "tui context msg"
    [ ( "classifiers"
      , [ Alcotest.test_case "every Context answer is a read" `Quick test_every_answer_is_a_read
        ; Alcotest.test_case "no Context answer waits for input" `Quick
            test_no_answer_waits_for_input ] )
    ; ( "apply"
      , [ Alcotest.test_case "a reading lands on the pane that asked" `Quick
            test_a_reading_lands_on_the_pane_that_asked
        ; Alcotest.test_case "a part lands while its read is current" `Quick
            test_a_part_lands_while_its_read_is_current
        ; Alcotest.test_case "a closed pane takes nothing" `Quick test_a_closed_pane_takes_nothing
        ] ) ]
