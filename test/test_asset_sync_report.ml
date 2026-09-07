(** What the boot log says after an asset sync, and what it used to lose.

    One line carried copies and deletions together and cut the shared sample
    at ten names. That is fine until a version bump, which copies enough
    assets to fill the sample by itself — and then the deleted paths are a
    count with no names. For the [Tools] domain that count is the only signal
    an operator gets that a definition they put in the runtime directory is
    gone, because tool definitions have no runtime edit layer.

    The first case below is that regression, written so it fails if the two
    budgets are ever merged again. *)

open Alcotest
module MAS = Masc.Managed_asset_sync

let result ?(copied = []) ?(overwritten = []) ?(removed = []) ?(failed = []) () =
  { MAS.copied; overwritten; removed; failed }
;;

let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec scan i = i + nl <= hl && (String.sub haystack i nl = needle || scan (i + 1)) in
  nl = 0 || scan 0
;;

let line_exn = function
  | Some line -> line
  | None -> failf "expected a line, got None"
;;

let path n = Printf.sprintf "tools/masc_generated_%02d.toml" n
let many n = List.init n path

let test_a_deletion_survives_a_full_copy_sample () =
  (* Enough copies to fill any shared sample twice over, and one deletion. *)
  let r = result ~copied:(many (MAS.sample_budget * 2)) ~removed:[ "tools/operator_own.toml" ] () in
  let removed = line_exn (MAS.removed_line ~label:"tool" r) in
  check bool "the deleted path is named" true (contains ~needle:"operator_own.toml" removed);
  (* And it is not buried in the copies: the two lines are separate, so the
     deletion line names nothing that was merely copied. *)
  check
    bool
    "no copied path leaks into the deletion line"
    false
    (contains ~needle:"masc_generated_00.toml" removed)
;;

let test_deletion_line_says_why () =
  let r = result ~removed:[ "tools/operator_own.toml" ] () in
  let removed = line_exn (MAS.removed_line ~label:"tool" r) in
  (* A path name alone reads as a distribution detail. The reason is what
     tells the operator their file is not coming back. *)
  check bool "the reason is stated" true (contains ~needle:"manifest" removed)
;;

let test_nothing_removed_is_no_line () =
  let r = result ~copied:[ path 1 ] ~overwritten:[ path 2 ] () in
  check bool "no deletion line" true (MAS.removed_line ~label:"tool" r = None)
;;

let test_nothing_copied_is_no_line () =
  let r = result ~removed:[ "tools/operator_own.toml" ] () in
  check bool "no distribution line" true (MAS.distribution_line ~label:"tool" r = None)
;;

(* An overwrite is an operator's edit being replaced, so the path is the
   message. Before this the line said "1 overwritten" and the operator had
   to guess which of 25 prompts, 154 tool definitions or 3 MCP surfaces it
   was -- the same count-without-names the removed line was fixed for. *)
let test_distribution_line_names_the_overwritten () =
  let r = result ~copied:(many 3) ~overwritten:[ path 7 ] () in
  let line = line_exn (MAS.distribution_line ~label:"prompt" r) in
  check bool "names the overwritten path" true (contains ~needle:(path 7) line)

(* Copies stay a count. A version bump makes dozens of them and the operator
   never had those files, so the paths crowd out the one class of entry they
   would act on. *)
let test_distribution_line_does_not_name_copies () =
  let r = result ~copied:[ path 1 ] ~overwritten:[ path 2 ] () in
  let line = line_exn (MAS.distribution_line ~label:"prompt" r) in
  check bool "copied path absent" false (contains ~needle:(path 1) line);
  check bool "overwritten path present" true (contains ~needle:(path 2) line)

(* The same budget the removed line holds: past ten the line says how many
   it did not print rather than growing without bound. *)
let test_distribution_line_caps_the_overwritten_sample () =
  let r = result ~overwritten:(many 14) () in
  let line = line_exn (MAS.distribution_line ~label:"tool" r) in
  check bool "says how many it withheld" true (contains ~needle:"and 4 more" line)

let test_distribution_line_counts_both_classes () =
  let r = result ~copied:(many 3) ~overwritten:(many 2) () in
  let line = line_exn (MAS.distribution_line ~label:"prompt" r) in
  check bool "copied count" true (contains ~needle:"3 copied" line);
  check bool "overwritten count" true (contains ~needle:"2 overwritten" line)
;;

let test_a_long_deletion_list_says_how_many_more () =
  let over = 5 in
  let r = result ~removed:(many (MAS.sample_budget + over)) () in
  let removed = line_exn (MAS.removed_line ~label:"tool" r) in
  check
    bool
    "the omitted count is stated"
    true
    (contains ~needle:(Printf.sprintf "and %d more" over) removed);
  (* Truncation has to keep the earlier names, not silently reorder. *)
  check bool "the first path is kept" true (contains ~needle:(path 0) removed)
;;

let () =
  run
    "asset_sync_report"
    [ ( "deletions"
      , [ test_case
            "a deletion survives a full copy sample"
            `Quick
            test_a_deletion_survives_a_full_copy_sample
        ; test_case "the deletion line says why" `Quick test_deletion_line_says_why
        ; test_case "nothing removed means no line" `Quick test_nothing_removed_is_no_line
        ; test_case
            "a long list says how many more"
            `Quick
            test_a_long_deletion_list_says_how_many_more
        ] )
    ; ( "copies"
      , [ test_case "nothing copied means no line" `Quick test_nothing_copied_is_no_line
        ; test_case
            "both classes are counted"
            `Quick
            test_distribution_line_counts_both_classes
        ; test_case
            "an overwrite is named"
            `Quick
            test_distribution_line_names_the_overwritten
        ; test_case
            "a copy is not named"
            `Quick
            test_distribution_line_does_not_name_copies
        ; test_case
            "the overwritten sample has the same budget"
            `Quick
            test_distribution_line_caps_the_overwritten_sample
        ] )
    ]
;;
