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
  let keeper_name = "acme-sandbox" in
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

(* The snapshot is memoised per domain on the identity of its source files.
   Unchanged files serve the same compiled patterns; a changed file rebuilds. *)
let test_snapshot_is_reused_until_a_source_changes () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let keeper_name = "memo-keeper" in
  let root = secret_root_default ~base ~keeper_name in
  let env_file = Filename.concat (Filename.concat root "env") "GH_TOKEN" in
  let first_secret = "first.secret.value" in
  let second_secret = "second.secret.value" in
  write_file env_file (first_secret ^ "\n");
  let first = R.snapshot ~base_path:base ~keeper_name in
  let again = R.snapshot ~base_path:base ~keeper_name in
  Alcotest.(check bool) "unchanged sources share the compiled patterns" true
    (R.For_testing.shares_compiled_patterns first again);
  (* A different request key is a different entry even over the same files. *)
  let scalars_off =
    R.snapshot_with_additional_secret_files
      ~redact_identity_scalars:false
      ~additional_secret_files:[]
      ~base_path:base
      ~keeper_name
  in
  Alcotest.(check bool) "another request key does not share" false
    (R.For_testing.shares_compiled_patterns first scalars_off);
  (* Appending a value changes the file's size, so the next call rebuilds. *)
  write_file env_file (first_secret ^ "\n" ^ second_secret ^ "\n");
  let rebuilt = R.snapshot ~base_path:base ~keeper_name in
  Alcotest.(check bool) "a changed source rebuilds the snapshot" false
    (R.For_testing.shares_compiled_patterns first rebuilt);
  let redacted = R.redact_text rebuilt ("a=" ^ first_secret ^ " b=" ^ second_secret) in
  not_contains "old value still hidden" redacted first_secret;
  not_contains "new value hidden after rebuild" redacted second_secret;
  (* The stale snapshot keeps redacting what it knew; it never learns more. *)
  contains "stale snapshot does not know the new value"
    (R.redact_text first ("b=" ^ second_secret)) second_secret

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
  let redaction = R.snapshot ~base_path:base ~keeper_name:"fixture-keeper" in
  let redacted = R.redact_text redaction ("token=" ^ base_secret) in
  not_contains "base env exact value hidden" redacted base_secret;
  contains "redaction marker present" redacted "[REDACTED]"

let test_snapshot_redacts_remote_token_without_projecting_it () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let keeper_name = "remote-token" in
  let token = "remote.github.token.value" in
  write_file (R.ssh_remote_token_file ~base_path:base ~keeper_name) (token ^ "\n");
  let redaction = R.snapshot ~base_path:base ~keeper_name in
  let redacted = R.redact_text redaction ("token=" ^ token) in
  not_contains "remote token hidden" redacted token;
  contains "remote token marker present" redacted "[REDACTED]";
  match
    Masc.Keeper_secret_projection.local_env_for_keeper
      ~host_env:[| "PATH=/usr/bin" |] ~base_path:base ~keeper_name ()
  with
  | Error error -> Alcotest.fail error
  | Ok None -> Alcotest.fail "scrubbed local env was unexpectedly absent"
  | Ok (Some env) ->
    Alcotest.(check bool) "remote token is not locally projected" false
      (Array.exists (fun entry -> String_util.contains_substring entry token) env)

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

(* A secret can be the key, not only the value: a header name, or a parameter
   a tool used as a dict key. Three boundaries call [redact_json] and only one
   used to also redact keys, so the other two emitted the secret (#22941). *)
let test_json_redaction_covers_object_keys () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let keeper_name = "json-keys" in
  let root = secret_root_default ~base ~keeper_name in
  let env_secret = "key.secret!" in
  write_file (Filename.concat (Filename.concat root "env") "GH_TOKEN") env_secret;
  let redaction = R.snapshot ~base_path:base ~keeper_name in
  let json =
    `Assoc
      [ (env_secret, `String "value under a secret key")
      ; ( "nested"
        , `Assoc [ ("headers", `Assoc [ (env_secret, `String "1") ]) ] )
      ; ("list", `List [ `Assoc [ (env_secret, `Int 2) ] ])
      ; ("kept", `String "not a secret")
      ]
  in
  let raw = Yojson.Safe.to_string (R.redact_json redaction json) in
  not_contains "top-level key redacted" raw env_secret;
  contains "the structure survives" raw {|"kept":"not a secret"|};
  contains "the value under the redacted key survives" raw "value under a secret key";
  contains "the nested int survives" raw "2"
;;

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

let test_stream_redaction_hides_secret_across_chunks () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let keeper_name = "stream" in
  let root = secret_root_default ~base ~keeper_name in
  let secret = "chunk.boundary.secret" in
  write_file (Filename.concat (Filename.concat root "env") "GH_TOKEN") secret;
  let state =
    R.snapshot ~base_path:base ~keeper_name |> R.create_stream_state
  in
  let first = R.redact_stream_chunk state "prefix chunk.boundary." in
  let second = R.redact_stream_chunk state "secret suffix\nnext" in
  let trailing = R.redact_stream_finish state in
  Alcotest.(check string) "unterminated line is withheld" "" first;
  not_contains "joined secret is hidden" second secret;
  contains "joined line has marker" second "[REDACTED]";
  Alcotest.(check string) "final unterminated line is emitted" "next" trailing

let test_execute_output_redacts_github_hosts_scalar () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let token = "classic-token-without-structural-prefix" in
  let hosts = Filename.concat base "hosts.yml" in
  write_file hosts
    ("github.com:\n  user: keeper-user\n  oauth_token: " ^ token ^ "\n");
  let stdout, stderr, output =
    Execute.redact_execute_output_with_additional_secret_files
      ~additional_secret_files:[ hosts ]
      ~base_path:base
      ~keeper_name:"github-output"
      ~stdout:("token=" ^ token)
      ~stderr:""
  in
  not_contains "GitHub token hidden from stdout" stdout token;
  not_contains "GitHub token hidden from combined output" output token;
  Alcotest.(check string) "empty stderr remains empty" "" stderr;
  contains "GitHub token redaction marker present" stdout "[REDACTED]"

let test_stream_redacts_github_hosts_scalar_across_chunks () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let token = "github-token-split-across-chunks" in
  let hosts = Filename.concat base "hosts.yml" in
  write_file hosts ("github.com:\n  oauth_token: " ^ token ^ "\n");
  let state =
    R.snapshot_with_additional_secret_files
      ~redact_identity_scalars:true
      ~additional_secret_files:[ hosts ]
      ~base_path:base
      ~keeper_name:"github-stream"
    |> R.create_stream_state
  in
  let first = R.redact_stream_chunk state "github-token-split-" in
  let second = R.redact_stream_chunk state "across-chunks\n" in
  Alcotest.(check string) "partial token is withheld" "" first;
  not_contains "streamed GitHub token is hidden" second token;
  contains "streamed GitHub token marker present" second "[REDACTED]"

(* 2026-08-29: scalar mining masked a GitHub account name (public in every
   repo URL) as [REDACTED] throughout chat text. The identity half is now a
   switch; the credential half never turns off. *)
let test_identity_scalar_toggle_leaves_credentials_masked () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let account = "anyang-keepers" in
  let token = "gho_toggle-still-masked-token" in
  let hosts = Filename.concat base "hosts.yml" in
  write_file hosts
    ("github.com:\n  user: " ^ account ^ "\n  oauth_token: " ^ token ^ "\n");
  let redact ~identity text =
    R.redact_text
      (R.snapshot_with_additional_secret_files
         ~redact_identity_scalars:identity
         ~additional_secret_files:[ hosts ]
         ~base_path:base
         ~keeper_name:"github-toggle")
      text
  in
  let url = "https://github.com/" ^ account ^ "/practice/branches" in
  contains "identity on masks the account name"
    (redact ~identity:true url) "[REDACTED]";
  Alcotest.(check string)
    "identity off shows the account name"
    url
    (redact ~identity:false url);
  not_contains "the token stays masked with identity on"
    (redact ~identity:true ("token=" ^ token)) token;
  not_contains "the token stays masked with identity off"
    (redact ~identity:false ("token=" ^ token)) token

let test_credential_shaped_keys_always_mine_their_scalar () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let secret_value = "a-very-opaque-credential" in
  let hosts = Filename.concat base "creds.yml" in
  write_file hosts
    ("service:\n  api_token: " ^ secret_value ^ "\n  user: plain-login\n");
  let redaction =
    R.snapshot_with_additional_secret_files
      ~redact_identity_scalars:false
      ~additional_secret_files:[ hosts ]
      ~base_path:base
      ~keeper_name:"github-toggle"
  in
  not_contains "a credential-shaped key mines even with identity off"
    (R.redact_text redaction ("value=" ^ secret_value))
    secret_value

let test_stream_emits_bounded_unterminated_output () =
  let input = String.make 200_000 'x' in
  let state = R.create_stream_state R.empty in
  let emitted = R.redact_stream_chunk state input in
  let trailing = R.redact_stream_finish state in
  Alcotest.(check bool) "long line streams before finish" true
    (String.length emitted > 0);
  Alcotest.(check bool) "only a bounded suffix remains" true
    (String.length trailing < 10_000);
  Alcotest.(check string) "streaming preserves ordinary bytes" input
    (emitted ^ trailing)

let test_stream_emits_carriage_return_progress () =
  let state = R.create_stream_state R.empty in
  let emitted = R.redact_stream_chunk state "step 1\rstep 2\rpartial" in
  Alcotest.(check string) "carriage-return records stream immediately"
    "step 1\rstep 2\r"
    emitted;
  Alcotest.(check string) "partial progress remains for finish" "partial"
    (R.redact_stream_finish state)

let test_stream_redacts_secret_crossing_bounded_flush () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let keeper_name = "bounded-crossing" in
  let root = secret_root_default ~base ~keeper_name in
  let secret = "bounded.flush.secret.value" in
  write_file (Filename.concat (Filename.concat root "env") "TOKEN") secret;
  let state = R.snapshot ~base_path:base ~keeper_name |> R.create_stream_state in
  let body = String.make 4_090 'x' ^ secret ^ String.make 5_000 'y' in
  let first = R.redact_stream_chunk state body in
  let emitted = first ^ R.redact_stream_chunk state "\n" in
  let trailing = R.redact_stream_finish state in
  Alcotest.(check bool) "bounded line emits before its terminator" true
    (String.length first > 0);
  not_contains "secret crossing the bounded cut is hidden" (emitted ^ trailing) secret;
  contains "crossing secret leaves a marker" (emitted ^ trailing) "[REDACTED]"

let test_stream_bounds_overlapping_repeated_secret () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let keeper_name = "bounded-overlap" in
  let root = secret_root_default ~base ~keeper_name in
  let secret = "aaaaaaaa" in
  write_file (Filename.concat (Filename.concat root "env") "TOKEN") secret;
  let state = R.snapshot ~base_path:base ~keeper_name |> R.create_stream_state in
  let emitted = R.redact_stream_chunk state (String.make 200_000 'a') in
  let trailing = R.redact_stream_finish state in
  Alcotest.(check bool) "overlapping secret stream emits before finish" true
    (String.length emitted > 0);
  Alcotest.(check bool) "overlapping secret leaves a bounded suffix" true
    (String.length trailing < 10_000);
  not_contains "repeated secret bytes do not escape" (emitted ^ trailing) secret;
  contains "repeated secret produces markers" emitted "[REDACTED]"

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
          Alcotest.test_case
            "redacts remote token without projecting it"
            `Quick
            test_snapshot_redacts_remote_token_without_projecting_it;
          Alcotest.test_case "redacts json while preserving shape" `Quick
            test_json_redaction_preserves_shape;
          Alcotest.test_case "reuses the snapshot until a source changes" `Quick
            test_snapshot_is_reused_until_a_source_changes;
          Alcotest.test_case "redacts json object keys" `Quick
            test_json_redaction_covers_object_keys;
          Alcotest.test_case "redacts Execute stdout stderr and combined output" `Quick
            test_execute_output_redaction_uses_keeper_snapshot;
          Alcotest.test_case "redacts a secret split across chunks" `Quick
            test_stream_redaction_hides_secret_across_chunks;
          Alcotest.test_case "redacts GitHub hosts scalar from Execute output" `Quick
            test_execute_output_redacts_github_hosts_scalar;
          Alcotest.test_case "redacts streamed GitHub scalar across chunks" `Quick
            test_stream_redacts_github_hosts_scalar_across_chunks;
          Alcotest.test_case "identity toggle leaves credentials masked" `Quick
            test_identity_scalar_toggle_leaves_credentials_masked;
          Alcotest.test_case "credential-shaped keys always mine their scalar" `Quick
            test_credential_shaped_keys_always_mine_their_scalar;
          Alcotest.test_case "bounds unterminated stream buffering" `Quick
            test_stream_emits_bounded_unterminated_output;
          Alcotest.test_case "streams carriage-return progress" `Quick
            test_stream_emits_carriage_return_progress;
          Alcotest.test_case "redacts a secret crossing a bounded flush" `Quick
            test_stream_redacts_secret_crossing_bounded_flush;
          Alcotest.test_case "bounds an overlapping repeated secret" `Quick
            test_stream_bounds_overlapping_repeated_secret;
        ] )
    ]
