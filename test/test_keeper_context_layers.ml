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
    L.Workspace_memory;
    L.Lane_updates;
    L.Repository_freshness;
    L.Autonomous_trigger;
    L.Scheduled_automation;
    L.Completion_authority;
    L.Task_cancellations;
    L.Pending_mentions;
    L.Scope_messages;
    L.Own_board_posts;
    L.Board_activity;
    L.Own_recent_actions;
    L.Recent_work;
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
    | L.Active_goals -> Some "A"
    | L.Autonomous_trigger -> Some "T"
    | L.Board_activity -> Some "B"
    | _ -> None
  in
  check string "present layers concatenated in ordered order" "ATB"
    (L.text (L.assemble ~content_of))

let test_assemble_empty_when_all_absent () =
  check string "no layers -> empty body" "" (L.text (L.assemble ~content_of:(fun _ -> None)))

let test_assemble_all_present_follows_ordered () =
  (* Each layer renders its own order index; the result must read 0..n-1.
     The expectation counts [all_layers], which is maintained by hand
     independently of [L.ordered], so a layer missing from either list still
     fails here — and adding a layer no longer means hand-editing a literal. *)
  let content_of id = Some (string_of_int (L.order_index id)) in
  let expected =
    List.init (List.length all_layers) string_of_int |> String.concat ""
  in
  check string "every layer present -> indices in order" expected
    (L.text (L.assemble ~content_of))

let test_issued_partition_preserves_occurrences () =
  let open Yojson.Safe.Util in
  let calls = ref [] in
  let repeated = "한글 \"same\"\n\\tail" in
  let rendered = L.assemble ~content_of:(fun layer ->
      calls := layer :: !calls;
      match layer with
      | L.Active_goals | L.Current_task -> Some repeated
      | L.Approval_authority -> Some ""
      | _ -> None)
    |> L.prepend_unattributed World_frame "" in
  let rendered = L.append_unattributed rendered Host_workspace_recall "HOST" in
  check bool "each producer is evaluated once in order" true (List.rev !calls = L.ordered);
  check string "source text is unchanged" (repeated ^ repeated ^ "HOST") (L.text rendered);
  let receipt = L.receipt_to_json rendered in
  let spans = member "spans" receipt |> to_list in
  check int "empty present layers and prefix retain their occurrences" 5 (List.length spans);
  check (list string) "repeated bytes retain distinct typed layer identities"
    ["active_goals"; "current_task"; "approval_authority"]
    (List.filter_map (fun span -> match member "layer" (member "source" span) with
      | `String name -> Some name | _ -> None) spans);
  let cursor = ref 0 in
  List.iter (fun span ->
    let offset = member "offset" span |> to_int in
    let bytes = member "bytes" span |> to_int in
    check int "contiguous actual source offset" !cursor offset;
    let actual = String.sub (L.text rendered) offset bytes in
    check string "actual slice hash" (member "sha256" span |> to_string)
      Digestif.SHA256.(digest_string actual |> to_hex);
    cursor := offset + bytes) spans;
  check int "all bytes accounted for" (String.length (L.text rendered)) !cursor

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
          test_case "issued partition preserves repeated and empty occurrences" `Quick
            test_issued_partition_preserves_occurrences;
          test_case "concatenates present layers in order" `Quick
            test_assemble_concatenates_present_in_order;
          test_case "empty when all absent" `Quick
            test_assemble_empty_when_all_absent;
          test_case "all present follows ordered" `Quick
            test_assemble_all_present_follows_ordered;
        ] );
    ]
