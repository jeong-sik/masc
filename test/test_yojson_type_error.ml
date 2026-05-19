(** Minimal reproduction of Yojson Type_error
 *
 * This test case demonstrates the Type_error that occurs when
 * Yojson.Safe.Util.to_string is called on a non-string JSON value.
 *
 * The error pattern:
 * - Yojson.Safe.Util.to_string raises Type_error when given `Int, `Float, `Bool, `Null, `Assoc, `List
 * - This is a common pitfall in the codebase where JSON fields may contain
 *   unexpected types
 *
 * Run with: dune exec test/test_yojson_type_error.exe
 *)

open Yojson.Safe
open Yojson.Safe.Util

(* Reproduce the Type_error by calling to_string on non-string values *)
let () =
  print_endline "=== Yojson Type_error Reproduction ===";

  (* Case 1: to_string on `Int *)
  let int_json : json = `Int 42 in
  (try
    let _ = to_string int_json in
    print_endline "Case 1: No error (unexpected)"
  with
  | Type_error (msg, ctx) ->
      Printf.printf "Case 1: Type_error caught - %s in %s\n" msg ctx);

  (* Case 2: to_string on `Float *)
  let float_json : json = `Float 3.14 in
  (try
    let _ = to_string float_json in
    print_endline "Case 2: No error (unexpected)"
  with
  | Type_error (msg, ctx) ->
      Printf.printf "Case 2: Type_error caught - %s in %s\n" msg ctx);

  (* Case 3: to_string on `Bool *)
  let bool_json : json = `Bool true in
  (try
    let _ = to_string bool_json in
    print_endline "Case 3: No error (unexpected)"
  with
  | Type_error (msg, ctx) ->
      Printf.printf "Case 3: Type_error caught - %s in %s\n" msg ctx);

  (* Case 4: to_string on `Null *)
  let null_json : json = `Null in
  (try
    let _ = to_string null_json in
    print_endline "Case 4: No error (unexpected)"
  with
  | Type_error (msg, ctx) ->
      Printf.printf "Case 4: Type_error caught - %s in %s\n" msg ctx);

  (* Case 5: to_string on `Assoc *)
  let assoc_json : json = `Assoc [("key", `String "value")] in
  (try
    let _ = to_string assoc_json in
    print_endline "Case 5: No error (unexpected)"
  with
  | Type_error (msg, ctx) ->
      Printf.printf "Case 5: Type_error caught - %s in %s\n" msg ctx);

  (* Case 6: to_string on `List *)
  let list_json : json = `List [`Int 1; `Int 2; `Int 3] in
  (try
    let _ = to_string list_json in
    print_endline "Case 6: No error (unexpected)"
  with
  | Type_error (msg, ctx) ->
      Printf.printf "Case 6: Type_error caught - %s in %s\n" msg ctx);

  (* Case 7: Real-world pattern - member then to_string on missing key *)
  let json : json = `Assoc [("name", `String "test")] in
  (try
    let _ = json |> member "missing_key" |> to_string in
    print_endline "Case 7: No error (unexpected)"
  with
  | Type_error (msg, ctx) ->
      Printf.printf "Case 7: Type_error caught - %s in %s\n" msg ctx);

  (* Case 8: Real-world pattern - member then to_string on wrong type *)
  let json : json = `Assoc [("count", `Int 42)] in
  (try
    let _ = json |> member "count" |> to_string in
    print_endline "Case 8: No error (unexpected)"
  with
  | Type_error (msg, ctx) ->
      Printf.printf "Case 8: Type_error caught - %s in %s\n" msg ctx);

  print_endline "=== All cases demonstrated ==="