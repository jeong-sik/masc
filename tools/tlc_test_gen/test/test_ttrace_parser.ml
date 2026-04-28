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
  | V_raw r    -> Printf.sprintf "raw(%s)" r

let must_contain ~ctx haystack needle =
  let n = String.length needle in
  let m = String.length haystack in
  let rec scan i =
    if i + n > m then begin
      Printf.eprintf "FAIL [%s missing fragment]: %S\n" ctx needle;
      exit 1
    end else if String.sub haystack i n = needle then ()
    else scan (i + 1)
  in
  scan 0

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

      (* emit_let_test still produces the legacy negative-test scaffold. *)
      let emitted = Tlc_test_gen.Ocaml_emit.emit_let_test st in
      must_contain ~ctx:"emit_let_test"
        emitted "spec_violation_SampleInv_TTrace_1700000000";
      must_contain ~ctx:"emit_let_test"
        emitted "\"turn_phase\", \"failed\"";
      must_contain ~ctx:"emit_let_test"
        emitted "\"retry_performed\", false";

      (* New: _TETrace step sequence is parsed. *)
      assert_eq ~ctx:"step count"
        "3" (string_of_int (List.length st.steps));
      let step i = List.nth st.steps i in
      let step_field i name =
        try List.assoc name (step i)
        with Not_found ->
          Printf.eprintf "FAIL [missing step %d field]: %s\n" i name;
          exit 1
      in
      assert_eq ~ctx:"step 0 turn_phase"
        "string(init)" (value_to_str (step_field 0 "turn_phase"));
      assert_eq ~ctx:"step 0 retry_performed"
        "bool(false)" (value_to_str (step_field 0 "retry_performed"));
      assert_eq ~ctx:"step 1 turn_phase"
        "string(running)" (value_to_str (step_field 1 "turn_phase"));
      assert_eq ~ctx:"step 2 turn_phase"
        "string(failed)" (value_to_str (step_field 2 "turn_phase"));
      assert_eq ~ctx:"step 2 provider_error"
        "string(internal)" (value_to_str (step_field 2 "provider_error"));
      assert_eq ~ctx:"step 2 tool_calls_made"
        "int(1)" (value_to_str (step_field 2 "tool_calls_made"));

      (* emit_trace serialises steps as a typed assoc list. *)
      let trace_emit = Tlc_test_gen.Ocaml_emit.emit_trace st in
      must_contain ~ctx:"emit_trace"
        trace_emit "let trace_SampleInv_TTrace_1700000000";
      must_contain ~ctx:"emit_trace"
        trace_emit "Tlc_test_gen.Ttrace_parser.step list";
      must_contain ~ctx:"emit_trace"
        trace_emit "Tlc_test_gen.Ttrace_parser.V_string \"init\"";
      must_contain ~ctx:"emit_trace"
        trace_emit "Tlc_test_gen.Ttrace_parser.V_string \"failed\"";
      must_contain ~ctx:"emit_trace"
        trace_emit "Tlc_test_gen.Ttrace_parser.V_int 0";
      must_contain ~ctx:"emit_trace"
        trace_emit "Tlc_test_gen.Ttrace_parser.V_bool false";

      (* emit_let_test_reachability binds the trace and asserts terminal. *)
      let reach = Tlc_test_gen.Ocaml_emit.emit_let_test_reachability st in
      must_contain ~ctx:"emit_reachability"
        reach "spec_violation_SampleInv_TTrace_1700000000_reaches_terminal";
      must_contain ~ctx:"emit_reachability"
        reach "let trace = trace_SampleInv_TTrace_1700000000";
      must_contain ~ctx:"emit_reachability"
        reach "List.nth_opt trace";
      must_contain ~ctx:"emit_reachability"
        reach "List.assoc_opt \"turn_phase\" last = Some (Tlc_test_gen.Ttrace_parser.V_string \"failed\")";

      (* ---- Nested record fixture (Cycle 21 follow-up) ---- *)
      (match parse_file (fixture "nested_record.tla") with
       | Error msg ->
           Printf.eprintf "FAIL [nested parse_file]: %s\n" msg; exit 1
       | Ok nst ->
           assert_eq ~ctx:"nested module name"
             "NestedSample_TTrace_1700000001" nst.spec_module;

           (* The _inv body uses simple bindings; record-typed bindings fall
              outside the regex narrower so should not pollute. *)
           assert_eq ~ctx:"nested binding count"
             "2" (string_of_int (List.length nst.bindings));

           (* Step sequence has 3 records; each contains a nested record
              [host |-> ..., port |-> ...] preserved as V_raw. *)
           assert_eq ~ctx:"nested step count"
             "3" (string_of_int (List.length nst.steps));
           let nstep i name =
             try List.assoc name (List.nth nst.steps i)
             with Not_found ->
               Printf.eprintf "FAIL [nested step %d field]: %s\n" i name;
               exit 1
           in
           assert_eq ~ctx:"nested step 0 active"
             "bool(false)" (value_to_str (nstep 0 "active"));
           assert_eq ~ctx:"nested step 0 retries"
             "int(0)" (value_to_str (nstep 0 "retries"));

           (* Critical: nested record value is preserved as V_raw with inner
              brackets and the embedded "init" string verbatim. *)
           (match nstep 0 "config" with
            | V_raw r ->
                let needle = "host |-> \"init\"" in
                let len_r = String.length r in
                let len_n = String.length needle in
                let rec scan i =
                  if i + len_n > len_r then begin
                    Printf.eprintf
                      "FAIL [nested step 0 config V_raw missing %S, got %S]\n"
                      needle r;
                    exit 1
                  end else if String.sub r i len_n = needle then ()
                  else scan (i + 1)
                in
                scan 0
            | other ->
                Printf.eprintf
                  "FAIL [nested step 0 config not V_raw]: %s\n"
                  (value_to_str other);
                exit 1);

           assert_eq ~ctx:"nested step 2 retries"
             "int(3)" (value_to_str (nstep 2 "retries"));

           (* Emitter quotes the V_raw payload so the embedded "init" stays
              valid OCaml after generation. *)
           let nemit = Tlc_test_gen.Ocaml_emit.emit_trace nst in
           must_contain ~ctx:"nested emit_trace V_raw"
             nemit "Tlc_test_gen.Ttrace_parser.V_raw";
           must_contain ~ctx:"nested emit_trace escaped init"
             nemit "host |-> \\\"init\\\"");

      print_endline "PASS"
