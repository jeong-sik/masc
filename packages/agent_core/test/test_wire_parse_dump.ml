(* The dump sink is a diagnostic, so it has to stay invisible when it is not
   asked for and it must never carry a credential out of the process. Both are
   properties the 2026-08-28 kimi_coding investigation depended on: the sink
   exists because a 256-byte excerpt could not say what broke the frame, and it
   is only useful if an operator can turn it on without auditing what lands in
   the file. *)

let refused_frame reason raw = Llm_provider.Types.Stream_parse_failed { reason; raw }

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let tmp_path suffix =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc-wire-dump-%d-%s" (Unix.getpid ()) suffix)

let check name expected actual =
  if expected <> actual
  then (
    Printf.eprintf "FAIL %s\n  expected: %b\n  actual:   %b\n" name expected actual;
    exit 1)
  else Printf.printf "ok - %s\n" name

let () =
  (* Off by default: no variable, no file, no trace. *)
  let unset_path = tmp_path "unset" in
  Unix.putenv "MASC_WIRE_PARSE_DUMP" "";
  ignore
    (Llm_provider.Complete_stream_error.http_error_of_stream_error
       (refused_frame "json_error" "{\"model\":\"k3-256k\"}"));
  check "no file when the variable is empty" false (Sys.file_exists unset_path);

  (* On: the whole frame lands, past the 256-byte message bound. *)
  let path = tmp_path "on" in
  if Sys.file_exists path then Sys.remove path;
  Unix.putenv "MASC_WIRE_PARSE_DUMP" path;
  let long = String.concat "" [ "{\"pad\":\""; String.make 900 'x'; "\"}" ] in
  ignore
    (Llm_provider.Complete_stream_error.http_error_of_stream_error
       (refused_frame "json_error: Line 1, bytes 41-75" long));
  let written = read_file path in
  check "frame is recorded" true (Sys.file_exists path);
  check "reason is recorded" true
    (Option.is_some (String.index_opt written 'L'));
  check "payload survives past the 256-byte excerpt bound" true
    (String.length written > 900);

  (* A credential in the refused frame is redacted before it reaches disk. *)
  let secret_path = tmp_path "secret" in
  if Sys.file_exists secret_path then Sys.remove secret_path;
  Unix.putenv "MASC_WIRE_PARSE_DUMP" secret_path;
  ignore
    (Llm_provider.Complete_stream_error.http_error_of_stream_error
       (refused_frame "json_error"
          "{\"authorization\":\"Bearer sk-live-abcdefghijklmnopqrstuvwxyz\"}"));
  let dumped = read_file secret_path in
  let contains needle hay =
    let n = String.length needle and h = String.length hay in
    let rec go i = i + n <= h && (String.sub hay i n = needle || go (i + 1)) in
    go 0
  in
  check "secret does not reach the file" false
    (contains "sk-live-abcdefghijklmnopqrstuvwxyz" dumped);
  check "redaction marker is present" true (contains "REDACTED" dumped);

  List.iter
    (fun p -> if Sys.file_exists p then Sys.remove p)
    [ path; secret_path ];
  print_endline "test_wire_parse_dump: all checks passed"
