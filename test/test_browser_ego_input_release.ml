open Alcotest
open Masc
module Input = Browser_ego_input
let ok = function Ok value -> value | Error detail -> fail detail
let contains ~sub text =
  let n = String.length sub and m = String.length text in
  let rec at i = i + n <= m && (String.sub text i n = sub || at (i + 1)) in
  n = 0 || at 0
let hold input ~command_id ~now =
  ok (Input.within_command input ~command_id (fun () ->
    Input.begin_holding input ~now ~scope:Input.Page_scope ~tab_id:4 ~page_label:"p2" ~operation:"target_click")) |> ok
let member key = function `Assoc fields -> List.assoc key fields | _ -> fail "not an object"
let string_of = function `String s -> s | _ -> fail "not a string"

(* The Keeper's own release runs inside its own command scope, just as the
   Ego peer's [release_input] control does, and unblocks the same peer. *)
let keeper_release_unblocks () =
  let input = Input.create () in
  let pending = hold input ~command_id:"original" ~now:100. in
  check bool "pending input refuses further input" true (Result.is_error (Input.admit input));
  check string "provenance while locked" "release_uncertain" (Input.provenance input);
  let outcome = ok (Input.within_command input ~command_id:"release"
    (fun () -> Input.reset input ~authority:Input.Keeper ~generation:pending.generation ~now:200.)) in
  check bool "release applied" true (outcome = Input.Reset_applied);
  check bool "input admitted again" true (Result.is_ok (Input.admit input));
  check string "provenance is distinguishable" "keeper_asserted" (Input.provenance input);
  check bool "state carries who and when" true
    (Input.status input = Input.Ready (Input.Keeper_released {pending; at = 200.}));
  let repeat = ok (Input.within_command input ~command_id:"again"
    (fun () -> Input.reset input ~authority:Input.Keeper ~generation:pending.generation ~now:300.)) in
  check bool "repeating the same release is idempotent" true (repeat = Input.Reset_already_applied);
  check bool "timestamp is not rewritten" true
    (Input.status input = Input.Ready (Input.Keeper_released {pending; at = 200.}))

(* An operator form for generation 1 is overtaken by generation 2: the old
   assert is refused, says why, and the Keeper's release for generation 2 works. *)
let overtaken_generation_is_visible () =
  let input = Input.create () in
  let first = hold input ~command_id:"c1" ~now:100. in
  ok (Input.not_started input ~generation:first.generation);
  let second = hold input ~command_id:"c2" ~now:150. in
  check bool "a new generation replaced the first" true (first.generation <> second.generation);
  (match Input.assert_reset input ~generation:first.generation ~now:160. with
   | Ok () -> fail "a stale generation must not be applied"
   | Error reason ->
     check bool "reason names the requested generation" true (contains ~sub:first.generation reason);
     check bool "reason names the current generation" true (contains ~sub:second.generation reason);
     check bool "reason says it was not applied" true (contains ~sub:"not applied" reason));
  check string "still locked" "release_uncertain" (Input.provenance input);
  let lock = Input.lock_report input in
  let rejection = member "lastRejection" lock in
  check string "report keeps the requested generation" first.generation (string_of (member "requestedGeneration" rejection));
  check string "report keeps the current generation" second.generation (string_of (member "currentGeneration" rejection));
  check bool "report keeps when the lock was taken" true (member "heldAt" rejection = `Float 150.);
  check bool "report names the release path" true
    (member "keeperCallable" (member "releasePath" lock) = `Bool true
     && string_of (member "action" (member "releasePath" lock)) = "release_input");
  let outcome = ok (Input.within_command input ~command_id:"release"
    (fun () -> Input.reset input ~authority:Input.Keeper ~generation:second.generation ~now:170.)) in
  check bool "the current generation releases" true (outcome = Input.Reset_applied);
  check bool "a successful release clears the rejection" true (member "lastRejection" (Input.lock_report input) = `Null)

let guards_hold () =
  let input = Input.create () in
  let pending = hold input ~command_id:"original" ~now:100. in
  (match Input.reset input ~authority:Input.Keeper ~generation:pending.generation ~now:200. with
   | Input.Reset_rejected rejection ->
     check bool "a Keeper release outside its own command is refused" true (contains ~sub:"own command scope" rejection.reason)
   | Input.Reset_applied | Input.Reset_already_applied -> fail "must not release outside a command");
  let during = ok (Input.within_command input ~command_id:"running" (fun () ->
    Input.reset input ~authority:Input.Operator ~generation:pending.generation ~now:200.)) in
  (match during with
   | Input.Reset_rejected rejection -> check bool "operator assertion still refuses while a command runs" true (contains ~sub:"still running" rejection.reason)
   | Input.Reset_applied | Input.Reset_already_applied -> fail "operator path must refuse while busy");
  check string "nothing was released" "release_uncertain" (Input.provenance input);
  (match Input.assert_reset input ~generation:pending.generation ~now:Float.nan with
   | Ok () -> fail "a non-finite timestamp must be refused"
   | Error _ -> ());
  check bool "operator path still works when idle" true (Input.assert_reset input ~generation:pending.generation ~now:210. = Ok ());
  check string "operator provenance unchanged" "operator_asserted" (Input.provenance input);
  let after = ok (Input.within_command input ~command_id:"late" (fun () ->
    Input.reset input ~authority:Input.Keeper ~generation:pending.generation ~now:220.)) in
  check bool "a later Keeper release does not rewrite the operator's assertion" true (after = Input.Reset_already_applied);
  check string "provenance stays operator_asserted" "operator_asserted" (Input.provenance input)

(* A released state survives a worker restart; a record from before [heldAt]
   existed still loads, with an unknown lock time. *)
let memory_persistence () =
  let cell = ref None in
  let persistence = {Input.read = (fun () -> Ok !cell);
    compare_and_set = (fun ~expected ~replacement ->
      if !cell = expected then (cell := Some replacement; Ok ()) else Error "changed");
    active = (fun () -> true)} in
  let first = ok (Input.create_persistent ~persistence ~writer:"w1" ~space_id:9) in
  let pending = hold first ~command_id:"original" ~now:100. in
  let _ = ok (Input.within_command first ~command_id:"release" (fun () ->
    Input.reset first ~authority:Input.Keeper ~generation:pending.generation ~now:200.)) in
  let second = ok (Input.create_persistent ~persistence ~writer:"w2" ~space_id:9) in
  check string "keeper assertion survives a restart" "keeper_asserted" (Input.provenance second);
  (match Input.status second with
   | Input.Ready (Input.Keeper_released {pending = restored; at}) ->
     check bool "restored lock time" true (restored.held_at = Some 100.);
     check bool "restored release time" true (at = 200.)
   | Input.Ready (Input.Command_settled | Input.Operator_reset_asserted _) | Input.Uncertain _ -> fail "restored state");
  let legacy = `Assoc ["version", `Int 1; "spaceId", `Int 10; "writer", `String "old";
    "state", `Assoc ["kind", `String "pending";
      "pending", `Assoc ["generation", `String "g-legacy"; "commandId", `String "c"; "tabId", `Int 3;
        "pageLabel", `String "p"; "operation", `String "target_click"; "scope", `String "page"];
      "previous", `Assoc ["kind", `String "command_settled"]]] in
  let cell = ref (Some legacy) in
  let persistence = {persistence with Input.read = (fun () -> Ok !cell);
    compare_and_set = (fun ~expected ~replacement ->
      if !cell = expected then (cell := Some replacement; Ok ()) else Error "changed")} in
  let reopened = ok (Input.create_persistent ~persistence ~writer:"w3" ~space_id:10) in
  (match Input.status reopened with
   | Input.Uncertain pending -> check bool "a record without heldAt loads with an unknown lock time" true (pending.held_at = None)
   | Input.Ready _ -> fail "legacy pending record must stay locked");
  check bool "report shows the unknown lock time as null" true
    (member "heldAt" (member "pending" (Input.lock_report reopened)) = `Null)


(* The operator form used to turn every refusal into the same "not applied"
   text. A refused confirmation now carries why, and an applied one still works. *)
let operator_view_keeps_the_reason () =
  let module Operator = Browser_ego_operator in
  let input = Input.create () in
  let first = hold input ~command_id:"c1" ~now:100. in
  ok (Input.not_started input ~generation:first.generation);
  let second = hold input ~command_id:"c2" ~now:150. in
  let connection : Operator.connection = {client_id = "client"; space = {Browser_lane.id = 3; name = "masc-keepers"};
    recovery = {status = (fun () -> Input.status input); busy = (fun () -> Input.busy input);
      assert_reset = (fun ~generation -> Input.assert_reset input ~generation ~now:160.);
      space_observation = (fun () -> None);
      space_presence = (fun () -> {Browser_ego_space_observation.space_id = 3; observed_at = 0.; state = Present})}} in
  let request generation = `Assoc ["action", `String "assert_input_reset"; "arguments", `Assoc [
    "clientId", `String "client"; "spaceId", `String "3"; "generation", `String generation;
    "confirmation", `String "checked_and_reset"]] in
  let stale = Operator.invoke (Some connection) (request first.generation) in
  check string "a stale confirmation is reported as not applied" "not_applied" (string_of (member "outcome" stale));
  let reason = string_of (member "reason" stale) in
  check bool "the operator sees the requested generation" true (contains ~sub:first.generation reason);
  check bool "the operator sees the current generation" true (contains ~sub:second.generation reason);
  check bool "the message carries the reason too" true (contains ~sub:"사유" (string_of (member "message" stale)));
  check string "still locked after the refused confirmation" "release_uncertain" (Input.provenance input);
  let wrong_client = Operator.invoke (Some {connection with client_id = "other"}) (request second.generation) in
  check bool "a client mismatch says so" true (contains ~sub:"client" (string_of (member "reason" wrong_client)));
  let applied = Operator.invoke (Some connection) (request second.generation) in
  check string "the current generation is applied" "operator_asserted" (string_of (member "outcome" applied));
  check bool "no reason is attached to an applied confirmation" true
    (match applied with `Assoc fields -> not (List.mem_assoc "reason" fields) | _ -> false)

let () = run "Ego input keeper release" ["release",[
  test_case "keeper release unblocks the same peer" `Quick keeper_release_unblocks;
  test_case "overtaken generation is visible and recoverable" `Quick overtaken_generation_is_visible;
  test_case "operator and command-scope guards hold" `Quick guards_hold;
  test_case "released state and legacy records persist" `Quick memory_persistence;
  test_case "operator view keeps the refusal reason" `Quick operator_view_keeps_the_reason]]
