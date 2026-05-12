(** Tests for Masc_core.Set_util — Hashtbl-as-set kernels. *)

open Alcotest
module S = Set_util

(* ---------- of_list_with ---------- *)

let test_of_list_with_empty () =
  let tbl = S.of_list_with Fun.id [] in
  check int "empty" 0 (Hashtbl.length tbl)

let test_of_list_with_dedupes () =
  let tbl = S.of_list_with Fun.id [ "a"; "b"; "a"; "c"; "b" ] in
  check int "distinct keys" 3 (Hashtbl.length tbl);
  check bool "a present" true (Hashtbl.mem tbl "a");
  check bool "b present" true (Hashtbl.mem tbl "b");
  check bool "c present" true (Hashtbl.mem tbl "c");
  check bool "z absent" false (Hashtbl.mem tbl "z")

let test_of_list_with_key_projection () =
  let tbl = S.of_list_with fst [ (1, "x"); (2, "y"); (1, "z") ] in
  check int "distinct ints" 2 (Hashtbl.length tbl);
  check bool "1 present" true (Hashtbl.mem tbl 1);
  check bool "2 present" true (Hashtbl.mem tbl 2)

(* ---------- count_distinct ---------- *)

let test_count_distinct_empty () =
  check int "empty" 0 (S.count_distinct (fun _ -> Some 0) [])

let test_count_distinct_all_some () =
  check int "all distinct" 3
    (S.count_distinct (fun x -> Some x) [ 1; 2; 3 ])

let test_count_distinct_duplicates_counted_once () =
  check int "dup collapsed" 2
    (S.count_distinct (fun x -> Some x) [ "a"; "b"; "a"; "a" ])

let test_count_distinct_none_skipped () =
  check int "None skipped" 2
    (S.count_distinct
       (fun x -> if x mod 2 = 0 then Some x else None)
       [ 1; 2; 3; 4; 5 ])

(* ---------- count_difference ---------- *)

(* Mini event model isomorphic to telemetry_eio's joined/left flow. *)
type ev = Joined of string | Left of string | Other

let present = function Joined id -> Some id | Left _ | Other -> None
let absent = function Left id -> Some id | Joined _ | Other -> None

let test_count_difference_empty () =
  check int "empty" 0 (S.count_difference [] ~present ~absent)

let test_count_difference_all_present_no_absent () =
  let events = [ Joined "a"; Joined "b"; Joined "c" ] in
  check int "all present" 3 (S.count_difference events ~present ~absent)

let test_count_difference_some_absent () =
  (* a joined+left, b joined, c joined+left, d joined → diff = {b, d} = 2 *)
  let events =
    [ Joined "a"; Joined "b"; Left "a"; Joined "c"; Left "c"; Joined "d" ]
  in
  check int "joined \\ left" 2 (S.count_difference events ~present ~absent)

let test_count_difference_duplicate_present () =
  (* a joined twice, never left → still 1 *)
  let events = [ Joined "a"; Joined "a"; Joined "a" ] in
  check int "dup present collapsed" 1
    (S.count_difference events ~present ~absent)

let test_count_difference_present_after_absent () =
  (* absent recorded first; if present key matches, still excluded.
     Models a late-join after Left was emitted. Set-difference is
     order-independent over the full event list. *)
  let events = [ Left "a"; Joined "a" ] in
  check int "absent dominates" 0
    (S.count_difference events ~present ~absent)

(* ---------- Test runner ---------- *)

let () =
  run "set_util"
    [ ( "of_list_with",
        [ test_case "empty" `Quick test_of_list_with_empty;
          test_case "dedupes" `Quick test_of_list_with_dedupes;
          test_case "key projection" `Quick test_of_list_with_key_projection
        ] );
      ( "count_distinct",
        [ test_case "empty" `Quick test_count_distinct_empty;
          test_case "all some" `Quick test_count_distinct_all_some;
          test_case "duplicates counted once" `Quick
            test_count_distinct_duplicates_counted_once;
          test_case "None skipped" `Quick test_count_distinct_none_skipped ]
      );
      ( "count_difference",
        [ test_case "empty" `Quick test_count_difference_empty;
          test_case "all present no absent" `Quick
            test_count_difference_all_present_no_absent;
          test_case "some absent" `Quick test_count_difference_some_absent;
          test_case "duplicate present" `Quick
            test_count_difference_duplicate_present;
          test_case "absent dominates" `Quick
            test_count_difference_present_after_absent ] ) ]
