(** Unit tests for Keeper_json_parse — simple JSON parser *)

let parse_ok input expected =
  match Keeper_json_parse.parse input with
  | Error msg -> Alcotest.fail ("expected Ok, got Error: " ^ msg)
  | Ok v ->
    let actual_str = Keeper_json_parse.to_string v in
    let expected_str = Keeper_json_parse.to_string expected in
    if actual_str <> expected_str then
      Alcotest.failf "mismatch: got %S, expected %S" actual_str expected_str

let parse_err input =
  match Keeper_json_parse.parse input with
  | Ok v -> Alcotest.failf "expected Error, got Ok: %s" (Keeper_json_parse.to_string v)
  | Error _ -> ()

let test_null () =
  parse_ok "null" Keeper_json_parse.Null

let test_true () =
  parse_ok "true" (Keeper_json_parse.Bool true)

let test_false () =
  parse_ok "false" (Keeper_json_parse.Bool false)

let test_integer () =
  parse_ok "42" (Keeper_json_parse.Int 42);
  parse_ok "-17" (Keeper_json_parse.Int (-17));
  parse_ok "0" (Keeper_json_parse.Int 0)

let test_float () =
  parse_ok "3.14" (Keeper_json_parse.Float 3.14);
  parse_ok "-0.5" (Keeper_json_parse.Float (-0.5));
  parse_ok "1e10" (Keeper_json_parse.Float 1e10);
  parse_ok "2.5e-3" (Keeper_json_parse.Float 2.5e-3)

let test_string () =
  parse_ok "\"hello\"" (Keeper_json_parse.String "hello");
  parse_ok "\"\"" (Keeper_json_parse.String "");
  parse_ok "\"hello\\nworld\"" (Keeper_json_parse.String "hello\nworld");
  parse_ok "\"tab\\there\"" (Keeper_json_parse.String "tab\there");
  parse_ok "\"quo\\\"te\"" (Keeper_json_parse.String "quo\"te");
  parse_ok "\"slash\\\\back\"" (Keeper_json_parse.String "slash\\back")

let test_array () =
  parse_ok "[]" (Keeper_json_parse.Array []);
  parse_ok "[1,2,3]" (Keeper_json_parse.Array [Keeper_json_parse.Int 1; Keeper_json_parse.Int 2; Keeper_json_parse.Int 3]);
  parse_ok "[null,true,false]" (Keeper_json_parse.Array [Keeper_json_parse.Null; Keeper_json_parse.Bool true; Keeper_json_parse.Bool false]);
  parse_ok "[[1],[]]" (Keeper_json_parse.Array [Keeper_json_parse.Array [Keeper_json_parse.Int 1]; Keeper_json_parse.Array []])

let test_object () =
  parse_ok "{}" (Keeper_json_parse.Object []);
  parse_ok "{\"a\":1}" (Keeper_json_parse.Object [("a", Keeper_json_parse.Int 1)]);
  parse_ok "{\"a\":1,\"b\":2}" (Keeper_json_parse.Object [("a", Keeper_json_parse.Int 1); ("b", Keeper_json_parse.Int 2)]);
  parse_ok "{\"nested\":{\"x\":true}}" (Keeper_json_parse.Object [("nested", Keeper_json_parse.Object [("x", Keeper_json_parse.Bool true)])])

let test_whitespace () =
  parse_ok "  null  " Keeper_json_parse.Null;
  parse_ok "\n\t 42 \r\n" (Keeper_json_parse.Int 42);
  parse_ok " [ 1 , 2 ] " (Keeper_json_parse.Array [Keeper_json_parse.Int 1; Keeper_json_parse.Int 2])

let test_errors () =
  parse_err "";
  parse_err "nul";
  parse_err "tru";
  parse_err "{";
  parse_err "[";
  parse_err "\"unterminated";
  parse_err "trailing garbage after";
  parse_err "{invalid}"

let test_roundtrip () =
  let cases = [
    "null";
    "true";
    "false";
    "42";
    "-1";
    "3.14";
    "\"hello\"";
    "[]";
    "[1,2,3]";
    "{}";
    "{\"a\":1}";
    "{\"a\":1,\"b\":2}";
  ] in
  List.iter (fun input ->
    match Keeper_json_parse.parse input with
    | Error msg -> Alcotest.failf "roundtrip: parse %S failed: %s" input msg
    | Ok v ->
      let output = Keeper_json_parse.to_string v in
      (* Re-parse the output to ensure it's valid *)
      match Keeper_json_parse.parse output with
      | Error msg -> Alcotest.failf "roundtrip: re-parse %S -> %s failed: %s" input output msg
      | Ok _ -> ()
  ) cases

let test_pretty_print () =
  let v = Keeper_json_parse.Object [
    "name", Keeper_json_parse.String "test";
    "value", Keeper_json_parse.Int 42;
    "nested", Keeper_json_parse.Object ["inner", Keeper_json_parse.Bool true];
  ] in
  let buf = Buffer.create 128 in
  let fmt = Format.formatter_of_buffer buf in
  Keeper_json_parse.pp fmt v;
  Format.pp_print_flush fmt ();
  let output = Buffer.contents buf in
  (* Should contain newlines and indentation *)
  if not (String.contains output '\n') then
    Alcotest.fail "pretty print should contain newlines";
  if not (String.contains output ' ') then
    Alcotest.fail "pretty print should contain spaces"

let tests = [
  "null", `Quick, test_null;
  "true", `Quick, test_true;
  "false", `Quick, test_false;
  "integer", `Quick, test_integer;
  "float", `Quick, test_float;
  "string", `Quick, test_string;
  "array", `Quick, test_array;
  "object", `Quick, test_object;
  "whitespace", `Quick, test_whitespace;
  "errors", `Quick, test_errors;
  "roundtrip", `Quick, test_roundtrip;
  "pretty_print", `Quick, test_pretty_print;
]

let () =
  Alcotest.run "Keeper_json_parse" [
    "parse", tests;
  ]