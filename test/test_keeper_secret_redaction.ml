module R = Masc.Keeper_secret_redaction
module Execute = Masc.Keeper_tool_execute_runtime.For_testing

let with_env key value f =
  let prior = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f

let temp_dir () =
  let d = Filename.temp_file "keeper_secret_redaction_" "" in
  Unix.unlink d;
  Unix.mkdir d 0o755;
  d

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755)

let cleanup_dir dir =
  let rec rm path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path
    | _ -> Unix.unlink path
    | exception Unix.Unix_error _ -> ()
  in
  try rm dir with
  | _ -> ()

let write_file path content =
  ensure_dir (Filename.dirname path);
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out oc) @@ fun () ->
  output_string oc content

let secret_root_default ~base ~keeper_name =
  Filename.concat
    (Filename.concat (Filename.concat base Common.masc_dirname) "secrets")
    (Workspace_utils.safe_filename keeper_name)

let base_secret_root_default ~base = secret_root_default ~base ~keeper_name:"base"

let not_contains label haystack needle =
  Alcotest.(check bool) label false (String_util.contains_substring haystack needle)

let contains label haystack needle =
  Alcotest.(check bool) label true (String_util.contains_substring haystack needle)

let test_snapshot_redacts_env_and_file_values () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let keeper_name = "minjae" in
  let root = secret_root_default ~base ~keeper_name in
  let env_secret = "keeper.secret!" in
  let file_secret = "file.secret!" in
  write_file (Filename.concat (Filename.concat root "env") "GH_TOKEN")
    (env_secret ^ "\n");
  write_file
    (Filename.concat (Filename.concat root "files") "home/keeper/.ssh/id")
    ("header\n" ^ file_secret ^ "\nfooter");
  let redaction = R.snapshot ~base_path:base ~keeper_name in
  let redacted =
    R.redact_text redaction
      ("env=" ^ env_secret ^ " file=" ^ file_secret)
  in
  not_contains "env exact value hidden" redacted env_secret;
  not_contains "file exact value hidden" redacted file_secret;
  contains "redaction marker present" redacted "[REDACTED]"

let test_short_values_are_not_exact_redacted () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let keeper_name = "shorty" in
  let root = secret_root_default ~base ~keeper_name in
  write_file (Filename.concat (Filename.concat root "env") "PIN") "1234567";
  let redaction = R.snapshot ~base_path:base ~keeper_name in
  Alcotest.(check string) "short value preserved"
    "pin=1234567"
    (R.redact_text redaction "pin=1234567")

let test_snapshot_redacts_base_secret_values () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let base_root = base_secret_root_default ~base in
  let base_secret = "base.secret!" in
  write_file (Filename.concat (Filename.concat base_root "env") "GH_TOKEN")
    (base_secret ^ "\n");
  let redaction = R.snapshot ~base_path:base ~keeper_name:"idealist" in
  let redacted = R.redact_text redaction ("token=" ^ base_secret) in
  not_contains "base env exact value hidden" redacted base_secret;
  contains "redaction marker present" redacted "[REDACTED]"

let test_json_redaction_preserves_shape () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let keeper_name = "json" in
  let root = secret_root_default ~base ~keeper_name in
  let env_secret = "json.secret!" in
  write_file (Filename.concat (Filename.concat root "env") "GH_TOKEN")
    env_secret;
  let redaction = R.snapshot ~base_path:base ~keeper_name in
  let json =
    `Assoc
      [ ("content", `String ("token " ^ env_secret));
        ("password", `String "plain-password");
        ("count", `Int 1) ]
  in
  let redacted = R.redact_json redaction json in
  let raw = Yojson.Safe.to_string redacted in
  not_contains "exact value hidden in json" raw env_secret;
  not_contains "sensitive key value hidden" raw "plain-password";
  contains "count preserved" raw {|"count":1|}

let test_execute_output_redaction_uses_keeper_snapshot () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let keeper_name = "execute" in
  let root = secret_root_default ~base ~keeper_name in
  let stdout_secret = "stdout.secret!" in
  let stderr_secret = "stderr.secret!" in
  write_file (Filename.concat (Filename.concat root "env") "STDOUT_TOKEN")
    stdout_secret;
  write_file (Filename.concat (Filename.concat root "env") "STDERR_TOKEN")
    stderr_secret;
  let stdout, stderr, output =
    Execute.redact_execute_output
      ~base_path:base
      ~keeper_name
      ~stdout:("out=" ^ stdout_secret)
      ~stderr:("err=" ^ stderr_secret)
  in
  not_contains "stdout exact value hidden" stdout stdout_secret;
  not_contains "stderr exact value hidden" stderr stderr_secret;
  not_contains "combined output hides stdout secret" output stdout_secret;
  not_contains "combined output hides stderr secret" output stderr_secret;
  contains "stdout marker present" stdout "[REDACTED]";
  contains "stderr marker present" stderr "[REDACTED]"

let test_stream_redaction_reassembles_split_secret () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let keeper_name = "stream" in
  let root = secret_root_default ~base ~keeper_name in
  let secret = "stream.secret!" in
  write_file (Filename.concat (Filename.concat root "env") "STREAM_TOKEN") secret;
  let redaction = R.snapshot ~base_path:base ~keeper_name in
  let state = R.create_stream_state () in
  let first = R.redact_stream_chunk redaction state "prefix stream." in
  Alcotest.(check string) "unterminated line is held" "" first;
  let second = R.redact_stream_chunk redaction state "secret! suffix\nnext\n" in
  not_contains "split secret hidden" second secret;
  contains "split secret marker present" second "[REDACTED]";
  contains "complete trailing line emitted" second "next\n";
  Alcotest.(check string)
    "finish after newline has no held bytes"
    ""
    (R.redact_stream_finish redaction state)

let test_stream_redaction_finish_redacts_held_tail () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let keeper_name = "stream-tail" in
  let root = secret_root_default ~base ~keeper_name in
  let secret = "tail.secret!" in
  write_file (Filename.concat (Filename.concat root "env") "TAIL_TOKEN") secret;
  let redaction = R.snapshot ~base_path:base ~keeper_name in
  let state = R.create_stream_state () in
  let emitted = R.redact_stream_chunk redaction state ("tail=" ^ secret) in
  Alcotest.(check string) "unterminated tail is held" "" emitted;
  let flushed = R.redact_stream_finish redaction state in
  not_contains "held tail secret hidden" flushed secret;
  contains "held tail marker present" flushed "[REDACTED]";
  Alcotest.(check string)
    "finish clears held bytes"
    ""
    (R.redact_stream_finish redaction state)

let () =
  Alcotest.run
    "keeper secret redaction"
    [ ( "snapshot",
        [ Alcotest.test_case "redacts env and file exact values" `Quick
            test_snapshot_redacts_env_and_file_values;
          Alcotest.test_case "does not exact-redact short values" `Quick
            test_short_values_are_not_exact_redacted;
          Alcotest.test_case "redacts base secret values" `Quick
            test_snapshot_redacts_base_secret_values;
          Alcotest.test_case "redacts json while preserving shape" `Quick
            test_json_redaction_preserves_shape;
          Alcotest.test_case "redacts Execute stdout stderr and combined output" `Quick
            test_execute_output_redaction_uses_keeper_snapshot;
          Alcotest.test_case "reassembles split stream secrets" `Quick
            test_stream_redaction_reassembles_split_secret;
          Alcotest.test_case "redacts held stream tail on finish" `Quick
            test_stream_redaction_finish_redacts_held_tail;
        ] )
    ]
