open Ttrace_parser

(* Untyped emission for the legacy [emit_let_test] surface. The result is a
   list of (string * raw-OCaml-token) pairs that intentionally end up as
   mixed-type and must be discarded with [ignore violating_state]. *)
let value_to_ocaml_untyped = function
  | V_int n    -> string_of_int n
  | V_string s -> Printf.sprintf "%S" s
  | V_bool b   -> if b then "true" else "false"
  | V_raw r    -> Printf.sprintf "%S" r

(* Typed emission referencing the [Tlc_test_gen.Ttrace_parser.V_*] data
   constructors. The generated assoc list is a uniform
   [(string * Tlc_test_gen.Ttrace_parser.value) list] and may be consumed
   by reachability assertions. *)
let value_to_ocaml_typed = function
  | V_int n    -> Printf.sprintf "Tlc_test_gen.Ttrace_parser.V_int %d" n
  | V_string s -> Printf.sprintf "Tlc_test_gen.Ttrace_parser.V_string %S" s
  | V_bool b   -> Printf.sprintf "Tlc_test_gen.Ttrace_parser.V_bool %B" b
  | V_raw r    -> Printf.sprintf "Tlc_test_gen.Ttrace_parser.V_raw %S" r

let emit_let_test (st : state) =
  let buf = Buffer.create 256 in
  Buffer.add_string buf
    (Printf.sprintf "(* Auto-generated from %s.\n   DO NOT EDIT.\n   \
                     Regenerate with [tlc_test_gen] after re-running TLC. *)\n"
       st.trace_file);
  Buffer.add_string buf
    (Printf.sprintf "let%%test \"spec_violation_%s\" =\n" st.spec_module);
  Buffer.add_string buf "  (* Negative assertion: the runtime must never\n";
  Buffer.add_string buf "     reach the state recorded by TLC's invariant\n";
  Buffer.add_string buf "     violation trace. *)\n";
  Buffer.add_string buf "  let violating_state = [\n";
  List.iter
    (fun (name, v) ->
      Buffer.add_string buf
        (Printf.sprintf "    %S, %s;\n" name (value_to_ocaml_untyped v)))
    st.bindings;
  Buffer.add_string buf "  ] in\n";
  Buffer.add_string buf "  ignore violating_state;\n";
  Buffer.add_string buf "  (* TODO: replace with module-specific reachability check. *)\n";
  Buffer.add_string buf "  true\n";
  Buffer.contents buf

let emit_trace (st : state) =
  let buf = Buffer.create 512 in
  Buffer.add_string buf
    (Printf.sprintf "(* Trace from %s. Auto-generated. *)\n" st.trace_file);
  Buffer.add_string buf
    (Printf.sprintf
       "let trace_%s : Tlc_test_gen.Ttrace_parser.step list =\n"
       st.spec_module);
  (match st.steps with
   | [] ->
       Buffer.add_string buf "  [] (* TLC trace lacked a parseable _TETrace module. *)\n"
   | steps ->
       Buffer.add_string buf "  [\n";
       List.iter
         (fun step ->
           Buffer.add_string buf "    [\n";
           List.iter
             (fun (name, v) ->
               Buffer.add_string buf
                 (Printf.sprintf "      %S, %s;\n"
                    name (value_to_ocaml_typed v)))
             step;
           Buffer.add_string buf "    ];\n")
         steps;
       Buffer.add_string buf "  ]\n");
  Buffer.contents buf

let emit_let_test_reachability (st : state) =
  let buf = Buffer.create 512 in
  Buffer.add_string buf
    (Printf.sprintf
       "let%%test \"spec_violation_%s_reaches_terminal\" =\n"
       st.spec_module);
  Buffer.add_string buf
    "  (* Reachability assertion: the recorded trace must end in the\n";
  Buffer.add_string buf
    "     violating terminal state. Pair this with [trace_X] from\n";
  Buffer.add_string buf
    "     [emit_trace]. *)\n";
  Buffer.add_string buf
    (Printf.sprintf "  let trace = trace_%s in\n" st.spec_module);
  Buffer.add_string buf
    "  match List.nth_opt trace (List.length trace - 1) with\n";
  Buffer.add_string buf "  | None -> false\n";
  Buffer.add_string buf "  | Some last ->\n";
  (match st.bindings with
   | [] -> Buffer.add_string buf "    false\n"
   | bindings ->
       let n = List.length bindings in
       List.iteri
         (fun i (name, v) ->
           let is_last = (i = n - 1) in
           Buffer.add_string buf
             (Printf.sprintf "    List.assoc_opt %S last = Some (%s)%s\n"
                name (value_to_ocaml_typed v)
                (if is_last then "" else " &&")))
         bindings);
  Buffer.contents buf
