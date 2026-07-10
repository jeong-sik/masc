(** test_field_resolution — Unit tests for [Field_resolution].

    Verifies the three-way [Present | Missing | Type_mismatch]
    discrimination and the [or_default] / [require] helpers. The
    load-bearing case is [Type_mismatch] — the legacy
    `| Error _ -> Ok default` shape flattens it into a success
    with a default value, and these tests confirm the new module
    preserves the diagnostic. *)

module F = Field_resolution

let toml_of_string s =
  match Otoml.Parser.from_string_result s with
  | Ok t -> t
  | Error msg -> failwith ("toml parse failed: " ^ msg)

(* ── resolve_string ───────────────────────────────────────────── *)

let test_string_present () =
  let toml = toml_of_string {|name = "alice"|} in
  Alcotest.(check bool) "Present alice" true
    (match F.resolve_string toml [ "name" ] with
     | Present "alice" -> true
     | _ -> false)

let test_string_missing () =
  let toml = toml_of_string {|other = "value"|} in
  Alcotest.(check bool) "Missing" true
    (match F.resolve_string toml [ "name" ] with Missing -> true | _ -> false)

let test_string_type_mismatch () =
  let toml = toml_of_string {|name = 42|} in
  Alcotest.(check bool) "Type_mismatch string vs int" true
    (match F.resolve_string toml [ "name" ] with
     | Type_mismatch { path = [ "name" ]; expected = "string"; _ } -> true
     | _ -> false)

(* ── resolve_bool ────────────────────────────────────────────── *)

let test_bool_present () =
  let toml = toml_of_string {|enabled = true|} in
  Alcotest.(check bool) "Present true" true
    (match F.resolve_bool toml [ "enabled" ] with
     | Present true -> true
     | _ -> false)

let test_bool_type_mismatch () =
  let toml = toml_of_string {|enabled = "yes"|} in
  Alcotest.(check bool) "Type_mismatch bool vs string" true
    (match F.resolve_bool toml [ "enabled" ] with
     | Type_mismatch { expected = "bool"; _ } -> true
     | _ -> false)

(* ── resolve_int / resolve_strings ──────────────────────────── *)

let test_int_present () =
  let toml = toml_of_string {|n = 7|} in
  Alcotest.(check bool) "Present 7" true
    (match F.resolve_int toml [ "n" ] with Present 7 -> true | _ -> false)

let test_int_type_mismatch () =
  let toml = toml_of_string {|n = "seven"|} in
  Alcotest.(check bool) "Type_mismatch int vs string" true
    (match F.resolve_int toml [ "n" ] with
     | Type_mismatch { expected = "int"; _ } -> true
     | _ -> false)

let test_strings_present () =
  let toml = toml_of_string {|tags = ["a", "b"]|} in
  Alcotest.(check bool) "Present [a; b]" true
    (match F.resolve_strings toml [ "tags" ] with
     | Present [ "a"; "b" ] -> true
     | _ -> false)

let test_strings_type_mismatch_element () =
  let toml = toml_of_string {|tags = ["a", 2]|} in
  Alcotest.(check bool) "Type_mismatch on non-string element" true
    (match F.resolve_strings toml [ "tags" ] with
     | Type_mismatch { expected = "string list"; _ } -> true
     | _ -> false)

(* ── Nested path ─────────────────────────────────────────────── *)

let test_nested_path_present () =
  let toml = toml_of_string {|[repository.foo]
name = "bar"|} in
  Alcotest.(check bool) "nested Present" true
    (match F.resolve_string toml [ "repository"; "foo"; "name" ] with
     | Present "bar" -> true
     | _ -> false)

let test_nested_path_missing () =
  let toml = toml_of_string {|[repository.foo]
name = "bar"|} in
  Alcotest.(check bool) "nested Missing on different table" true
    (match F.resolve_string toml [ "repository"; "baz"; "name" ] with
     | Missing -> true
     | _ -> false)

