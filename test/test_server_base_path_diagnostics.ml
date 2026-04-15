open Masc_mcp

let with_env name value f =
  let saved = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match saved with
      | Some prior -> Unix.putenv name prior
      | None -> Unix.putenv name "")
    f

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let rec mkdir_p path =
  if path = "" || path = "." || path = "/" then
    ()
  else if Sys.file_exists path then
    ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let with_cwd path f =
  let saved = Sys.getcwd () in
  Unix.chdir path;
  Fun.protect ~finally:(fun () -> Unix.chdir saved) f

let canonical_path path =
  try Unix.realpath path with
  | Unix.Unix_error _ -> path

let string_contains ~needle haystack =
  let needle_len = String.length needle in
  let hay_len = String.length haystack in
  let rec loop idx =
    if idx + needle_len > hay_len then
      false
    else if String.sub haystack idx needle_len = needle then
      true
    else
      loop (idx + 1)
  in
  if needle_len = 0 then true else loop 0

let test_detects_dual_masc_roots () =
  with_temp_dir "base-path-diag" @@ fun root ->
  let cwd = Filename.concat root "repo" in
  let effective = Filename.concat root "workspace" in
  Unix.mkdir cwd 0o755;
  Unix.mkdir effective 0o755;
  let cwd_masc = Filename.concat cwd ".masc" in
  let effective_masc = Filename.concat effective ".masc" in
  Unix.mkdir cwd_masc 0o755;
  Unix.mkdir effective_masc 0o755;
  Unix.mkdir (Filename.concat cwd_masc "perpetual") 0o755;
  let diag =
    Server_base_path_diagnostics.detect ~cwd
      ~input_base_path:effective
      ~env_masc_base_path:effective
      ~effective_base_path:effective
      ~effective_masc_root:effective_masc
      ()
  in
  Alcotest.(check bool) "roots diverge" true diag.roots_diverge;
  Alcotest.(check bool) "dual roots" true diag.dual_masc_roots;
  Alcotest.(check bool) "cwd .masc exists" true diag.cwd_has_masc_dir;
  Alcotest.(check bool) "effective .masc exists" true diag.effective_has_masc_dir;
  Alcotest.(check bool) "warning present" true (Option.is_some diag.warning);
  Alcotest.(check (list string)) "cwd legacy dirs" [ "perpetual" ]
    diag.cwd_legacy_dirs;
  Alcotest.(check bool) "warning mentions ignored legacy dirs" true
    (match diag.warning with
     | Some warning ->
         string_contains ~needle:"ignored cwd .masc still contains legacy dirs (perpetual)"
           warning
     | None -> false)

