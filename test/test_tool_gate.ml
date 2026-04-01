(** Tests for Tool_gate — algebraic tool set operations. *)

open Alcotest
open Masc_mcp
open Tool_gate

let sl = list string

(** Compare as sorted sets (order-independent). *)
let check_set_eq msg expected actual =
  let sort = List.sort String.compare in
  check sl msg (sort expected) (sort actual)

(* ================================================================ *)
(* apply — basic                                                     *)
(* ================================================================ *)

let base = ["a"; "b"; "c"]

let test_apply_keep_all () =
  check sl "identity" base (Tool_gate.apply Keep_all base)

let test_apply_clear_all () =
  check sl "empty" [] (Tool_gate.apply Clear_all base)

let test_apply_add () =
  check sl "union" ["a"; "b"; "c"; "d"]
    (Tool_gate.apply (Add ["d"]) base)

let test_apply_add_duplicate () =
  check sl "no dup" ["a"; "b"; "c"]
    (Tool_gate.apply (Add ["a"]) base)

let test_apply_add_empty () =
  check sl "identity" base
    (Tool_gate.apply (Add []) base)

let test_apply_remove () =
  check sl "diff" ["a"; "c"]
    (Tool_gate.apply (Remove ["b"]) base)

let test_apply_remove_absent () =
  check sl "no change" base
    (Tool_gate.apply (Remove ["x"]) base)

let test_apply_remove_empty () =
  check sl "identity" base
    (Tool_gate.apply (Remove []) base)

let test_apply_replace_with () =
  check sl "replaced" ["x"; "y"]
    (Tool_gate.apply (Replace_with ["x"; "y"]) base)

let test_apply_replace_with_empty () =
  check sl "empty" []
    (Tool_gate.apply (Replace_with []) base)

let test_apply_intersect () =
  check sl "intersection" ["a"; "c"]
    (Tool_gate.apply (Intersect_with ["a"; "c"; "z"]) base)

let test_apply_intersect_empty () =
  check sl "empty" []
    (Tool_gate.apply (Intersect_with []) base)

let test_apply_intersect_disjoint () =
  check sl "empty" []
    (Tool_gate.apply (Intersect_with ["x"; "y"]) base)

let test_apply_seq () =
  check sl "sequential"
    ["a"; "c"; "d"]
    (Tool_gate.apply (Seq [Remove ["b"]; Add ["d"]]) base)

let test_apply_seq_empty () =
  check sl "identity" base
    (Tool_gate.apply (Seq []) base)

(* apply on empty input *)
let test_apply_add_to_empty () =
  check sl "add to empty" ["x"]
    (Tool_gate.apply (Add ["x"]) [])

let test_apply_remove_from_empty () =
  check sl "remove from empty" []
    (Tool_gate.apply (Remove ["x"]) [])

let test_apply_intersect_on_empty () =
  check sl "intersect empty" []
    (Tool_gate.apply (Intersect_with ["x"]) [])

(* whitespace / dedup normalization *)
let test_apply_add_whitespace () =
  check sl "trimmed" ["a"; "b"; "c"; "d"]
    (Tool_gate.apply (Add [" d "; "d"]) base)

(* ================================================================ *)
(* inverse                                                           *)
(* ================================================================ *)

let test_inverse_keep_all () =
  match Tool_gate.inverse Keep_all with
  | Reversible Keep_all -> ()
  | _ -> fail "expected Reversible Keep_all"

let test_inverse_clear_all () =
  match Tool_gate.inverse Clear_all with
  | Irreversible -> ()
  | _ -> fail "expected Irreversible"

let test_inverse_add () =
  match Tool_gate.inverse (Add ["x"; "y"]) with
  | Reversible (Remove names) ->
      check sl "inverse names" ["x"; "y"] names
  | _ -> fail "expected Reversible Remove"

let test_inverse_remove () =
  match Tool_gate.inverse (Remove ["x"]) with
  | Reversible (Add names) ->
      check sl "inverse names" ["x"] names
  | _ -> fail "expected Reversible Add"

