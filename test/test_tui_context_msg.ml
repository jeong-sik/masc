(* The Context inspector's answers are [Masc_tui_context_results.msg] and
   travel in [async_msg] as [Context_msg] (#48617). Every answer is a read
   that never waits for input. A reading lands only on the open pane that
   asked for it. *)

module Protocol = Masc_tui_async_protocol
module Context = Masc_tui_context_results
module Inspector = Masc_tui_context_inspector
module Fetched = Masc_tui_fetched
module Types = Masc_tui_types

let fresh () = Types.create_state ~workspace:"test" ~port:0 ~refresh_interval:0. ()

let part_request () =
  let key =
    { Inspector.part_keeper = "omega"
    ; part_turn_ref = Ids.Turn_ref.make ~trace_id:"trace" ~absolute_turn:1
    ; part_item = { Inspector.index = 0; kind = Inspector.System_prompt; bytes = 0; sha256 = "" } }
  in
  match Fetched.start ~equal:Inspector.same_part_key Fetched.initial ~key with
  | Fetched.Started (_, request) -> request
  | Fetched.Already_loading -> Alcotest.fail "a fresh source reported a read in flight"

(* Every constructor named: a new answer has to be placed here before this
   test compiles. *)
let name : Context.msg -> string = function
  | Context.Context_inspector_loaded _ -> "reading"
  | Context.Context_inspector_part_loaded _ -> "part"

let answers () =
  [ Context.Context_inspector_loaded (0, "omega", Inspector.Request_failed "not read")
  ; Context.Context_inspector_part_loaded (part_request (), Error "not read") ]

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
  let generation = state.context_inspector_generation in
  Context.apply state
    (Context.Context_inspector_loaded (generation + 1, "omega", Inspector.Request_failed "late"));
  Alcotest.(check (option string)) "a reading from another generation is dropped" None
    (reading_keeper state);
  Context.apply state
    (Context.Context_inspector_loaded (generation, "theta", Inspector.Request_failed "other"));
  Alcotest.(check (option string)) "a reading for another Keeper is dropped" None
    (reading_keeper state);
  Context.apply state
    (Context.Context_inspector_loaded (generation, "omega", Inspector.Request_failed "failed"));
  Alcotest.(check (option string)) "the asked reading lands" (Some "omega") (reading_keeper state);
  Alcotest.(check bool) "a failed request is not loading" false state.context_inspector_loading

let test_a_closed_pane_takes_nothing () =
  let state = fresh () in
  state.context_inspector_keeper <- Some "omega";
  List.iter (Context.apply state) (answers ());
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
        ; Alcotest.test_case "a closed pane takes nothing" `Quick test_a_closed_pane_takes_nothing
        ] ) ]