let test_implicit_dual_roots_are_strict_violation () =
  (* When [effective_base_path] was derived from a cwd heuristic
     (no [input_base_path], no [resolution_source] → implicit), a
     dual-.masc-root situation forces fail-fast even if the operator
     did not explicitly opt in via [MASC_BASE_PATH_STRICT]. Cwd
     heuristics are unreliable enough that "start the server next to
     two different .masc trees" is unambiguously an operator error. *)
  with_temp_dir "base-path-strict" @@ fun root ->
  let cwd = Filename.concat root "repo" in
  let effective = Filename.concat root "workspace" in
  Unix.mkdir cwd 0o755;
  Unix.mkdir effective 0o755;
  Unix.mkdir (Filename.concat cwd ".masc") 0o755;
  Unix.mkdir (Filename.concat effective ".masc") 0o755;
  with_env "MASC_BASE_PATH_STRICT" (Some "false") @@ fun () ->
  let diag =
    Server_base_path_diagnostics.detect ~cwd
      ~effective_base_path:effective
      ~effective_masc_root:(Filename.concat effective ".masc")
      ()
  in
  Alcotest.(check bool) "strict_mode_requested stays false" false
    diag.strict_mode_requested;
  Alcotest.(check bool) "startup_rejected derived from implicit dual roots" true
    diag.startup_rejected;
  Alcotest.(check bool) "fail_fast derived from implicit dual roots" true
    diag.fail_fast_enabled;
  Alcotest.(check bool) "implicit dual roots violate" true
    (Server_base_path_diagnostics.strict_violation diag)

let test_explicit_resolution_source_escapes_strict_violation () =
  (* When the operator/test-harness explicitly set MASC_BASE_PATH (or
     passed --base-path on the CLI), the runtime trusts that decision
     and uses the explicit path — the warning still fires so operator
     tools can flag the stale cwd .masc tree, but strict_violation
     must return false so the server keeps running.

     Pre-#6548 behavior had this escape via the
     [not explicit_resolution_source] clause in [strict_violation].
     #6548 flattened [strict_violation] to just [dual_masc_roots],
     which broke the [Run SSE reconnect e2e] CI step because the test
     harness runs from a git worktree (with its own committed
     .masc/) while pointing at a tmp [/tmp/sse-storm-base-<hex>]
     MASC_BASE_PATH. The fix restores the escape for explicit
     resolution sources. *)
  with_temp_dir "base-path-explicit" @@ fun root ->
  let cwd = Filename.concat root "repo" in
  let effective = Filename.concat root "workspace" in
  Unix.mkdir cwd 0o755;
  Unix.mkdir effective 0o755;
  Unix.mkdir (Filename.concat cwd ".masc") 0o755;
  Unix.mkdir (Filename.concat effective ".masc") 0o755;
  with_env "MASC_BASE_PATH_STRICT" (Some "true") @@ fun () ->
  let diag =
    Server_base_path_diagnostics.detect ~cwd
      ~resolution_source:"explicit_env"
      ~input_base_path:effective
      ~env_masc_base_path:effective
      ~effective_base_path:effective
      ~effective_masc_root:(Filename.concat effective ".masc")
      ()
  in
  Alcotest.(check bool) "dual roots still detected" true diag.dual_masc_roots;
  Alcotest.(check bool) "warning still present" true
    (Option.is_some diag.warning);
  Alcotest.(check bool) "strict_mode_requested reflects user STRICT=true" true
    diag.strict_mode_requested;
  Alcotest.(check bool) "startup_rejected false for explicit env source" false
    diag.startup_rejected;
  Alcotest.(check bool) "fail_fast_enabled remains true under strict mode" true
    diag.fail_fast_enabled;
  Alcotest.(check bool) "explicit env source escapes violation" false
    (Server_base_path_diagnostics.strict_violation diag)

let test_explicit_cli_resolution_source_also_escapes () =
  (* Symmetric with [test_explicit_resolution_source_escapes_strict_violation]
     but drives [resolution_source:"explicit_cli"]. [explicit_resolution_source]
     pattern-matches on both ["explicit_env"] and ["explicit_cli"], so both
     must take the escape branch. This test guards against a future
     refactor that splits those literals into separate code paths and
     accidentally drops the CLI case. *)
  with_temp_dir "base-path-explicit-cli" @@ fun root ->
  let cwd = Filename.concat root "repo" in
  let effective = Filename.concat root "workspace" in
  Unix.mkdir cwd 0o755;
  Unix.mkdir effective 0o755;
  Unix.mkdir (Filename.concat cwd ".masc") 0o755;
  Unix.mkdir (Filename.concat effective ".masc") 0o755;
  with_env "MASC_BASE_PATH_STRICT" None @@ fun () ->
  let diag =
    Server_base_path_diagnostics.detect ~cwd
      ~resolution_source:"explicit_cli"
      ~input_base_path:effective
      ~effective_base_path:effective
      ~effective_masc_root:(Filename.concat effective ".masc")
      ()
  in
  Alcotest.(check bool) "dual roots still detected" true diag.dual_masc_roots;
  Alcotest.(check bool) "strict_mode_requested false without user STRICT" false
    diag.strict_mode_requested;
  Alcotest.(check bool) "startup_rejected false for explicit cli source" false
    diag.startup_rejected;
  Alcotest.(check bool) "fail_fast_enabled false without user STRICT" false
    diag.fail_fast_enabled;
  Alcotest.(check bool) "explicit cli source escapes violation" false
    (Server_base_path_diagnostics.strict_violation diag)

let test_to_yojson_exposes_effective_paths () =
  let diag =
    Server_base_path_diagnostics.detect ~cwd:"/tmp/repo"
      ~input_base_path:"/tmp/workspace"
      ~env_masc_base_path:"/tmp/workspace"
      ~effective_base_path:"/tmp/workspace"
      ~effective_masc_root:"/tmp/workspace/.masc"
      ()
  in
  let open Yojson.Safe.Util in
  let json = Server_base_path_diagnostics.to_yojson diag in
  Alcotest.(check string) "effective base path" "/tmp/workspace"
    (json |> member "effective_base_path" |> to_string);
  Alcotest.(check string) "effective masc root" "/tmp/workspace/.masc"
    (json |> member "effective_masc_root" |> to_string);
  Alcotest.(check bool) "roots diverge field" true
    (json |> member "roots_diverge" |> to_bool);
  Alcotest.(check int) "cwd legacy dirs exposed" 0
    (json |> member "cwd_legacy_dirs" |> to_list |> List.length);
  Alcotest.(check int) "effective legacy dirs exposed" 0
    (json |> member "effective_legacy_dirs" |> to_list |> List.length)

let test_to_yojson_exposes_resolution_source () =
  let diag =
    Server_base_path_diagnostics.detect ~cwd:"/tmp/repo"
      ~resolution_source:"explicit_cli"
      ~input_base_path:"/tmp/workspace"
      ~env_masc_base_path:"/tmp/workspace"
      ~effective_base_path:"/tmp/workspace"
      ~effective_masc_root:"/tmp/workspace/.masc"
      ()
  in
  let open Yojson.Safe.Util in
  let json = Server_base_path_diagnostics.to_yojson diag in
  Alcotest.(check string) "resolution source" "explicit_cli"
    (json |> member "resolution_source" |> to_string)

let test_to_yojson_exposes_gate_fields () =
  let diag =
    Server_base_path_diagnostics.detect ~cwd:"/tmp/repo"
      ~effective_base_path:"/tmp/workspace"
      ~effective_masc_root:"/tmp/workspace/.masc"
      ()
  in
  let open Yojson.Safe.Util in
  let json = Server_base_path_diagnostics.to_yojson diag in
  Alcotest.(check bool) "strict_mode_requested field" false
    (json |> member "strict_mode_requested" |> to_bool);
  Alcotest.(check bool) "startup_rejected field" false
    (json |> member "startup_rejected" |> to_bool);
  Alcotest.(check bool) "fail_fast_enabled field" false
    (json |> member "fail_fast_enabled" |> to_bool)

let test_default_base_path_ignores_inherited_parent_root_in_tests () =
  with_temp_dir "base-path-default" @@ fun root ->
  let base_path = Filename.concat root "base" in
  let repo = Filename.concat base_path "workspace/yousleepwhen/masc-mcp" in
  mkdir_p repo;
  Unix.mkdir (Filename.concat base_path ".masc") 0o755;
  Unix.mkdir (Filename.concat repo ".masc") 0o755;
  with_cwd repo @@ fun () ->
  with_env "MASC_BASE_PATH" (Some base_path) @@ fun () ->
  with_env "MASC_TEST_ALLOW_INHERITED_BASE_PATH" None @@ fun () ->
  with_env "MASC_BASE_PATH_INPUT" None @@ fun () ->
  Alcotest.(check string) "default base path ignores inherited parent root in tests"
    (canonical_path repo)
    (Server_mcp_transport_http.default_base_path () |> canonical_path)

let test_default_base_path_preserves_explicit_root_with_opt_in () =
  with_temp_dir "base-path-default-optin" @@ fun root ->
  let base_path = Filename.concat root "base" in
  let repo = Filename.concat base_path "workspace/yousleepwhen/masc-mcp" in
  mkdir_p repo;
  Unix.mkdir (Filename.concat base_path ".masc") 0o755;
  Unix.mkdir (Filename.concat repo ".masc") 0o755;
  with_cwd repo @@ fun () ->
  with_env "MASC_BASE_PATH" (Some base_path) @@ fun () ->
  with_env "MASC_TEST_ALLOW_INHERITED_BASE_PATH" (Some "true") @@ fun () ->
  with_env "MASC_BASE_PATH_INPUT" None @@ fun () ->
  Alcotest.(check string) "explicit root preserved with opt-in"
    (canonical_path base_path)
    (Server_mcp_transport_http.default_base_path () |> canonical_path)

let test_default_base_path_ignores_inherited_root_without_local_masc () =
  with_temp_dir "base-path-default-no-local-masc" @@ fun root ->
  let base_path = Filename.concat root "base" in
  let repo = Filename.concat base_path "workspace/yousleepwhen/masc-mcp" in
  mkdir_p repo;
  Unix.mkdir (Filename.concat base_path ".masc") 0o755;
  with_cwd repo @@ fun () ->
  with_env "MASC_BASE_PATH" (Some base_path) @@ fun () ->
  with_env "MASC_TEST_ALLOW_INHERITED_BASE_PATH" None @@ fun () ->
  with_env "MASC_BASE_PATH_INPUT" None @@ fun () ->
  Alcotest.(check string) "default base path ignores inherited root without local .masc"
    (canonical_path repo)
    (Server_mcp_transport_http.default_base_path () |> canonical_path)

let test_default_base_path_falls_back_to_home_when_unset () =
  with_temp_dir "base-path-default-home-fallback" @@ fun root ->
  let repo = Filename.concat root "repo" in
  let home = Filename.concat root "home" in
  mkdir_p repo;
  mkdir_p home;
  with_cwd repo @@ fun () ->
  with_env "MASC_BASE_PATH" None @@ fun () ->
  with_env "MASC_TEST_ALLOW_INHERITED_BASE_PATH" None @@ fun () ->
  with_env "MASC_BASE_PATH_INPUT" None @@ fun () ->
  with_env "HOME" (Some home) @@ fun () ->
  Alcotest.(check string) "default base path falls back to home"
    (canonical_path home)
    (Server_mcp_transport_http.default_base_path () |> canonical_path)

let () =
  Alcotest.run "Server_base_path_diagnostics"
    [
      ( "diagnostics",
        [
          Alcotest.test_case "detects dual .masc roots" `Quick
            test_detects_dual_masc_roots;
          Alcotest.test_case "implicit dual roots are strict violation" `Quick
            test_implicit_dual_roots_are_strict_violation;
          Alcotest.test_case
            "explicit env resolution source escapes strict violation"
            `Quick
            test_explicit_resolution_source_escapes_strict_violation;
          Alcotest.test_case
            "explicit cli resolution source also escapes"
            `Quick
            test_explicit_cli_resolution_source_also_escapes;
          Alcotest.test_case "json exposes effective paths" `Quick
            test_to_yojson_exposes_effective_paths;
          Alcotest.test_case "json exposes resolution source" `Quick
            test_to_yojson_exposes_resolution_source;
          Alcotest.test_case "json exposes gate fields" `Quick
            test_to_yojson_exposes_gate_fields;
          Alcotest.test_case "default base path ignores inherited parent root in tests"
            `Quick test_default_base_path_ignores_inherited_parent_root_in_tests;
          Alcotest.test_case
            "default base path preserves explicit root with opt-in"
            `Quick test_default_base_path_preserves_explicit_root_with_opt_in;
          Alcotest.test_case
            "default base path ignores inherited root without local .masc"
            `Quick test_default_base_path_ignores_inherited_root_without_local_masc;
          Alcotest.test_case
            "default base path falls back to home when unset"
            `Quick test_default_base_path_falls_back_to_home_when_unset;
        ] );
    ]
