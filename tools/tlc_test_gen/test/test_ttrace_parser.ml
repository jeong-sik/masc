open Tlc_test_gen.Ttrace_parser

let fixture name =
  Filename.concat (Filename.concat (Sys.getcwd ()) "fixtures") name

let assert_eq ~ctx expected actual =
  if expected <> actual then begin
    Printf.eprintf "FAIL [%s]\n  expected: %s\n  actual:   %s\n"
      ctx expected actual;
    exit 1
  end

let value_to_str = function
  | V_int n    -> Printf.sprintf "int(%d)" n
  | V_string s -> Printf.sprintf "string(%s)" s
  | V_bool b   -> Printf.sprintf "bool(%b)" b

let () =
  match parse_file (fixture "sample_inv.tla") with
  | Error msg ->
      Printf.eprintf "FAIL [parse_file]: %s\n" msg; exit 1
  | Ok st ->
      assert_eq ~ctx:"module name"
        "SampleInv_TTrace_1700000000" st.spec_module;
      let lookup k =
        try List.assoc k st.bindings
        with Not_found ->
          Printf.eprintf "FAIL [missing binding]: %s\n" k; exit 1
      in
      assert_eq ~ctx:"tool_calls_made"  "int(1)"
        (value_to_str (lookup "tool_calls_made"));
      assert_eq ~ctx:"turn_phase"       "string(failed)"
        (value_to_str (lookup "turn_phase"));
      assert_eq ~ctx:"provider_error"   "string(internal)"
        (value_to_str (lookup "provider_error"));
      assert_eq ~ctx:"mutating_committed" "int(1)"
        (value_to_str (lookup "mutating_committed"));
      assert_eq ~ctx:"retry_count"      "int(0)"
        (value_to_str (lookup "retry_count"));
      assert_eq ~ctx:"retry_performed"  "bool(false)"
        (value_to_str (lookup "retry_performed"));
      let emitted = Tlc_test_gen.Ocaml_emit.emit_let_test st in
      let must_contain s =
        let n = String.length s in
        let m = String.length emitted in
        let rec scan i =
          if i + n > m then begin
            Printf.eprintf "FAIL [emit missing fragment]: %S\n" s; exit 1
          end else if String.sub emitted i n = s then ()
          else scan (i + 1)
        in
        scan 0
      in
      must_contain "spec_violation_SampleInv_TTrace_1700000000";
      must_contain "\"turn_phase\", \"failed\"";
      must_contain "\"retry_performed\", false";
      print_endline "PASS"