let test_nested_path_scalar_parent_is_type_mismatch () =
  let toml = toml_of_string {|repository = "not-a-table"|} in
  Alcotest.(check bool) "scalar parent is not Missing" true
    (match F.resolve_string toml [ "repository"; "name" ] with
     | Type_mismatch { path = [ "repository" ]; expected = "table"; _ } -> true
     | Present _ | Missing | Type_mismatch _ -> false)

(* ── or_default / require ───────────────────────────────────── *)

let test_or_default_present () =
  let toml = toml_of_string {|name = "alice"|} in
  Alcotest.(check (result string string)) "Present passes through"
    (Ok "alice")
    (F.or_default ~default:"bob" (F.resolve_string toml [ "name" ]))

let test_or_default_missing () =
  let toml = toml_of_string {|other = "value"|} in
  Alcotest.(check (result string string)) "Missing → default"
    (Ok "bob")
    (F.or_default ~default:"bob" (F.resolve_string toml [ "name" ]))

let test_or_default_type_mismatch_propagates () =
  (* The load-bearing case. Legacy [Error _ -> Ok default] silently
     substituted "bob" here; or_default must Error instead. *)
  let toml = toml_of_string {|name = 42|} in
  let r = F.or_default ~default:"bob" (F.resolve_string toml [ "name" ]) in
  Alcotest.(check bool) "Type_mismatch → Error (not default)" true
    (match r with Error _ -> true | _ -> false)

let test_require_present () =
  let toml = toml_of_string {|url = "https://example.com"|} in
  Alcotest.(check (result string string)) "require Present"
    (Ok "https://example.com")
    (F.require (F.resolve_string toml [ "url" ]))

let test_require_missing_errors () =
  let toml = toml_of_string {|other = "value"|} in
  Alcotest.(check bool) "require Missing → Error" true
    (match F.require (F.resolve_string toml [ "url" ]) with
     | Error _ -> true
     | _ -> false)

let test_require_type_mismatch_errors () =
  let toml = toml_of_string {|url = 42|} in
  Alcotest.(check bool) "require Type_mismatch → Error" true
    (match F.require (F.resolve_string toml [ "url" ]) with
     | Error _ -> true
     | _ -> false)

let () =
  Alcotest.run "field_resolution"
    [
      ( "string"
      , [
          Alcotest.test_case "present" `Quick test_string_present;
          Alcotest.test_case "missing" `Quick test_string_missing;
          Alcotest.test_case "type_mismatch" `Quick test_string_type_mismatch;
        ] );
      ( "scalars"
      , [
          Alcotest.test_case "bool present" `Quick test_bool_present;
          Alcotest.test_case "bool type_mismatch" `Quick test_bool_type_mismatch;
          Alcotest.test_case "int present" `Quick test_int_present;
          Alcotest.test_case "int type_mismatch" `Quick test_int_type_mismatch;
        ] );
      ( "strings"
      , [
          Alcotest.test_case "strings present" `Quick test_strings_present;
          Alcotest.test_case "strings type_mismatch element" `Quick
            test_strings_type_mismatch_element;
        ] );
      ( "nested"
      , [
          Alcotest.test_case "present" `Quick test_nested_path_present;
          Alcotest.test_case "missing different table" `Quick
            test_nested_path_missing;
          Alcotest.test_case "scalar parent is type_mismatch" `Quick
            test_nested_path_scalar_parent_is_type_mismatch;
        ] );
      ( "or_default"
      , [
          Alcotest.test_case "present" `Quick test_or_default_present;
          Alcotest.test_case "missing returns default" `Quick
            test_or_default_missing;
          Alcotest.test_case "type_mismatch errors" `Quick
            test_or_default_type_mismatch_propagates;
        ] );
      ( "require"
      , [
          Alcotest.test_case "present" `Quick test_require_present;
          Alcotest.test_case "missing errors" `Quick test_require_missing_errors;
          Alcotest.test_case "type_mismatch errors" `Quick
            test_require_type_mismatch_errors;
        ] );
    ]