let test_inverse_replace_with () =
  match Tool_gate.inverse (Replace_with ["x"]) with
  | Irreversible -> ()
  | _ -> fail "expected Irreversible"

let test_inverse_intersect_with () =
  match Tool_gate.inverse (Intersect_with ["x"]) with
  | Irreversible -> ()
  | _ -> fail "expected Irreversible"

let test_inverse_seq_reversible () =
  let op = Seq [Add ["x"]; Remove ["y"]] in
  match Tool_gate.inverse op with
  | Reversible (Seq [Add ["y"]; Remove ["x"]]) -> ()
  | Reversible other ->
      fail (Printf.sprintf "unexpected: %s"
        (Yojson.Safe.to_string (Tool_gate.to_yojson other)))
  | Irreversible -> fail "expected Reversible Seq"

let test_inverse_seq_irreversible () =
  let op = Seq [Add ["x"]; Clear_all] in
  match Tool_gate.inverse op with
  | Irreversible -> ()
  | _ -> fail "expected Irreversible"

(* roundtrip: apply inverse undoes effective op *)
let test_roundtrip_add () =
  let original = ["a"; "b"] in
  let op = Add ["c"; "d"] in
  let modified = Tool_gate.apply op original in
  match Tool_gate.inverse op with
  | Reversible inv ->
      let restored = Tool_gate.apply inv modified in
      check sl "roundtrip" original restored
  | Irreversible -> fail "Add should be reversible"

let test_roundtrip_remove () =
  let original = ["a"; "b"; "c"] in
  let op = Remove ["b"] in
  let modified = Tool_gate.apply op original in
  match Tool_gate.inverse op with
  | Reversible inv ->
      let restored = Tool_gate.apply inv modified in
      (* Roundtrip preserves set membership, not insertion order.
         Add appends to the end, so "b" moves from position 1 to end. *)
      check_set_eq "roundtrip set" original restored
  | Irreversible -> fail "Remove should be reversible"

(* Documented limitation: phantom addition when Remove is a no-op *)
let test_roundtrip_phantom () =
  let original = ["a"] in
  let op = Remove ["b"] in
  let modified = Tool_gate.apply op original in
  check sl "no-op remove" ["a"] modified;
  match Tool_gate.inverse op with
  | Reversible inv ->
      let restored = Tool_gate.apply inv modified in
      (* This is the documented phantom: "b" was never in original *)
      check sl "phantom addition" ["a"; "b"] restored;
      check bool "not equal to original" false (original = restored)
  | Irreversible -> fail "Remove should be reversible"

(* ================================================================ *)
(* compose                                                           *)
(* ================================================================ *)

let test_compose_empty () =
  check bool "Keep_all" true
    (Tool_gate.equal (Tool_gate.compose []) Keep_all)

let test_compose_single () =
  let op = Add ["x"] in
  check bool "unwrap" true
    (Tool_gate.equal (Tool_gate.compose [op]) op)

let test_compose_flatten () =
  let result = Tool_gate.compose [Seq [Add ["a"]; Add ["b"]]; Remove ["c"]] in
  match result with
  | Seq [Add _; Add _; Remove _] -> ()
  | _ -> fail (Printf.sprintf "expected flat Seq, got %s"
    (Yojson.Safe.to_string (Tool_gate.to_yojson result)))

let test_compose_identity_elimination () =
  let op = Remove ["x"] in
  let result = Tool_gate.compose [Keep_all; op; Keep_all] in
  check bool "unwrap" true (Tool_gate.equal result op)

let test_compose_all_identity () =
  let result = Tool_gate.compose [Add []; Remove []] in
  check bool "Keep_all" true (Tool_gate.equal result Keep_all)

