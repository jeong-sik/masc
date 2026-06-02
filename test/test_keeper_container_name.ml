(** RFC-0070 Phase 3b-ii — tests for [Keeper_container_name].

    Pins the derivation contract: determinism, uniqueness across
    distinct input tuples, length invariant, prefix invariant, and
    that the unit-separator collision guard works. *)

open Alcotest
open Masc_mcp

let make ?(algo = Keeper_hash_algo.SHA_256) ~turn_id ~attempt ~suffix () =
  Keeper_container_name.derive ~algo ~turn_id ~attempt ~suffix

(* ── Determinism: same input ⇒ same output ────────────────────── *)

let test_determinism_basic () =
  let a = make ~turn_id:1 ~attempt:0 ~suffix:"k" () in
  let b = make ~turn_id:1 ~attempt:0 ~suffix:"k" () in
  check string "same input → same output"
    (Keeper_container_name.to_string a)
    (Keeper_container_name.to_string b)

let test_determinism_sha512 () =
  let a = make ~algo:Keeper_hash_algo.SHA_512 ~turn_id:9 ~attempt:3 ~suffix:"persona" () in
  let b = make ~algo:Keeper_hash_algo.SHA_512 ~turn_id:9 ~attempt:3 ~suffix:"persona" () in
  check string "SHA-512 same input → same output"
    (Keeper_container_name.to_string a)
    (Keeper_container_name.to_string b)

(* ── Uniqueness: distinct input tuples ⇒ distinct outputs ──── *)

let test_uniqueness_turn_id () =
  let a = Keeper_container_name.to_string (make ~turn_id:1 ~attempt:0 ~suffix:"k" ()) in
  let b = Keeper_container_name.to_string (make ~turn_id:2 ~attempt:0 ~suffix:"k" ()) in
  if String.equal a b then fail "turn_id should distinguish containers"

let test_uniqueness_attempt () =
  let a = Keeper_container_name.to_string (make ~turn_id:1 ~attempt:0 ~suffix:"k" ()) in
  let b = Keeper_container_name.to_string (make ~turn_id:1 ~attempt:1 ~suffix:"k" ()) in
  if String.equal a b then fail "attempt should distinguish containers"

let test_uniqueness_suffix () =
  let a = Keeper_container_name.to_string (make ~turn_id:1 ~attempt:0 ~suffix:"alice" ()) in
  let b = Keeper_container_name.to_string (make ~turn_id:1 ~attempt:0 ~suffix:"bob" ()) in
  if String.equal a b then fail "suffix should distinguish containers"

let test_uniqueness_algo () =
  let a = Keeper_container_name.to_string
            (make ~algo:Keeper_hash_algo.SHA_256 ~turn_id:7 ~attempt:1 ~suffix:"x" ()) in
  let b = Keeper_container_name.to_string
            (make ~algo:Keeper_hash_algo.SHA_512 ~turn_id:7 ~attempt:1 ~suffix:"x" ()) in
  if String.equal a b then fail "algo choice should change the digest prefix"

(* ── Unit-separator collision guard ───────────────────────────── *)

(* The implementation uses \x1f (unit separator) between fields so
   that (turn_id=42, attempt=7) and (turn_id=4, attempt=27) cannot
   produce identical inputs by mere digit concatenation. *)

let test_no_field_boundary_collision () =
  let a = Keeper_container_name.to_string (make ~turn_id:42 ~attempt:7 ~suffix:"s" ()) in
  let b = Keeper_container_name.to_string (make ~turn_id:4 ~attempt:27 ~suffix:"s" ()) in
  if String.equal a b then fail "field-boundary collision — separator missing"

let test_no_attempt_suffix_boundary_collision () =
  (* Without separators, [Printf.sprintf "%d%d%s" 0 2 "3x"] and
     [Printf.sprintf "%d%d%s" 0 23 "x"] both produce "023x" — same
     string. With the \x1f unit separator they become distinct
     ("0\x1f2\x1f3x" vs "0\x1f23\x1fx"), and so do their digests. *)
  let a = Keeper_container_name.to_string (make ~turn_id:0 ~attempt:2 ~suffix:"3x" ()) in
  let b = Keeper_container_name.to_string (make ~turn_id:0 ~attempt:23 ~suffix:"x" ()) in
  if String.equal a b then fail "attempt/suffix-boundary collision — separator missing"

