(** What a refusal that ended a completed-history original says about the next
    read. The rule alone, on values. *)
open Alcotest
open Masc
module Refusal = Keeper_librarian_durable_refusal
module Exact = Lane_addon_exact

let next_read =
  testable
    (fun ppf value ->
      Format.pp_print_string ppf
        (match value with Refusal.Narrowed -> "narrowed" | Whole_again -> "whole again"))
    ( = )

let test_a_request_the_host_ended_unrun () =
  let retained=Exact.Retained_not_allowed {reason=Replaced_declaration} in
  let evidence=Exact.retained_final_to_json retained in
  let restored=match Exact.retained_final_of_json ~schema:(`Assoc []) evidence with
    | Ok value -> value | Error detail -> fail detail in
  check next_read "the stored replacement reason keeps the read whole without configuration"
    Refusal.Whole_again (Refusal.next_read ~final:(Exact.delivered restored));
  let text=Exact.not_allowed_reason_detail Exact.Replaced_declaration in
  check next_read "ordinary refusal text cannot establish declaration replacement"
    Refusal.Narrowed
    (Refusal.next_read ~final:(Exact.Not_allowed {reason=Permission_refused {detail=text}}));
  List.iter (fun invalid ->
    check bool "unknown or contradictory replacement evidence is refused" true
      (Result.is_error (Exact.final_of_json ~schema:(`Assoc []) invalid)))
    [`Assoc ["status",`String "not_allowed";"cause",`String "unknown"];
     `Assoc ["status",`String "not_allowed";"cause",`String "declaration_replaced";
       "reason",`String text]]

let test_a_refusal_that_came_from_a_call () =
  List.iter
    (fun (label, final) -> check next_read label Refusal.Narrowed (Refusal.next_read ~final))
    [
      ("a size refusal narrows under a replaced declaration", Exact.Call_final (Input_refused Input_capacity));
      ("a context overflow narrows", Exact.Call_final (Input_refused Context_overflow));
      ("a refused request body narrows", Exact.Call_final (Input_refused Request_body_refused));
      ("an invalid request narrows", Exact.Call_final (Input_refused Invalid_request));
      ("an output no slot could give narrows", Exact.Call_final (Invalid_output { detail = "fixture" }));
      ("a reused request ID narrows", Exact.Request_id_reused);
    ]

let () =
  run "Librarian durable refusal"
    [
      ( "next read",
        [
          test_case "a request the host ended unrun" `Quick test_a_request_the_host_ended_unrun;
          test_case "a refusal that came from a call" `Quick test_a_refusal_that_came_from_a_call;
        ] );
    ]
