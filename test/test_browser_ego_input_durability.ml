open Alcotest
module Input = Masc.Browser_ego_input
module Release = Masc.Browser_ego_release
open Input
open Release
let ok = function Ok value->value|Error detail->fail detail
let proof () = match Release.judge [0,Release.answer_of_json (`Assoc [])] with
  | Release.Settled (Released proof)->proof
  | Settled No_hold|Unconfirmed _->fail "fixture receipt did not prove settlement"
type fault = Normal | Before_write | After_write
let storage () =
  let current=ref None and fault=ref Normal and active=ref true and writes=ref 0 in
  let persistence={Input.read=(fun () -> Ok !current);
    compare_and_set=(fun ~expected ~replacement ->
      incr writes;
      if expected<> !current then Error "writer/state changed" else
      match !fault with
      | Before_write -> Error "injected pre-publication failure"
      | Normal -> current:=Some replacement;Ok ()
      | After_write -> current:=Some replacement;Error "injected unconfirmed publication");
    active=(fun () -> !active)} in
  persistence,current,fault,active,writes
let open_input persistence writer = ok (Input.create_persistent ~persistence ~writer ~space_id:51)
let hold t command = ok (Input.within_command t ~command_id:command (fun () ->
  Input.begin_holding t ~scope:Input.Space_scope ~tab_id:7 ~page_label:"p2" ~operation:"native_workflow"))
let pending t = match Input.status t with Input.Uncertain pending->pending|Ready _->fail "input unexpectedly available"
let reopen () =
  let persistence,_,_,_,_=storage () in
  let first=open_input persistence "original" in
  let original=ok (hold first "original-command") in
  let replacement=open_input persistence "replacement" in
  check bool "reopen retains the complete original intent" true (pending replacement=original);
  check bool "reopen blocks input without replay" true (Result.is_error (Input.admit replacement));
  check bool "local running scope is not restored as active execution" false (Input.busy replacement)
let stale_writer_and_generation () =
  let persistence,current,_,_,_=storage () in
  let first=open_input persistence "old" in let original=ok (hold first "original") in
  let replacement=open_input persistence "new" in let before= !current in
  check bool "old writer cannot settle replacement record" true
    (Result.is_error (Input.command_settled first ~generation:original.generation (proof ())));
  check bool "old writer cannot reset replacement record" true
    (Result.is_error (Input.assert_reset first ~generation:original.generation ~now:1.));
  check bool "stale writes preserve exact bytes/state" true (!current=before);
  check bool "wrong generation cannot settle current owner" true
    (Result.is_error (Input.command_settled replacement ~generation:"stale-generation" (proof ())));
  check bool "wrong generation cannot roll back current owner" true
    (Result.is_error (Input.not_started replacement ~generation:"stale-generation"));
  check bool "wrong reset generation rejected" true (Result.is_error (Input.assert_reset replacement ~generation:"other" ~now:1.));
  ok (Input.command_settled replacement ~generation:original.generation (proof ()));
  check bool "genuine settlement survives reopen" true (Input.status (open_input persistence "third")=Ready Command_settled)
let replacement_races_transition () = List.iter (fun settling ->
  let persistence,_,_,_,_=storage () in
  let race=ref false and replacement=ref None in
  let original_persistence={persistence with compare_and_set=(fun ~expected ~replacement:next ->
    if !race then (race:=false;replacement:=Some (open_input persistence "replacement"));
    persistence.compare_and_set ~expected ~replacement:next)} in
  let first=open_input original_persistence "old" in
  let original=if settling then Some (ok (hold first "original")) else None in
  race:=true;
  let result=match original with
    | Some pending->Input.command_settled first ~generation:pending.generation (proof ())
    | None->Result.map (fun (_:Input.pending)->()) (hold first "never-dispatched") in
  check bool "replacement claim wins before stale CAS" true (Result.is_error result);
  let replacement=Option.get !replacement in
  (match original with
   | Some pending->check bool "racing old settlement preserves original pending" true (Input.status replacement=Uncertain pending)
   | None->check bool "racing old intent grants no effect or new pending" true (Input.status replacement=Ready Command_settled))) [false;true]
let replaced_available_writer () =
  let persistence,_,_,_,_=storage () in
  let first=open_input persistence "old" in let replacement=open_input persistence "replacement" in
  ignore (ok (hold replacement "new-pending"));
  check bool "old available peer cannot admit nonholding input past replacement uncertainty" true (Result.is_error (Input.admit first))
let publication_failure () = List.iter (fun mode ->
  let persistence,_,fault,_,_=storage () in let first=open_input persistence "first" in
  fault:=mode;
  let effects=ref 0 in
  let result=Input.within_command first ~command_id:"must-not-dispatch" (fun () ->
    match Input.begin_holding first ~scope:Input.Page_scope ~tab_id:1 ~page_label:"p1" ~operation:"target_click" with
    | Error detail -> Error detail
    | Ok _ -> incr effects;Ok ()) |> ok in
  check bool "unconfirmed write refuses effect" true (Result.is_error result);
  check int "no native effect after failed write ahead" 0 !effects;
  check bool "local admission stays blocked" true (Result.is_error (Input.admit first));
  let original=pending first in fault:=Normal;
  let reopened=open_input persistence "after-crash" in
  match mode with
  | After_write -> check bool "unconfirmed committed intent survives" true (pending reopened=original)
  | Before_write -> check bool "no persisted intent and no effect" true (Input.status reopened=Ready Command_settled)
  | Normal -> fail "fault fixture must inject a failure") [Before_write;After_write]
let reset_and_rollback () =
  let persistence,_,_,_,_=storage () in let first=open_input persistence "first" in
  let original=ok (hold first "original") in
  ok (Input.assert_reset first ~generation:original.generation ~now:12.);
  let second=open_input persistence "second" in
  let asserted=Input.status second in
  let later=ok (hold second "provably-unstarted") in
  check bool "earlier real generation cannot settle the later intent" true
    (Result.is_error (Input.command_settled second ~generation:original.generation (proof ())));
  check bool "earlier real generation cannot roll back the later intent" true
    (Result.is_error (Input.not_started second ~generation:original.generation));
  check bool "later exact pending survives stale-generation attempts" true (pending second=later);
  ok (Input.not_started second ~generation:later.generation);
  check bool "proven pre-effect rollback retains exact operator provenance" true (Input.status second=asserted);
  check bool "operator assertion persists across another reopen" true (Input.status (open_input persistence "third")=asserted)
let retired_and_unconfirmed_settlement () =
  let persistence,_,fault,active,writes=storage () in let first=open_input persistence "first" in
  let original=ok (hold first "original") in let count= !writes in active:=false;
  check bool "retired owner cannot settle" true (Result.is_error (Input.command_settled first ~generation:original.generation (proof ())));
  check bool "retired owner cannot reset" true (Result.is_error (Input.assert_reset first ~generation:original.generation ~now:2.));
  check int "retired owner performs no write" count !writes;
  active:=true;fault:=Before_write;
  check bool "failed genuine settlement remains blocked" true (Result.is_error (Input.command_settled first ~generation:original.generation (proof ())));
  check bool "same original pending survives failed settlement" true (pending first=original);
  fault:=Normal;check bool "failed settlement survives reopen" true (pending (open_input persistence "replacement")=original)
let malformed_record () =
  let persistence,current,_,_,writes=storage () in
  ignore (open_input persistence "original");
  let original=Option.get !current in
  let cases=match original with
    | `Assoc fields -> [`Assoc (("version",`Int 1)::fields);`Assoc (("unexpected",`Bool true)::fields);
        `Assoc (List.map (fun (key,value)->key,(if key="spaceId" then `Int 52 else value)) fields)]
    | _ -> fail "fixture record is not an object" in
  List.iter (fun value -> current:=Some value;let count= !writes in
    check bool "malformed/misbound record refuses attachment" true
      (Result.is_error (Input.create_persistent ~persistence ~writer:"next" ~space_id:51));
    check int "invalid record never overwritten" count !writes) cases
let () = run "Ego input durability" ["state",[
  test_case "crash/reopen retains exact pending intent" `Quick reopen;
  test_case "stale writer and generation cannot clear replacement" `Quick stale_writer_and_generation;
  test_case "replacement claim races old intent and settlement" `Quick replacement_races_transition;
  test_case "replaced available peer cannot admit further input" `Quick replaced_available_writer;
  test_case "write failure prevents effects and preserves uncertainty" `Quick publication_failure;
  test_case "checked reset and proven unstarted rollback retain provenance" `Quick reset_and_rollback;
  test_case "retired owner and failed settlement stay blocked" `Quick retired_and_unconfirmed_settlement;
  test_case "malformed or misbound records refuse attachment" `Quick malformed_record]]
