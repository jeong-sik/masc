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

let test_strict_violation_respects_env () =
  with_temp_dir "base-path-strict" @@ fun root ->
  let cwd = Filename.concat root "repo" in
  let effective = Filename.concat root "workspace" in
  Unix.mkdir cwd 0o755;
  Unix.mkdir effective 0o755;
  Unix.mkdir (Filename.concat cwd ".masc") 0o755;
  Unix.mkdir (Filename.concat effective ".masc") 0o755;
  with_env "MASC_BASE_PATH_STRICT" (Some "true") @@ fun () ->
  let diag =
    Server_base_path_diagnostics.detect ~cwd
      ~effective_base_path:effective
      ~effective_masc_root:(Filename.concat effective ".masc")
      ()
  in
  Alcotest.(check bool) "strict enabled" true diag.fail_fast_enabled;
  Alcotest.(check bool) "strict violation" true
    (Server_base_path_diagnostics.strict_violation diag)

let test_explicit_resolution_source_bypasses_strict_violation () =
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
  Alcotest.(check bool) "strict enabled" true diag.fail_fast_enabled;
  Alcotest.(check bool) "explicit source skips strict violation" false
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

let test_default_base_path_sanitizes_inherited_dual_roots () =
  with_temp_dir "base-path-default" @@ fun root ->
  let base_path = Filename.concat root "base" in
  let repo = Filename.concat base_path "workspace/yousleepwhen/masc-mcp" in
  mkdir_p repo;
  Unix.mkdir (Filename.concat base_path ".masc") 0o755;
  Unix.mkdir (Filename.concat repo ".masc") 0o755;
  with_cwd repo @@ fun () ->
  with_env "MASC_BASE_PATH" (Some base_path) @@ fun () ->
  with_env "MASC_BASE_PATH_INPUT" None @@ fun () ->
  with_env "MASC_ALLOW_INHERITED_BASE_PATH" (Some "") @@ fun () ->
  Alcotest.(check string) "default base path ignores inherited parent root"
    (canonical_path repo)
    (Server_mcp_transport_http.default_base_path () |> canonical_path)

let test_default_base_path_respects_opt_in_for_inherited_root () =
  with_temp_dir "base-path-default-optin" @@ fun root ->
  let base_path = Filename.concat root "base" in
  let repo = Filename.concat base_path "workspace/yousleepwhen/masc-mcp" in
  mkdir_p repo;
  Unix.mkdir (Filename.concat base_path ".masc") 0o755;
  Unix.mkdir (Filename.concat repo ".masc") 0o755;
  with_cwd repo @@ fun () ->
  with_env "MASC_BASE_PATH" (Some base_path) @@ fun () ->
  with_env "MASC_BASE_PATH_INPUT" None @@ fun () ->
  with_env "MASC_ALLOW_INHERITED_BASE_PATH" (Some "1") @@ fun () ->
  Alcotest.(check string) "opt-in keeps inherited root"
    (canonical_path base_path)
    (Server_mcp_transport_http.default_base_path () |> canonical_path)

let test_default_base_path_keeps_inherited_root_without_local_masc () =
  with_temp_dir "base-path-default-no-local-masc" @@ fun root ->
  let base_path = Filename.concat root "base" in
  let repo = Filename.concat base_path "workspace/yousleepwhen/masc-mcp" in
  mkdir_p repo;
  Unix.mkdir (Filename.concat base_path ".masc") 0o755;
  with_cwd repo @@ fun () ->
  with_env "MASC_BASE_PATH" (Some base_path) @@ fun () ->
  with_env "MASC_BASE_PATH_INPUT" None @@ fun () ->
  with_env "MASC_ALLOW_INHERITED_BASE_PATH" (Some "") @@ fun () ->
  Alcotest.(check string) "default base path keeps inherited root without local .masc"
    (canonical_path base_path)
    (Server_mcp_transport_http.default_base_path () |> canonical_path)

let () =
  Alcotest.run "Server_base_path_diagnostics"
    [
      ( "diagnostics",
        [
          Alcotest.test_case "detects dual .masc roots" `Quick
            test_detects_dual_masc_roots;
          Alcotest.test_case "strict violation respects env" `Quick
            test_strict_violation_respects_env;
          Alcotest.test_case
            "explicit resolution source bypasses strict violation"
            `Quick
            test_explicit_resolution_source_bypasses_strict_violation;
          Alcotest.test_case "json exposes effective paths" `Quick
            test_to_yojson_exposes_effective_paths;
          Alcotest.test_case "json exposes resolution source" `Quick
            test_to_yojson_exposes_resolution_source;
          Alcotest.test_case "default base path sanitizes inherited parent root"
            `Quick test_default_base_path_sanitizes_inherited_dual_roots;
          Alcotest.test_case "default base path honors inherited opt-in" `Quick
            test_default_base_path_respects_opt_in_for_inherited_root;
          Alcotest.test_case
            "default base path keeps inherited root without local .masc"
            `Quick test_default_base_path_keeps_inherited_root_without_local_masc;
        ] );
    ]
