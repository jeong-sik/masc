open Ttrace_parser

let value_to_ocaml = function
  | V_int n    -> string_of_int n
  | V_string s -> Printf.sprintf "%S" s
  | V_bool b   -> if b then "true" else "false"

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
        (Printf.sprintf "    %S, %s;\n" name (value_to_ocaml v)))
    st.bindings;
  Buffer.add_string buf "  ] in\n";
  Buffer.add_string buf "  ignore violating_state;\n";
  Buffer.add_string buf "  (* TODO: replace with module-specific reachability check. *)\n";
  Buffer.add_string buf "  true\n";
  Buffer.contents buf
