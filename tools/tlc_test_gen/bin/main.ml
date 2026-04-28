let usage () =
  prerr_endline "usage:";
  prerr_endline "  tlc_test_gen <path-to-TTrace.tla>";
  prerr_endline "  tlc_test_gen --batch <out-dir> <path-to-TTrace.tla>...";
  prerr_endline "  tlc_test_gen --runner <path-to-TTrace.tla>";
  exit 2

let render state =
  let buf = Buffer.create 1024 in
  Buffer.add_string buf (Tlc_test_gen.Ocaml_emit.emit_let_test state);
  Buffer.add_char   buf '\n';
  Buffer.add_string buf (Tlc_test_gen.Ocaml_emit.emit_trace state);
  Buffer.add_char   buf '\n';
  Buffer.add_string buf
    (Tlc_test_gen.Ocaml_emit.emit_let_test_reachability state);
  Buffer.contents buf

let parse path =
  match Tlc_test_gen.Ttrace_parser.parse_file path with
  | Error msg ->
      Printf.eprintf "tlc_test_gen: %s: %s\n" path msg;
      None
  | Ok state -> Some state

(* mkdir -p without depending on the [Unix] library — relies on stdlib only.
   Returns true if the directory exists (or was created) after the call. *)
let mkdir_p dir =
  if Sys.file_exists dir then Sys.is_directory dir
  else
    let cmd = Printf.sprintf "mkdir -p %s" (Filename.quote dir) in
    Sys.command cmd = 0 && Sys.file_exists dir && Sys.is_directory dir

let write_to dir state out =
  if not (mkdir_p dir) then begin
    Printf.eprintf "tlc_test_gen: cannot create out-dir: %s\n" dir;
    false
  end else
    let fname =
      Filename.concat dir
        (state.Tlc_test_gen.Ttrace_parser.spec_module ^ ".ml")
    in
    let oc = open_out fname in
    output_string oc out;
    close_out oc;
    Printf.printf "wrote %s\n" fname;
    true

let run_one path =
  match parse path with
  | None -> false
  | Some state ->
      print_string (render state);
      true

let run_batch out_dir paths =
  if paths = [] then begin usage () end;
  let any_error = ref false in
  List.iter
    (fun path ->
      match parse path with
      | None -> any_error := true
      | Some state ->
          let out = render state in
          if not (write_to out_dir state out) then any_error := true)
    paths;
  not !any_error

let run_runner path =
  match parse path with
  | None -> false
  | Some state ->
      print_string (Tlc_test_gen.Ocaml_emit.emit_test_runner state);
      true

let () =
  match Array.to_list Sys.argv with
  | _ :: "--batch" :: out_dir :: paths ->
      if run_batch out_dir paths then () else exit 1
  | _ :: "--runner" :: path :: _ ->
      if run_runner path then () else exit 1
  | _ :: ("-h" | "--help") :: _ -> usage ()
  | _ :: path :: _ ->
      if run_one path then () else exit 1
  | _ -> usage ()
