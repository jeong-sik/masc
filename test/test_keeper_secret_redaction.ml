module R = Masc.Keeper_secret_redaction

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
        ] )
    ]