let test_compose_deep_flatten () =
  let result = Tool_gate.compose [Seq [Seq [Add ["a"]]]; Remove ["b"]] in
  match result with
  | Seq [Add _; Remove _] -> ()
  | _ -> fail (Printf.sprintf "expected deep flatten, got %s"
    (Yojson.Safe.to_string (Tool_gate.to_yojson result)))

(* ================================================================ *)
(* is_identity                                                       *)
(* ================================================================ *)

let test_is_identity_keep_all () =
  check bool "Keep_all" true (Tool_gate.is_identity Keep_all)

let test_is_identity_add_empty () =
  check bool "Add []" true (Tool_gate.is_identity (Add []))

let test_is_identity_remove_empty () =
  check bool "Remove []" true (Tool_gate.is_identity (Remove []))

let test_is_identity_intersect_empty () =
  check bool "Intersect_with [] is NOT identity" false
    (Tool_gate.is_identity (Intersect_with []))

let test_is_identity_add_nonempty () =
  check bool "Add [x]" false (Tool_gate.is_identity (Add ["x"]))

let test_is_identity_seq_recursive () =
  check bool "Seq of identities" true
    (Tool_gate.is_identity (Seq [Keep_all; Add []; Remove []]))

let test_is_identity_seq_mixed () =
  check bool "Seq with non-identity" false
    (Tool_gate.is_identity (Seq [Keep_all; Add ["x"]]))

(* ================================================================ *)
(* is_irreversible                                                   *)
(* ================================================================ *)

let test_is_irreversible_clear () =
  check bool "Clear_all" true (Tool_gate.is_irreversible Clear_all)

let test_is_irreversible_add () =
  check bool "Add" false (Tool_gate.is_irreversible (Add ["x"]))

let test_is_irreversible_replace () =
  check bool "Replace_with" true (Tool_gate.is_irreversible (Replace_with ["x"]))

let test_is_irreversible_intersect () =
  check bool "Intersect_with" true (Tool_gate.is_irreversible (Intersect_with ["x"]))

let test_is_irreversible_seq () =
  check bool "Seq with Clear_all" true
    (Tool_gate.is_irreversible (Seq [Add ["x"]; Clear_all]))

let test_is_irreversible_seq_ok () =
  check bool "Seq all reversible" false
    (Tool_gate.is_irreversible (Seq [Add ["x"]; Remove ["y"]]))

(* ================================================================ *)
(* equal                                                             *)
(* ================================================================ *)

let test_equal_add_order () =
  check bool "normalized" true
    (Tool_gate.equal (Add ["a"; "b"]) (Add ["b"; "a"]))

let test_equal_structural () =
  check bool "different structure" false
    (Tool_gate.equal (Add ["a"]) (Seq [Add ["a"]]))

let test_equal_keep_all () =
  check bool "same" true
    (Tool_gate.equal Keep_all Keep_all)

let test_equal_different_variant () =
  check bool "different" false
    (Tool_gate.equal (Add ["a"]) (Remove ["a"]))

(* ================================================================ *)
(* to_yojson                                                         *)
(* ================================================================ *)

let test_to_yojson_keep_all () =
  let json = Tool_gate.to_yojson Keep_all in
  match json with
  | `Assoc [("op", `String "keep_all")] -> ()
  | _ -> fail "unexpected JSON"

