(* Keeper_context_layers — pure ordered-fold of the keeper world-state user
   message. These tests pin the two properties the typed fold replaces an
   imperative buffer to guarantee: a single declared render order, and that the
   assembled body is exactly the in-order concatenation of the present layers
   (a [None] layer contributes nothing). *)

open Alcotest
module L = Masc.Keeper_context_layers

(* The full constructor set, listed independently of [L.ordered] so a drift
   between the two is observable here rather than silently dropping a section. *)
let all_layers =
  [
    L.Active_goals;
    L.Current_task;
    L.Working_state;
    L.Connected_surfaces;
    L.Namespace_state;
    L.Context_health;
    L.Autonomous_trigger;
    L.Scheduled_automation;
    L.Continuity;
    L.Pending_mentions;
    L.Scope_messages;
    L.Claimable_work;
    L.Board_activity;
  ]

let test_ordered_is_complete_permutation () =
  check int "ordered length matches constructor count" (List.length all_layers)
    (List.length L.ordered);
  List.iter
    (fun id ->
      check bool
        (Printf.sprintf "ordered contains layer at index %d" (L.order_index id))
        true
        (List.mem id L.ordered))
    all_layers

let test_order_index_matches_position () =
  List.iteri
    (fun i id ->
      check int
        (Printf.sprintf "order_index agrees with position %d" i)
        i (L.order_index id))
    L.ordered

let test_order_index_is_injective () =
  let indices = List.map L.order_index all_layers in
  let sorted = List.sort_uniq compare indices in
  check int "order_index distinct across all layers"
    (List.length all_layers) (List.length sorted)

let test_assemble_concatenates_present_in_order () =
  (* Render a label for three layers spread across the order (positions 0, 4, 11)
     and nothing for the rest; assemble must yield them in ordered order. *)
  let content_of = function
    | L.Active_goals -> Some "A"
    | L.Context_health -> Some "C"
    | L.Board_activity -> Some "B"
    | _ -> None
  in
  check string "present layers concatenated in ordered order" "ACB"
    (L.assemble ~content_of)

let test_assemble_empty_when_all_absent () =
  check string "no layers -> empty body" "" (L.assemble ~content_of:(fun _ -> None))

let test_assemble_all_present_follows_ordered () =
  (* Each layer renders its own order index; the result must read 0..12. *)
  let content_of id = Some (string_of_int (L.order_index id)) in
  check string "every layer present -> indices in order" "0123456789101112"
    (L.assemble ~content_of)

let () =
  run "keeper_context_layers"
    [
      ( "ordering",
        [
          test_case "ordered is a complete permutation" `Quick
            test_ordered_is_complete_permutation;
          test_case "order_index matches ordered position" `Quick
            test_order_index_matches_position;
          test_case "order_index is injective" `Quick
            test_order_index_is_injective;
        ] );
      ( "assemble",
        [
          test_case "concatenates present layers in order" `Quick
            test_assemble_concatenates_present_in_order;
          test_case "empty when all absent" `Quick
            test_assemble_empty_when_all_absent;
          test_case "all present follows ordered" `Quick
            test_assemble_all_present_follows_ordered;
        ] );
    ]
