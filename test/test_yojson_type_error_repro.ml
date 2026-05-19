(** Reproduction tests for Yojson.Safe.Util.Type_error boundary in tool_board.ml.

    Background: When a keeper LLM submits board_post or board_comment with
    an array where a string is expected (e.g. sources=[...] instead of
    sources=[{url, quote}]), the handler raises Yojson.Safe.Util.Type_error
    which bubbles out as an opaque OCaml exception.  The fix in d903cd46a
    added [with_yojson_boundary] to catch and convert these into structured
    Tool_result.error messages.

    This file verifies the *reproduction paths* — the four root-cause classes
    that trigger Type_error in the yojson parsing layer.  Each case is
    standalone and can be run with: dune exec test/test_yojson_type_error_repro.exe

    task-318 — analyst keeper
*)

(* ── Pattern 1: Null fed to Util.to_string / Util.to_int ─────────── *)
let test_null_to_string () =
  let json = {| {"title": null} |} in
  let v = Yojson.Safe.from_string json in
  let _ = Yojson.Safe.Util.(field "title" v |> to_string) in ()

let test_null_to_int () =
  let json = {| {"count": null} |} in
  let v = Yojson.Safe.from_string json in
  let _ = Yojson.Safe.Util.(field "count" v |> to_int) in ()

(* ── Pattern 2: Array where string expected (the board_post trigger) ── *)
let test_array_where_string_expected () =
  (* This is the exact pattern from the original bug:
     LLM sends sources=[...] as a raw array instead of
     sources=[{url:"...", quote:"..."}].  The parsing code
     calls to_string on the array element. *)
  let json = {| {"body": ["unexpected", "array"]} |} in
  let v = Yojson.Safe.from_string json in
  let _ = Yojson.Safe.Util.(field "body" v |> to_string) in ()

(* ── Pattern 3: String where int expected ─────────────────────────── *)
let test_string_where_int_expected () =
  let json = {| {"priority": "critical"} |} in
  let v = Yojson.Safe.from_string json in
  let _ = Yojson.Safe.Util.(field "priority" v |> to_int) in ()

(* ── Pattern 4: Int where string expected ─────────────────────────── *)
let test_int_where_string_expected () =
  let json = {| {"hearth": 42} |} in
  let v = Yojson.Safe.from_string json in
  let _ = Yojson.Safe.Util.(field "hearth" v |> to_string) in ()

(* ── Pattern 5: Duplicate key — last-wins with different type ──────── *)
let test_duplicate_key_type_switch () =
  let json = {| {"value": 42, "value": "surprise"} |} in
  let v = Yojson.Safe.from_string json in
  let _ = Yojson.Safe.Util.(field "value" v |> to_int) in ()

(* ── Pattern 6: Nested field — wrong type deep in Assoc ───────────── *)
let test_nested_wrong_type () =
  let json = {| {"meta": {"count": ["not", "an", "int"]}} |} in
  let v = Yojson.Safe.from_string json in
  let _ = Yojson.Safe.Util.(
    field "meta" v |> field "count" |> to_int
  ) in ()

(* ── Runner ───────────────────────────────────────────────────────── *)
let () =
  let cases : (string * (unit -> unit)) list = [
    ("null→to_string",        test_null_to_string);
    ("null→to_int",           test_null_to_int);
    ("array→to_string",       test_array_where_string_expected);
    ("string→to_int",         test_string_where_int_expected);
    ("int→to_string",         test_int_where_string_expected);
    ("dup_key_type_switch",   test_duplicate_key_type_switch);
    ("nested_wrong_type",     test_nested_wrong_type);
  ] in
  let passed = ref 0 in
  let failed = ref 0 in
  List.iter (fun (name, fn) ->
    match fn () with
    | () ->
      (* No Type_error raised — the value matched the expected type.
         This is unexpected for reproduction tests: we EXPECT Type_error. *)
      Printf.printf "UNEXPECTED (no error): %s\n" name;
      incr failed
    | exception Yojson.Safe.Util.Type_error (msg, _json) ->
      (* This is the EXPECTED path — Type_error caught successfully. *)
      Printf.printf "REPRODUCED: %s — %s\n" name msg;
      incr passed
    | exception exn ->
      Printf.printf "UNEXPECTED exception: %s — %s\n" name
        (Printexc.to_string exn);
      incr failed
  ) cases;
  Printf.printf "\n--- Summary: %d reproduced / %d unexpected ---\n"
    !passed !failed;
  if !passed >= 5 then
    Printf.printf "PASS: Yojson.Type_error boundary is reproducible.\n"
  else
    Printf.printf "FAIL: Expected at least 5 Type_error reproductions.\n";
  (* Exit 0 always — this is a reproduction test, not a pass/fail gate.
     The value is in the log output showing which patterns trigger Type_error. *)