let test_to_yojson_seq () =
  let json = Tool_gate.to_yojson (Seq [Add ["a"]; Remove ["b"]]) in
  match json with
  | `Assoc [("op", `String "seq"); ("ops", `List [_; _])] -> ()
  | _ -> fail "unexpected JSON"

let test_inverse_result_to_yojson () =
  let json = Tool_gate.inverse_result_to_yojson Irreversible in
  match json with
  | `Assoc [("irreversible", `Bool true)] -> ()
  | _ -> fail "unexpected JSON"

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

let () =
  run "Tool_gate"
    [
      ( "apply",
        [
          test_case "Keep_all" `Quick test_apply_keep_all;
          test_case "Clear_all" `Quick test_apply_clear_all;
          test_case "Add" `Quick test_apply_add;
          test_case "Add duplicate" `Quick test_apply_add_duplicate;
          test_case "Add empty" `Quick test_apply_add_empty;
          test_case "Remove" `Quick test_apply_remove;
          test_case "Remove absent" `Quick test_apply_remove_absent;
          test_case "Remove empty" `Quick test_apply_remove_empty;
          test_case "Replace_with" `Quick test_apply_replace_with;
          test_case "Replace_with empty" `Quick test_apply_replace_with_empty;
          test_case "Intersect_with" `Quick test_apply_intersect;
          test_case "Intersect_with empty" `Quick test_apply_intersect_empty;
          test_case "Intersect_with disjoint" `Quick test_apply_intersect_disjoint;
          test_case "Seq" `Quick test_apply_seq;
          test_case "Seq empty" `Quick test_apply_seq_empty;
          test_case "Add to empty" `Quick test_apply_add_to_empty;
          test_case "Remove from empty" `Quick test_apply_remove_from_empty;
          test_case "Intersect on empty" `Quick test_apply_intersect_on_empty;
          test_case "Add whitespace" `Quick test_apply_add_whitespace;
        ] );
      ( "inverse",
        [
          test_case "Keep_all" `Quick test_inverse_keep_all;
          test_case "Clear_all" `Quick test_inverse_clear_all;
          test_case "Add" `Quick test_inverse_add;
          test_case "Remove" `Quick test_inverse_remove;
          test_case "Replace_with" `Quick test_inverse_replace_with;
          test_case "Intersect_with" `Quick test_inverse_intersect_with;
          test_case "Seq reversible" `Quick test_inverse_seq_reversible;
          test_case "Seq irreversible" `Quick test_inverse_seq_irreversible;
          test_case "roundtrip Add" `Quick test_roundtrip_add;
          test_case "roundtrip Remove" `Quick test_roundtrip_remove;
          test_case "roundtrip phantom" `Quick test_roundtrip_phantom;
        ] );
      ( "compose",
        [
          test_case "empty" `Quick test_compose_empty;
          test_case "single" `Quick test_compose_single;
          test_case "flatten" `Quick test_compose_flatten;
          test_case "identity elimination" `Quick test_compose_identity_elimination;
          test_case "all identity" `Quick test_compose_all_identity;
          test_case "deep flatten" `Quick test_compose_deep_flatten;
        ] );
      ( "is_identity",
        [
          test_case "Keep_all" `Quick test_is_identity_keep_all;
          test_case "Add []" `Quick test_is_identity_add_empty;
          test_case "Remove []" `Quick test_is_identity_remove_empty;
          test_case "Intersect_with []" `Quick test_is_identity_intersect_empty;
          test_case "Add nonempty" `Quick test_is_identity_add_nonempty;
          test_case "Seq recursive" `Quick test_is_identity_seq_recursive;
          test_case "Seq mixed" `Quick test_is_identity_seq_mixed;
        ] );
      ( "is_irreversible",
        [
          test_case "Clear_all" `Quick test_is_irreversible_clear;
          test_case "Add" `Quick test_is_irreversible_add;
          test_case "Replace_with" `Quick test_is_irreversible_replace;
          test_case "Intersect_with" `Quick test_is_irreversible_intersect;
          test_case "Seq with irreversible" `Quick test_is_irreversible_seq;
          test_case "Seq all reversible" `Quick test_is_irreversible_seq_ok;
        ] );
      ( "equal",
        [
          test_case "Add order" `Quick test_equal_add_order;
          test_case "structural" `Quick test_equal_structural;
          test_case "Keep_all" `Quick test_equal_keep_all;
          test_case "different variant" `Quick test_equal_different_variant;
        ] );
      ( "to_yojson",
        [
          test_case "Keep_all" `Quick test_to_yojson_keep_all;
          test_case "Seq" `Quick test_to_yojson_seq;
          test_case "inverse_result" `Quick test_inverse_result_to_yojson;
        ] );
    ]
