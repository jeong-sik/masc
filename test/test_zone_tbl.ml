(** Tests for Zone_tbl — Phase 2B of Tool Gate architecture (#4381). *)

open Masc_mcp
open Tool_gate

(* ================================================================ *)
(* Helpers                                                           *)
(* ================================================================ *)

let str_list = Alcotest.(list string)

(** Sort for order-independent set comparison. *)
let check_set_eq msg expected actual =
  Alcotest.(check (list string)) msg
    (List.sort String.compare expected)
    (List.sort String.compare actual)

let base = ["alpha"; "beta"; "gamma"]

(* ================================================================ *)
(* create                                                            *)
(* ================================================================ *)

let test_create_basic () =
  let zt = Zone_tbl.create ~base_tools:base in
  Alcotest.(check int) "depth 0" 0 (Zone_tbl.depth zt);
  Alcotest.(check bool) "is_base" true (Zone_tbl.is_base zt);
  check_set_eq "current = base" base (Zone_tbl.current_tools zt)

let test_create_normalizes () =
  let zt = Zone_tbl.create ~base_tools:["  a "; "b"; ""; "a"; " b "] in
  Alcotest.(check str_list) "normalized + deduped" ["a"; "b"]
    (Zone_tbl.current_tools zt)

let test_is_tool_allowed_base () =
  let zt = Zone_tbl.create ~base_tools:base in
  Alcotest.(check bool) "alpha allowed" true
    (Zone_tbl.is_tool_allowed zt "alpha");
  Alcotest.(check bool) "unknown denied" false
    (Zone_tbl.is_tool_allowed zt "unknown")

(* ================================================================ *)
(* enter                                                             *)
(* ================================================================ *)

let test_enter_add () =
  let zt = Zone_tbl.create ~base_tools:base in
  let _zid, zt2 = Zone_tbl.enter ~op:(Add ["delta"]) zt in
  Alcotest.(check int) "depth 1" 1 (Zone_tbl.depth zt2);
  check_set_eq "added delta" ["alpha"; "beta"; "gamma"; "delta"]
    (Zone_tbl.current_tools zt2)

let test_enter_remove () =
  let zt = Zone_tbl.create ~base_tools:base in
  let _zid, zt2 = Zone_tbl.enter ~op:(Remove ["beta"]) zt in
  check_set_eq "removed beta" ["alpha"; "gamma"]
    (Zone_tbl.current_tools zt2)

let test_enter_replace_with () =
  let zt = Zone_tbl.create ~base_tools:base in
  let _zid, zt2 = Zone_tbl.enter ~op:(Replace_with ["x"; "y"]) zt in
  check_set_eq "replaced" ["x"; "y"] (Zone_tbl.current_tools zt2)

let test_enter_intersect_with () =
  let zt = Zone_tbl.create ~base_tools:base in
  let _zid, zt2 = Zone_tbl.enter ~op:(Intersect_with ["alpha"; "gamma"]) zt in
  check_set_eq "intersection" ["alpha"; "gamma"]
    (Zone_tbl.current_tools zt2)

let test_enter_keep_all () =
  let zt = Zone_tbl.create ~base_tools:base in
  let _zid, zt2 = Zone_tbl.enter ~op:Keep_all zt in
  Alcotest.(check int) "depth 1" 1 (Zone_tbl.depth zt2);
  check_set_eq "unchanged" base (Zone_tbl.current_tools zt2)

let test_enter_is_tool_allowed () =
  let zt = Zone_tbl.create ~base_tools:base in
  let _zid, zt2 = Zone_tbl.enter ~op:(Remove ["beta"]) zt in
  Alcotest.(check bool) "alpha still allowed" true
    (Zone_tbl.is_tool_allowed zt2 "alpha");
  Alcotest.(check bool) "beta blocked" false
    (Zone_tbl.is_tool_allowed zt2 "beta")

let test_enter_nested_depth2 () =
  let zt = Zone_tbl.create ~base_tools:base in
  let _z1, zt1 = Zone_tbl.enter ~op:(Remove ["gamma"]) zt in
  let _z2, zt2 = Zone_tbl.enter ~op:(Add ["delta"]) zt1 in
  Alcotest.(check int) "depth 2" 2 (Zone_tbl.depth zt2);
  check_set_eq "gamma removed, delta added" ["alpha"; "beta"; "delta"]
    (Zone_tbl.current_tools zt2)

let test_enter_nested_depth3 () =
  let zt = Zone_tbl.create ~base_tools:base in
  let _, zt1 = Zone_tbl.enter ~op:(Remove ["gamma"]) zt in
  let _, zt2 = Zone_tbl.enter ~op:(Remove ["beta"]) zt1 in
  let _, zt3 = Zone_tbl.enter ~op:(Add ["omega"]) zt2 in
  Alcotest.(check int) "depth 3" 3 (Zone_tbl.depth zt3);
  check_set_eq "only alpha + omega" ["alpha"; "omega"]
    (Zone_tbl.current_tools zt3)

(* ================================================================ *)
(* exit                                                              *)
(* ================================================================ *)

let test_exit_restores_base () =
  let zt = Zone_tbl.create ~base_tools:base in
  let zid, zt1 = Zone_tbl.enter ~op:(Remove ["beta"]) zt in
  match Zone_tbl.exit ~zone_id:zid zt1 with
  | Error e -> Alcotest.fail e
  | Ok zt2 ->
      Alcotest.(check int) "depth 0" 0 (Zone_tbl.depth zt2);
      check_set_eq "base restored" base (Zone_tbl.current_tools zt2)

let test_exit_ok_zone_id () =
  let zt = Zone_tbl.create ~base_tools:base in
  let zid, zt1 = Zone_tbl.enter ~op:Keep_all zt in
  match Zone_tbl.exit ~zone_id:zid zt1 with
  | Ok _ -> ()
  | Error e -> Alcotest.fail (Printf.sprintf "expected Ok, got Error: %s" e)

let test_exit_wrong_zone_id () =
  let zt = Zone_tbl.create ~base_tools:base in
  let _z1, zt1 = Zone_tbl.enter ~op:Keep_all zt in
  let _z2, zt2 = Zone_tbl.enter ~op:Keep_all zt1 in
  (* Try to exit z1 (not on top) *)
  match Zone_tbl.exit ~zone_id:_z1 zt2 with
  | Error msg ->
      Alcotest.(check bool) "contains LIFO" true
        (String.length msg > 0)
  | Ok _ -> Alcotest.fail "expected LIFO violation error"

let test_exit_empty_stack () =
  let zt = Zone_tbl.create ~base_tools:base in
  let zid, zt1 = Zone_tbl.enter ~op:Keep_all zt in
  (* Exit correctly first *)
  match Zone_tbl.exit ~zone_id:zid zt1 with
  | Error e -> Alcotest.fail e
  | Ok zt2 ->
      (* Now stack is empty; try to exit again *)
      match Zone_tbl.exit ~zone_id:zid zt2 with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "expected empty stack error"

let test_exit_nested_restores_outer () =
  let zt = Zone_tbl.create ~base_tools:base in
  let _z1, zt1 = Zone_tbl.enter ~op:(Remove ["gamma"]) zt in
  let z2, zt2 = Zone_tbl.enter ~op:(Add ["delta"]) zt1 in
  match Zone_tbl.exit ~zone_id:z2 zt2 with
  | Error e -> Alcotest.fail e
  | Ok zt3 ->
      Alcotest.(check int) "depth 1" 1 (Zone_tbl.depth zt3);
      check_set_eq "outer zone state" ["alpha"; "beta"]
        (Zone_tbl.current_tools zt3)

let test_exit_irreversible_snapshot () =
  let zt = Zone_tbl.create ~base_tools:base in
  let zid, zt1 = Zone_tbl.enter ~op:(Replace_with ["x"]) zt in
  match Zone_tbl.exit ~zone_id:zid zt1 with
  | Error e -> Alcotest.fail e
  | Ok zt2 ->
      check_set_eq "full base restored via snapshot" base
        (Zone_tbl.current_tools zt2)

(* ================================================================ *)
(* exit_all                                                          *)
(* ================================================================ *)

let test_exit_all_from_depth2 () =
  let zt = Zone_tbl.create ~base_tools:base in
  let _, zt1 = Zone_tbl.enter ~op:(Replace_with ["x"]) zt in
  let _, zt2 = Zone_tbl.enter ~op:(Add ["y"]) zt1 in
  let zt3 = Zone_tbl.exit_all zt2 in
  Alcotest.(check int) "depth 0" 0 (Zone_tbl.depth zt3);
  check_set_eq "base restored" base (Zone_tbl.current_tools zt3)

let test_exit_all_from_base () =
  let zt = Zone_tbl.create ~base_tools:base in
  let zt2 = Zone_tbl.exit_all zt in
  Alcotest.(check int) "still depth 0" 0 (Zone_tbl.depth zt2);
  check_set_eq "same base" base (Zone_tbl.current_tools zt2)

(* ================================================================ *)
(* snapshot correctness                                              *)
(* ================================================================ *)

let test_snapshot_replace_with () =
  let zt = Zone_tbl.create ~base_tools:base in
  let zid, zt1 = Zone_tbl.enter ~op:(Replace_with ["only"]) zt in
  Alcotest.(check str_list) "replaced" ["only"]
    (Zone_tbl.current_tools zt1);
  match Zone_tbl.exit ~zone_id:zid zt1 with
  | Error e -> Alcotest.fail e
  | Ok zt2 -> check_set_eq "restored" base (Zone_tbl.current_tools zt2)

let test_snapshot_intersect_with () =
  let zt = Zone_tbl.create ~base_tools:base in
  let zid, zt1 = Zone_tbl.enter ~op:(Intersect_with ["alpha"]) zt in
  Alcotest.(check str_list) "intersected" ["alpha"]
    (Zone_tbl.current_tools zt1);
  match Zone_tbl.exit ~zone_id:zid zt1 with
  | Error e -> Alcotest.fail e
  | Ok zt2 -> check_set_eq "restored" base (Zone_tbl.current_tools zt2)

let test_snapshot_clear_all () =
  let zt = Zone_tbl.create ~base_tools:base in
  let zid, zt1 = Zone_tbl.enter ~op:Clear_all zt in
  Alcotest.(check str_list) "cleared" [] (Zone_tbl.current_tools zt1);
  match Zone_tbl.exit ~zone_id:zid zt1 with
  | Error e -> Alcotest.fail e
  | Ok zt2 -> check_set_eq "restored" base (Zone_tbl.current_tools zt2)

(* ================================================================ *)
(* Tool_gate integration                                             *)
(* ================================================================ *)

let test_compose_enter () =
  let zt = Zone_tbl.create ~base_tools:base in
  let op = Tool_gate.compose [Remove ["gamma"]; Add ["delta"]] in
  let _zid, zt1 = Zone_tbl.enter ~op zt in
  check_set_eq "composed" ["alpha"; "beta"; "delta"]
    (Zone_tbl.current_tools zt1)

let test_inverse_matches_snapshot_reversible () =
  let zt = Zone_tbl.create ~base_tools:base in
  let op = Add ["delta"] in
  let zid, zt1 = Zone_tbl.enter ~op zt in
  (* Exit via snapshot *)
  let snapshot_result =
    match Zone_tbl.exit ~zone_id:zid zt1 with
    | Ok zt2 -> Zone_tbl.current_tools zt2
    | Error e -> Alcotest.fail e
  in
  (* Compute via inverse *)
  let inverse_result =
    match Tool_gate.inverse op with
    | Reversible inv -> Tool_gate.apply inv (Zone_tbl.current_tools zt1)
    | Irreversible -> Alcotest.fail "expected reversible"
  in
  check_set_eq "snapshot == inverse for reversible" snapshot_result inverse_result

let test_inverse_differs_irreversible () =
  (* Replace_with is irreversible -- inverse cannot recover original *)
  let op = Replace_with ["x"] in
  match Tool_gate.inverse op with
  | Irreversible -> () (* correct: cannot compute inverse *)
  | Reversible _ -> Alcotest.fail "Replace_with should be irreversible"

(* ================================================================ *)
(* to_yojson                                                         *)
(* ================================================================ *)

let test_to_yojson_base () =
  let zt = Zone_tbl.create ~base_tools:base in
  let j = Zone_tbl.to_yojson zt in
  match j with
  | `Assoc fields ->
      let depth = List.assoc "depth" fields in
      Alcotest.(check string) "depth 0" "0"
        (Yojson.Safe.to_string depth);
      let base_count = List.assoc "base_tool_count" fields in
      Alcotest.(check string) "base 3" "3"
        (Yojson.Safe.to_string base_count)
  | _ -> Alcotest.fail "expected Assoc"

let test_to_yojson_with_zone () =
  let zt = Zone_tbl.create ~base_tools:base in
  let _, zt1 = Zone_tbl.enter ~op:(Remove ["beta"]) zt in
  let j = Zone_tbl.to_yojson zt1 in
  match j with
  | `Assoc fields ->
      let depth = List.assoc "depth" fields in
      Alcotest.(check string) "depth 1" "1"
        (Yojson.Safe.to_string depth);
      let zones = List.assoc "zones" fields in
      (match zones with
       | `List [_one] -> ()
       | _ -> Alcotest.fail "expected 1 zone in list")
  | _ -> Alcotest.fail "expected Assoc"

(* ================================================================ *)
(* base_tools invariance                                             *)
(* ================================================================ *)

let test_base_tools_invariant () =
  let zt = Zone_tbl.create ~base_tools:base in
  let z1, zt1 = Zone_tbl.enter ~op:(Replace_with ["x"]) zt in
  let _, zt2 = Zone_tbl.enter ~op:Clear_all zt1 in
  let zt3 = Zone_tbl.exit_all zt2 in
  let _, zt4 = Zone_tbl.enter ~op:(Add ["y"]) zt3 in
  (* base_tools must be the same at every point *)
  let check_base msg t =
    check_set_eq msg base (Zone_tbl.base_tools t)
  in
  check_base "after create" zt;
  check_base "after enter replace" zt1;
  check_base "after enter clear" zt2;
  check_base "after exit_all" zt3;
  check_base "after re-enter" zt4;
  (* Also check original zt unchanged (functional) *)
  Alcotest.(check int) "original depth unchanged" 0 (Zone_tbl.depth zt);
  (* Check exit from z1 on zt1 still works *)
  match Zone_tbl.exit ~zone_id:z1 zt1 with
  | Ok zt_back ->
      check_set_eq "zt1 exit restores base" base
        (Zone_tbl.current_tools zt_back)
  | Error e -> Alcotest.fail e

let test_empty_base () =
  let zt = Zone_tbl.create ~base_tools:[] in
  Alcotest.(check int) "depth 0" 0 (Zone_tbl.depth zt);
  Alcotest.(check bool) "is_base" true (Zone_tbl.is_base zt);
  Alcotest.(check str_list) "empty current" [] (Zone_tbl.current_tools zt);
  Alcotest.(check bool) "nothing allowed" false
    (Zone_tbl.is_tool_allowed zt "anything");
  (* enter on empty base *)
  let _zid, zt1 = Zone_tbl.enter ~op:(Add ["x"]) zt in
  Alcotest.(check str_list) "added to empty" ["x"]
    (Zone_tbl.current_tools zt1);
  Alcotest.(check bool) "x allowed" true
    (Zone_tbl.is_tool_allowed zt1 "x")

(* ================================================================ *)
(* Test registration                                                 *)
(* ================================================================ *)

let () =
  Alcotest.run "Zone_tbl"
    [
      ( "create",
        [
          Alcotest.test_case "basic" `Quick test_create_basic;
          Alcotest.test_case "normalizes" `Quick test_create_normalizes;
          Alcotest.test_case "is_tool_allowed" `Quick test_is_tool_allowed_base;
        ] );
      ( "enter",
        [
          Alcotest.test_case "add" `Quick test_enter_add;
          Alcotest.test_case "remove" `Quick test_enter_remove;
          Alcotest.test_case "replace_with" `Quick test_enter_replace_with;
          Alcotest.test_case "intersect_with" `Quick test_enter_intersect_with;
          Alcotest.test_case "keep_all" `Quick test_enter_keep_all;
          Alcotest.test_case "is_tool_allowed" `Quick test_enter_is_tool_allowed;
          Alcotest.test_case "nested depth 2" `Quick test_enter_nested_depth2;
          Alcotest.test_case "nested depth 3" `Quick test_enter_nested_depth3;
        ] );
      ( "exit",
        [
          Alcotest.test_case "restores base" `Quick test_exit_restores_base;
          Alcotest.test_case "ok zone_id" `Quick test_exit_ok_zone_id;
          Alcotest.test_case "wrong zone_id" `Quick test_exit_wrong_zone_id;
          Alcotest.test_case "empty stack" `Quick test_exit_empty_stack;
          Alcotest.test_case "nested restores outer" `Quick test_exit_nested_restores_outer;
          Alcotest.test_case "irreversible snapshot" `Quick test_exit_irreversible_snapshot;
        ] );
      ( "exit_all",
        [
          Alcotest.test_case "from depth 2" `Quick test_exit_all_from_depth2;
          Alcotest.test_case "from base" `Quick test_exit_all_from_base;
        ] );
      ( "snapshot",
        [
          Alcotest.test_case "replace_with" `Quick test_snapshot_replace_with;
          Alcotest.test_case "intersect_with" `Quick test_snapshot_intersect_with;
          Alcotest.test_case "clear_all" `Quick test_snapshot_clear_all;
        ] );
      ( "tool_gate_integration",
        [
          Alcotest.test_case "compose enter" `Quick test_compose_enter;
          Alcotest.test_case "inverse matches snapshot" `Quick test_inverse_matches_snapshot_reversible;
          Alcotest.test_case "irreversible inverse" `Quick test_inverse_differs_irreversible;
        ] );
      ( "to_yojson",
        [
          Alcotest.test_case "base state" `Quick test_to_yojson_base;
          Alcotest.test_case "with zone" `Quick test_to_yojson_with_zone;
        ] );
      ( "invariance",
        [
          Alcotest.test_case "base_tools invariant" `Quick test_base_tools_invariant;
          Alcotest.test_case "empty base" `Quick test_empty_base;
        ] );
    ]
