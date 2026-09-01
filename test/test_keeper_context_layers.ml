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
    L.Approval_authority;
    L.Connected_surfaces;
    L.Namespace_state;
    L.Autonomous_trigger;
    L.Scheduled_automation;
    L.Completion_authority;
    L.Task_cancellations;
    L.Pending_mentions;
    L.Scope_messages;
    L.Own_board_posts;
    L.Board_activity;
    L.Own_recent_actions;
    L.Fleet_messages;
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
  (* Render a label for three layers spread across the order (positions 0, 4, 9)
     and nothing for the rest; assemble must yield them in ordered order. *)
  let content_of = function
    | L.Active_goals -> Some (L.Block "A")
    | L.Autonomous_trigger -> Some (L.Block "T")
    | L.Board_activity -> Some (L.Block "B")
    | _ -> None
  in
  check string "present layers concatenated in ordered order" "ATB"
    (L.assemble ~content_of ())

let test_assemble_empty_when_all_absent () =
  check string "no layers -> empty body" "" (L.assemble ~content_of:(fun _ -> None) ())

let test_assemble_all_present_follows_ordered () =
  (* Each layer renders its own order index; the result must read 0..n-1.
     The expectation counts [all_layers], which is maintained by hand
     independently of [L.ordered], so a layer missing from either list still
     fails here — and adding a layer no longer means hand-editing a literal. *)
  let content_of id = Some (L.Block (string_of_int (L.order_index id))) in
  let expected =
    List.init (List.length all_layers) string_of_int |> String.concat ""
  in
  check string "every layer present -> indices in order" expected
    (L.assemble ~content_of ())
(* --- budget ------------------------------------------------------------ *)

(* Every trimmable layer renders rows this way, so one helper states the shape
   the budget acts on: a header naming how many rows are missing, then the
   rows that fit. *)
let rows_section rows =
  let total = List.length rows in
  L.Rows
    { rows
    ; render =
        (fun kept ->
          Printf.sprintf "[shown=%d/%d]" (List.length kept) total
          ^ String.concat "" kept)
    }

let trimmable_layer =
  match List.find_opt (fun id -> L.retention id <> L.Required) all_layers with
  | Some id -> id
  | None -> failwith "no trimmable layer to test the budget against"

let required_layer =
  match List.find_opt (fun id -> L.retention id = L.Required) all_layers with
  | Some id -> id
  | None -> failwith "no required layer"

let budget_content_of ~rows id =
  if id = trimmable_layer
  then Some (rows_section rows)
  else if id = required_layer
  then Some (L.Block "REQUIRED")
  else None

(* The property that makes the budget safe to turn on everywhere: a message
   that already fits is the same bytes it was before the budget existed. *)
let test_budget_under_is_byte_identical () =
  let content_of = budget_content_of ~rows:[ "a"; "b"; "c" ] in
  let unbudgeted = L.assemble ~content_of () in
  check string "fits -> identical to the unbudgeted assembly" unbudgeted
    (L.assemble ~budget_bytes:(String.length unbudgeted) ~content_of ());
  check string "far under budget -> still identical" unbudgeted
    (L.assemble ~budget_bytes:(String.length unbudgeted * 10) ~content_of ())

(* Rows go from the head, so what survives a cut is the newest end. *)
let test_budget_withholds_oldest_rows_first () =
  let content_of = budget_content_of ~rows:[ "old"; "mid"; "new" ] in
  let full = L.assemble ~content_of () in
  let trimmed = L.assemble ~budget_bytes:(String.length full - 1) ~content_of () in
  check bool "the oldest row is gone" false
    (Astring.String.is_infix ~affix:"old" trimmed);
  check bool "the newest row survives" true
    (Astring.String.is_infix ~affix:"new" trimmed);
  check bool "the heading counts what it shows" true
    (Astring.String.is_infix ~affix:"[shown=2/3]" trimmed)

(* A budget below what the rows alone cost must still not reach the layer that
   states what the turn is deciding about. *)
let test_budget_never_drops_a_required_layer () =
  let content_of = budget_content_of ~rows:[ "aaaa"; "bbbb"; "cccc" ] in
  let trimmed = L.assemble ~budget_bytes:1 ~content_of () in
  check bool "the required layer is still there" true
    (Astring.String.is_infix ~affix:"REQUIRED" trimmed);
  check bool "every row was given up first" true
    (Astring.String.is_infix ~affix:"[shown=0/3]" trimmed)

(* Best effort rather than a raise: an unmeetable budget returns the smallest
   assembly it could reach, because refusing to render a turn is worse than
   rendering one that the projection will size again. *)
let test_budget_unmeetable_returns_best_effort () =
  let content_of id = if id = required_layer then Some (L.Block "REQUIRED") else None in
  check string "nothing to give up -> the required layer as it stands" "REQUIRED"
    (L.assemble ~budget_bytes:1 ~content_of ())

(* Retention is a second axis over the same variant, so it has to stay total
   and unambiguous the way [order_index] does. *)
let test_retention_ranks_are_unique () =
  let ranks =
    all_layers
    |> List.filter_map (fun id ->
      match L.retention id with L.Required -> None | L.Trimmable rank -> Some rank)
  in
  check int "no two trimmable layers share a rank" (List.length ranks)
    (List.length (List.sort_uniq compare ranks))

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
      ( "budget",
        [
          test_case "under budget is byte-identical" `Quick
            test_budget_under_is_byte_identical;
          test_case "withholds the oldest rows first" `Quick
            test_budget_withholds_oldest_rows_first;
          test_case "never drops a required layer" `Quick
            test_budget_never_drops_a_required_layer;
          test_case "unmeetable budget returns best effort" `Quick
            test_budget_unmeetable_returns_best_effort;
          test_case "retention ranks are unique" `Quick
            test_retention_ranks_are_unique;
        ] );
    ]