(* ── Length + prefix invariants ───────────────────────────────── *)

let test_length () =
  let n = Keeper_container_name.to_string (make ~turn_id:1 ~attempt:0 ~suffix:"k" ()) in
  check int "length = 12 + 32 = 44" 44 (String.length n)

let test_prefix () =
  let n = Keeper_container_name.to_string (make ~turn_id:1 ~attempt:0 ~suffix:"k" ()) in
  let has_prefix = String.length n >= 12 && String.sub n 0 12 = "masc-keeper-" in
  check bool "prefix = masc-keeper-" true has_prefix

let test_charset () =
  let n = Keeper_container_name.to_string (make ~turn_id:1 ~attempt:0 ~suffix:"k" ()) in
  (* After the "masc-keeper-" prefix, every char is a lowercase hex digit. *)
  let suffix = String.sub n 12 (String.length n - 12) in
  let valid =
    String.for_all (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) suffix
  in
  check bool "hex chars after prefix" true valid

(* ── Empty / large input edge cases ───────────────────────────── *)

let test_empty_suffix () =
  let n = Keeper_container_name.to_string (make ~turn_id:0 ~attempt:0 ~suffix:"" ()) in
  check int "empty suffix still yields full-length name" 44 (String.length n)

let test_large_inputs () =
  let big_suffix = String.make 10_000 'x' in
  let n = Keeper_container_name.to_string (make ~turn_id:max_int ~attempt:max_int ~suffix:big_suffix ()) in
  check int "large inputs still yield full-length name" 44 (String.length n)

(* ── equal / pp sanity ────────────────────────────────────────── *)

let test_equal_reflexive () =
  let n = make ~turn_id:1 ~attempt:0 ~suffix:"k" () in
  check bool "equal is reflexive" true (Keeper_container_name.equal n n)

let test_pp_matches_to_string () =
  let n = make ~turn_id:1 ~attempt:0 ~suffix:"k" () in
  let buf = Buffer.create 64 in
  let ppf = Format.formatter_of_buffer buf in
  Keeper_container_name.pp ppf n;
  Format.pp_print_flush ppf ();
  check string "pp emits to_string" (Keeper_container_name.to_string n) (Buffer.contents buf)

let () =
  run "Keeper_container_name"
    [
      ( "determinism",
        [
          test_case "SHA-256 same input → same output" `Quick test_determinism_basic;
          test_case "SHA-512 same input → same output" `Quick test_determinism_sha512;
        ] );
      ( "uniqueness",
        [
          test_case "turn_id distinguishes" `Quick test_uniqueness_turn_id;
          test_case "attempt distinguishes" `Quick test_uniqueness_attempt;
          test_case "suffix distinguishes" `Quick test_uniqueness_suffix;
          test_case "algo distinguishes" `Quick test_uniqueness_algo;
        ] );
      ( "collision guard",
        [
          test_case "no field-boundary collision (42/7 vs 4/27)" `Quick test_no_field_boundary_collision;
          test_case "no attempt/suffix-boundary collision (2/3x vs 23/x)" `Quick test_no_attempt_suffix_boundary_collision;
        ] );
      ( "format invariants",
        [
          test_case "length = 44" `Quick test_length;
          test_case "prefix = masc-keeper-" `Quick test_prefix;
          test_case "hex charset after prefix" `Quick test_charset;
        ] );
      ( "edge cases",
        [
          test_case "empty suffix" `Quick test_empty_suffix;
          test_case "max_int / large suffix" `Quick test_large_inputs;
        ] );
      ( "equal / pp",
        [
          test_case "equal reflexive" `Quick test_equal_reflexive;
          test_case "pp = to_string" `Quick test_pp_matches_to_string;
        ] );
    ]
