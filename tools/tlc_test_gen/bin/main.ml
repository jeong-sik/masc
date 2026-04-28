let usage () =
  prerr_endline "usage: tlc_test_gen <path-to-TTrace.tla>";
  exit 2

let () =
  match Array.to_list Sys.argv with
  | _ :: path :: _ ->
      (match Tlc_test_gen.Ttrace_parser.parse_file path with
       | Error msg ->
           prerr_endline ("tlc_test_gen: " ^ msg);
           exit 1
       | Ok state ->
           print_string (Tlc_test_gen.Ocaml_emit.emit_let_test state);
           print_newline ();
           print_string (Tlc_test_gen.Ocaml_emit.emit_trace state);
           print_newline ();
           print_string (Tlc_test_gen.Ocaml_emit.emit_let_test_reachability state))
  | _ -> usage ()
