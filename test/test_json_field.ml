(** test_json_field — Unit tests for [Json_field].

    Verifies the three-way [Found | Field_absent | Wrong_shape]
    discrimination and the [to_option] / [log_wrong_shape] /
    [require] helpers. The load-bearing case is [Wrong_shape]: the
    legacy catch-all flattened it into [None], and these tests
    confirm the new module preserves the diagnostic. *)

open Masc_mcp
module J = Json_field

let assoc fields : Yojson.Safe.t = `Assoc fields

(* ── string ───────────────────────────────────────────────────── *)

let test_string_found () =
  let json = assoc [ "name", `String "alice" ] in
  match J.string json "name" with
  | Found "alice" -> ()
  | other ->
    Alcotest.failf "expected Found alice, got %s"
      (match other with
       | Found s -> "Found " ^ s
       | Field_absent -> "Field_absent"
       | Wrong_shape { expected; got } ->
         Printf.sprintf "Wrong_shape{%s/%s}" expected got)

let test_string_absent () =
  let json = assoc [ "other", `String "value" ] in
  Alcotest.(check bool) "field_absent" true
    (match J.string json "name" with Field_absent -> true | _ -> false)

let test_string_wrong_shape () =
  let json = assoc [ "name", `Int 42 ] in
  match J.string json "name" with
  | Wrong_shape { expected = "string"; got = "int" } -> ()
  | other ->
    Alcotest.failf "expected Wrong_shape string/int, got %s"
      (match other with
       | Found s -> "Found " ^ s
       | Field_absent -> "Field_absent"
       | Wrong_shape { expected; got } ->
         Printf.sprintf "Wrong_shape{%s/%s}" expected got)

let test_string_non_assoc_root () =
  let json : Yojson.Safe.t = `List [ `String "a" ] in
  Alcotest.(check bool) "non-assoc root → Field_absent" true
    (match J.string json "any" with Field_absent -> true | _ -> false)

(* ── int / bool / float ───────────────────────────────────────── *)

let test_int_found_and_wrong () =
  let json = assoc [ "n", `Int 7; "s", `String "x" ] in
  Alcotest.(check bool) "int found" true
    (match J.int json "n" with Found 7 -> true | _ -> false);
  Alcotest.(check bool) "int wrong_shape on string" true
    (match J.int json "s" with
     | Wrong_shape { expected = "int"; got = "string" } -> true
     | _ -> false)

let test_bool_found () =
  let json = assoc [ "b", `Bool false ] in
  Alcotest.(check bool) "bool found" true
    (match J.bool json "b" with Found false -> true | _ -> false)

let test_float_accepts_int () =
  (* Mixed numeric is a wire reality, not schema drift: float should
     accept [`Int]. *)
  let json = assoc [ "f", `Int 3 ] in
  Alcotest.(check bool) "float accepts int → 3.0" true
    (match J.float json "f" with Found 3.0 -> true | _ -> false)

(* ── assoc / list ─────────────────────────────────────────────── *)

let test_assoc_found () =
  let json = assoc [ "meta", `Assoc [ "k", `String "v" ] ] in
  Alcotest.(check bool) "assoc found single field" true
    (match J.assoc json "meta" with
     | Found [ ("k", `String "v") ] -> true
     | _ -> false)

let test_list_wrong_shape () =
  let json = assoc [ "items", `String "not-a-list" ] in
  Alcotest.(check bool) "list wrong_shape on string" true
    (match J.list json "items" with
     | Wrong_shape { expected = "list"; got = "string" } -> true
     | _ -> false)

(* ── to_option / log_wrong_shape / require ───────────────────── *)

let test_to_option_collapses () =
  let json = assoc [ "k", `Int 1 ] in
  Alcotest.(check (option string)) "found → Some" (Some "x")
    (J.to_option (J.string (assoc [ "k", `String "x" ]) "k"));
  Alcotest.(check (option string)) "absent → None" None
    (J.to_option (J.string json "absent"));
  Alcotest.(check (option string)) "wrong shape → None" None
    (J.to_option (J.string json "k"))

let test_log_wrong_shape_returns_none () =
  (* The log line is a side effect we don't capture here; the
     contract is that the function returns None on Wrong_shape and
     does not raise. *)
  let json = assoc [ "k", `Int 1 ] in
  Alcotest.(check (option string)) "log_wrong_shape returns None" None
    (J.log_wrong_shape ~label:"test_log" (J.string json "k"))

let test_require_errors_on_absent_and_wrong () =
  let json = assoc [ "k", `Int 1 ] in
  Alcotest.(check bool) "require found ok" true
    (match J.require (J.string (assoc [ "k", `String "x" ]) "k") with
     | Ok "x" -> true | _ -> false);
  Alcotest.(check bool) "require absent → Error" true
    (match J.require (J.string json "absent") with
     | Error _ -> true | _ -> false);
  Alcotest.(check bool) "require wrong shape → Error" true
    (match J.require (J.string json "k") with
     | Error _ -> true | _ -> false)

(* ── Yojson.Safe variant coverage ─────────────────────────────── *)

let test_intlit_reported_as_intlit () =
  (* JSON integers wider than OCaml's int land as [`Intlit] — the
     classifier should preserve that as a distinct [got] value so
     the operator log shows the truth, not "int". *)
  let json = assoc [ "n", `Intlit "99999999999999999999" ] in
  Alcotest.(check bool) "intlit → Wrong_shape{int/intlit}" true
    (match J.int json "n" with
     | Wrong_shape { expected = "int"; got = "intlit" } -> true
     | _ -> false)

let test_null_reported_as_null () =
  let json = assoc [ "k", `Null ] in
  Alcotest.(check bool) "null value → Wrong_shape{string/null}" true
    (match J.string json "k" with
     | Wrong_shape { expected = "string"; got = "null" } -> true
     | _ -> false)

let () =
  Alcotest.run "json_field"
    [
      ( "string"
      , [
          Alcotest.test_case "found" `Quick test_string_found;
          Alcotest.test_case "absent" `Quick test_string_absent;
          Alcotest.test_case "wrong_shape" `Quick test_string_wrong_shape;
          Alcotest.test_case "non-assoc root" `Quick test_string_non_assoc_root;
        ] );
      ( "scalars"
      , [
          Alcotest.test_case "int" `Quick test_int_found_and_wrong;
          Alcotest.test_case "bool" `Quick test_bool_found;
          Alcotest.test_case "float accepts int" `Quick test_float_accepts_int;
        ] );
      ( "containers"
      , [
          Alcotest.test_case "assoc" `Quick test_assoc_found;
          Alcotest.test_case "list wrong shape" `Quick test_list_wrong_shape;
        ] );
      ( "helpers"
      , [
          Alcotest.test_case "to_option" `Quick test_to_option_collapses;
          Alcotest.test_case "log_wrong_shape" `Quick test_log_wrong_shape_returns_none;
          Alcotest.test_case "require" `Quick test_require_errors_on_absent_and_wrong;
        ] );
      ( "yojson_safe_variants"
      , [
          Alcotest.test_case "intlit" `Quick test_intlit_reported_as_intlit;
          Alcotest.test_case "null" `Quick test_null_reported_as_null;
        ] );
    ]
