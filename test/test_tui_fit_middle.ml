(** Names that share a prefix have to stay distinguishable when they are cut.

    The roster cut identifiers with [fit_width], which keeps the head: two
    keepers whose names differ only past the cut rendered identically. The name
    in these cases is the one the live roster actually carried,
    "rw-e0-r9-20260820-revision-audit", drawn as "rw-e0-r9-20260820-revi~".

    A tail-only cut is the other half of the story — it keeps the tail and drops the
    head, which loses the family a name belongs to. [fit_middle] keeps both
    ends, and the assertions below are about that pair of properties rather
    than about one exact rendering: pinning the precise cut would fail on any
    change to the head/tail split without saying anything was actually lost. *)

open Alcotest
module Layout = Masc_tui_message_layout

let width = Layout.display_width

let contains ~needle haystack =
  let n = String.length needle
  and h = String.length haystack in
  let rec loop i = i + n <= h && (String.sub haystack i n = needle || loop (i + 1)) in
  n = 0 || loop 0
;;

(* The live name, and a sibling that differs only past where fit_width cut. *)
let audit = "rw-e0-r9-20260820-revision-audit"
let review = "rw-e0-r9-20260820-revision-review"
let roster_cells = 23

let test_siblings_stay_distinct () =
  let a = Layout.fit_middle roster_cells audit in
  let b = Layout.fit_middle roster_cells review in
  check bool "two keepers sharing a prefix do not render the same" false (a = b);
  (* What the roster used to do, kept here so the regression is legible. *)
  let head_only_a = Layout.fit_width audit roster_cells in
  let head_only_b = Layout.fit_width review roster_cells in
  check
    bool
    "head-only cutting is what made them identical"
    true
    (head_only_a = head_only_b)
;;

let test_both_ends_survive () =
  let cut = Layout.fit_middle roster_cells audit in
  check bool "the family prefix survives" true (contains ~needle:"rw-e0" cut);
  check bool "the deciding tail survives" true (contains ~needle:"audit" cut);
  check bool "the cut is marked" true (contains ~needle:"\xe2\x80\xa6" cut)
;;

(* Callers pad columns by trusting the returned width. A name that overruns and
   one that fits have to come back the same size or the column walks. *)
let test_width_is_exact () =
  List.iter
    (fun (label, name) ->
       List.iter
         (fun column ->
            check
              int
              (Printf.sprintf "%s at %d cells" label column)
              column
              (width (Layout.fit_middle column name)))
         [ 4; 8; 12; 23; 40 ])
    (* #30740 spelled the short case as a word that is also a live Keeper's
       name, which the identity guard claims. A short fixture only has to be
       short, so it does not need one. *)
    [ "long", audit; "short", "brisk"; "empty", "" ]
;;

(* As the column shrinks the head's third reaches zero, and the result becomes
   tail-only. That is the right thing to degrade into:
   between "which family" and "which one", the deciding end is the tail. *)
let test_narrow_degrades_to_tail () =
  let cut = Layout.fit_middle 8 audit in
  check int "still exactly the column" 8 (width cut);
  check bool "keeps the deciding end" true (contains ~needle:"audit" cut)
;;

let test_degenerate_columns () =
  check string "zero cells is empty" "" (Layout.fit_middle 0 audit);
  check string "one cell is the marker alone" "\xe2\x80\xa6" (Layout.fit_middle 1 audit);
  check int "two cells still measures two" 2 (width (Layout.fit_middle 2 audit))
;;

let () =
  run
    "tui fit_middle"
    [ ( "identifiers"
      , [ test_case "siblings stay distinct" `Quick test_siblings_stay_distinct
        ; test_case "both ends survive" `Quick test_both_ends_survive
        ; test_case "width is exact" `Quick test_width_is_exact
        ; test_case "narrow degrades to tail" `Quick test_narrow_degrades_to_tail
        ; test_case "degenerate columns" `Quick test_degenerate_columns
        ] )
    ]
;;
