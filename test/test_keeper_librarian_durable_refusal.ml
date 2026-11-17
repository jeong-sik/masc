(** What a refusal that ended a completed-history original says about the next
    read. The rule alone, on values. *)
open Alcotest
open Masc
module Refusal = Keeper_librarian_durable_refusal
module Destination = Lane_addon_captured_destination
module Exact = Lane_addon_exact

let next_read =
  testable
    (fun ppf value ->
      Format.pp_print_string ppf
        (match value with Refusal.Narrowed -> "narrowed" | Whole_again -> "whole again"))
    ( = )

let not_allowed = Exact.Not_allowed { reason = "fixture reason" }
let known relation () = Ok relation

let test_a_request_the_host_ended_unrun () =
  check next_read "under a replaced declaration the next read stays whole" Refusal.Whole_again
    (Refusal.next_read ~final:not_allowed ~relation:(known Destination.Replaced));
  check next_read "under the same declaration the next read narrows" Refusal.Narrowed
    (Refusal.next_read ~final:not_allowed ~relation:(known Destination.Same));
  check next_read "under another owner's destination the next read narrows" Refusal.Narrowed
    (Refusal.next_read ~final:not_allowed ~relation:(known Destination.Other_owner));
  check next_read "without a current destination the next read narrows" Refusal.Narrowed
    (Refusal.next_read ~final:not_allowed ~relation:(fun () -> Error "fixture: no destination"))

let test_a_refusal_that_came_from_a_call () =
  let asked = ref 0 in
  let relation () =
    incr asked;
    Ok Destination.Replaced
  in
  List.iter
    (fun (label, final) -> check next_read label Refusal.Narrowed (Refusal.next_read ~final ~relation))
    [
      ("a size refusal narrows under a replaced declaration", Exact.Call_final (Input_refused Input_capacity));
      ("a context overflow narrows", Exact.Call_final (Input_refused Context_overflow));
      ("a refused request body narrows", Exact.Call_final (Input_refused Request_body_refused));
      ("an invalid request narrows", Exact.Call_final (Input_refused Invalid_request));
      ("an output no slot could give narrows", Exact.Call_final (Invalid_output { detail = "fixture" }));
      ("a reused request ID narrows", Exact.Request_id_reused);
    ];
  check int "the declaration is not read for a refusal that came from a call" 0 !asked

let () =
  run "Librarian durable refusal"
    [
      ( "next read",
        [
          test_case "a request the host ended unrun" `Quick test_a_request_the_host_ended_unrun;
          test_case "a refusal that came from a call" `Quick test_a_refusal_that_came_from_a_call;
        ] );
    ]
