(** Tests for [Set_util] (lib/core, [masc_core] is [(wrapped false)]) —
    Hashtbl-as-set kernels. *)

open Alcotest
module S = Set_util

(* Mini event model isomorphic to telemetry_eio's joined/left flow. *)
type ev =
  | Joined of string
  | Left of string
  | Other

(* ---------- count_distinct ---------- *)

let test_count_distinct_empty () =
  check int "empty" 0 (S.count_distinct (fun x -> Some x) [])
;;

let test_count_distinct_skips_none_and_collapses_duplicates () =
  let key = function
    | Joined id -> Some id
    | Left id -> Some id
    | Other -> None
  in
  let events = [ Joined "a"; Left "a"; Other; Joined "b"; Joined "b" ] in
  check int "distinct ids" 2 (S.count_distinct key events)
;;

(* ---------- count_difference ---------- *)

let present = function
  | Joined id -> Some id
  | Left _ | Other -> None
;;

let absent = function
  | Left id -> Some id
  | Joined _ | Other -> None
;;

let test_count_difference_empty () =
  check int "empty" 0 (S.count_difference [] ~present ~absent)
;;

let test_count_difference_all_present_no_absent () =
  let events = [ Joined "a"; Joined "b"; Joined "c" ] in
  check int "all present" 3 (S.count_difference events ~present ~absent)
;;

let test_count_difference_some_absent () =
  (* a joined+left, b joined, c joined+left, d joined → diff = {b, d} = 2 *)
  let events = [ Joined "a"; Joined "b"; Left "a"; Joined "c"; Left "c"; Joined "d" ] in
  check int "joined \\ left" 2 (S.count_difference events ~present ~absent)
;;

let test_count_difference_duplicate_present () =
  (* a joined twice, never left → still 1 *)
  let events = [ Joined "a"; Joined "a"; Joined "a" ] in
  check int "dup present collapsed" 1 (S.count_difference events ~present ~absent)
;;

let test_count_difference_present_after_absent () =
  (* absent recorded first; if present key matches, still excluded.
     Models a late-join after Left was emitted. Set-difference is
     order-independent over the full event list. *)
  let events = [ Left "a"; Joined "a" ] in
  check int "absent dominates" 0 (S.count_difference events ~present ~absent)
;;

(* ---------- Test runner ---------- *)

let () =
  run
    "set_util"
    [ ( "count_distinct"
      , [ test_case "empty" `Quick test_count_distinct_empty
        ; test_case
            "skips none and collapses duplicates"
            `Quick
            test_count_distinct_skips_none_and_collapses_duplicates
        ] )
    ; ( "count_difference"
      , [ test_case "empty" `Quick test_count_difference_empty
        ; test_case
            "all present no absent"
            `Quick
            test_count_difference_all_present_no_absent
        ; test_case "some absent" `Quick test_count_difference_some_absent
        ; test_case "duplicate present" `Quick test_count_difference_duplicate_present
        ; test_case "absent dominates" `Quick test_count_difference_present_after_absent
        ] )
    ]
;;
