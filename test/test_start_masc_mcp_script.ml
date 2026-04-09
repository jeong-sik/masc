open Alcotest

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

let script_path () =
  Filename.concat (source_root ()) "start-masc-mcp.sh"

let loopback_script_path () =
  Filename.concat (source_root ()) "scripts/start-loopback.sh"

let quote = Filename.quote

let read_file path =
  In_channel.with_open_bin path In_channel.input_all

let contains_substring haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop idx =
    idx + nlen <= hlen
    && (String.sub haystack idx nlen = needle || loop (idx + 1))
  in
  nlen = 0 || loop 0

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

let write_executable path content =
  write_file path content;
  Unix.chmod path 0o755

let rec mkdir_p path =
  if path = "" || path = "." || path = "/" then
    ()
  else if Sys.file_exists path then
    ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let run_shell ?(env = []) ~cwd cmd =
  let env =
    if List.mem_assoc "MASC_ALLOW_PORT_REUSE" env then env
    else ("MASC_ALLOW_PORT_REUSE", "1") :: env
  in
  let env_prefix =
    env
    |> List.map (fun (k, v) -> Printf.sprintf "%s=%s" k (quote v))
    |> String.concat " "
  in
  let full =
    if env_prefix = "" then
      Printf.sprintf "cd %s && %s" (quote cwd) cmd
    else
      Printf.sprintf "cd %s && %s %s" (quote cwd) env_prefix cmd
  in
  let out = Filename.temp_file "start-masc-out" ".txt" in
  let err = Filename.temp_file "start-masc-err" ".txt" in
  let wrapped =
    Printf.sprintf "%s > %s 2> %s" full (quote out) (quote err)
  in
  let code = Sys.command wrapped in
  let stdout = read_file out in
  let stderr = read_file err in
  Sys.remove out;
  Sys.remove err;
  (code, stdout, stderr)

let copy_script src dst =
  write_executable dst (read_file src)

let make_config_root root =
  let config = Filename.concat root "config" in
  mkdir_p (Filename.concat config "prompts");
  mkdir_p (Filename.concat config "keepers");
  mkdir_p (Filename.concat config "personas");
  write_file (Filename.concat config "cascade.json") "{\"seed\":\"repo\"}";
  config

let write_fake_eio_exe exe_path ~marker =
  mkdir_p (Filename.dirname exe_path);
  let content =
    Printf.sprintf
      {|
#!/bin/sh
set -eu
capture="${FAKE_CAPTURE_FILE:?}"
{
  printf 'FAKE_EXE_MARKER=%s\n' '%s'
  printf 'MASC_STORAGE_TYPE=%%s\n' "${MASC_STORAGE_TYPE:-}"
  printf 'SUPABASE_DB_URL=%%s\n' "${SUPABASE_DB_URL:-}"
  printf 'MASC_BASE_PATH=%%s\n' "${MASC_BASE_PATH:-}"
  printf 'MASC_CONFIG_DIR=%%s\n' "${MASC_CONFIG_DIR:-}"
  printf 'MASC_KEEPER_BOOTSTRAP_ENABLED=%%s\n' "${MASC_KEEPER_BOOTSTRAP_ENABLED:-}"
  printf 'MASC_WS_ENABLED=%%s\n' "${MASC_WS_ENABLED:-}"
  printf 'MASC_WEBRTC_ENABLED=%%s\n' "${MASC_WEBRTC_ENABLED:-}"
  printf 'ARGS=%%s\n' "$*"
} >"$capture"
exit 0
|} "%s" marker
  in
  write_file exe_path content;
  Unix.chmod exe_path 0o755

let make_fake_eio_exe repo_root =
  let exe_path = Filename.concat repo_root "_build/default/bin/main_eio.exe" in
  write_fake_eio_exe exe_path ~marker:"local"

let test_explicit_env_overrides_repo_env_files () =
  with_temp_dir "start-masc-script" (fun dir ->
      let script = Filename.concat dir "start-masc-mcp.sh" in
      copy_script (script_path ()) script;
      write_file (Filename.concat dir ".env.local")
        "MASC_STORAGE_TYPE=filesystem\nSUPABASE_DB_URL=postgresql://from-env-file/db\n";
      make_fake_eio_exe dir;
      let capture = Filename.concat dir "captured-env.txt" in
      let code, stdout, stderr =
        run_shell ~cwd:dir
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("MASC_STORAGE_TYPE", "postgres");
              ("SUPABASE_DB_URL", "postgresql://caller-override/db");
              ("MASC_BASE_PATH", dir);
              ("MASC_CONFIG_DIR", Filename.concat dir "config");
            ]
          (Printf.sprintf "%s --http --port 9955 --base-path %s"
             (quote script) (quote dir))
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let captured = read_file capture in
      check bool "explicit storage wins" true
        (contains_substring captured "MASC_STORAGE_TYPE=postgres");
      check bool "explicit DB URL wins" true
        (contains_substring captured
           "SUPABASE_DB_URL=postgresql://caller-override/db");
      check bool "base path passed through" true
        (contains_substring captured ("MASC_BASE_PATH=" ^ dir));
      check bool "explicit config dir preserved" true
        (contains_substring captured ("MASC_CONFIG_DIR=" ^ Filename.concat dir "config")))

let test_realtime_transports_default_to_base_path_config_and_preserve_override ()
    =
  with_temp_dir "start-masc-script" (fun dir ->
      let script = Filename.concat dir "start-masc-mcp.sh" in
      copy_script (script_path ()) script;
      ignore (make_config_root dir);
      make_fake_eio_exe dir;
      let home_dir = Filename.concat dir "home" in
      mkdir_p (Filename.concat home_dir ".masc/config/prompts");
      write_file (Filename.concat home_dir ".masc/config/cascade.json") "{}";
      let bootstrapped_config = Filename.concat dir ".masc/config" in
      let capture_default = Filename.concat dir "captured-default.txt" in
      let code_default, stdout_default, stderr_default =
        run_shell ~cwd:dir
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture_default);
              ("HOME", home_dir);
              ("MASC_BASE_PATH", dir);
              ("MASC_CONFIG_DIR", "");
            ]
          (Printf.sprintf "%s --http --port 9956 --base-path %s"
             (quote script) (quote dir))
      in
      if code_default <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code_default stdout_default stderr_default;
      let captured_default = read_file capture_default in
      check bool "ws enabled by default" true
        (contains_substring captured_default "MASC_WS_ENABLED=1");
      check bool "webrtc enabled by default" true
        (contains_substring captured_default "MASC_WEBRTC_ENABLED=1");
      check bool "config dir defaults to base path config" true
        (contains_substring captured_default
           ("MASC_CONFIG_DIR=" ^ bootstrapped_config));
      check bool "base path config bootstrapped" true
        (Sys.file_exists (Filename.concat bootstrapped_config "cascade.json"));
      let capture_override = Filename.concat dir "captured-override.txt" in
      let code_override, stdout_override, stderr_override =
        run_shell ~cwd:dir
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture_override);
              ("MASC_BASE_PATH", dir);
              ("MASC_CONFIG_DIR", Filename.concat dir "custom-config");
              ("MASC_WS_ENABLED", "0");
              ("MASC_WEBRTC_ENABLED", "0");
            ]
          (Printf.sprintf "%s --http --port 9957 --base-path %s"
             (quote script) (quote dir))
      in
      if code_override <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code_override stdout_override stderr_override;
      let captured_override = read_file capture_override in
      check bool "config dir override preserved" true
        (contains_substring captured_override
           ("MASC_CONFIG_DIR=" ^ Filename.concat dir "custom-config"));
      check bool "ws override preserved" true
        (contains_substring captured_override "MASC_WS_ENABLED=0");
      check bool "webrtc override preserved" true
        (contains_substring captured_override "MASC_WEBRTC_ENABLED=0"))

let test_bootstraps_base_path_config_from_repo_when_unset () =
  with_temp_dir "start-masc-script" (fun dir ->
      let script = Filename.concat dir "start-masc-mcp.sh" in
      copy_script (script_path ()) script;
      ignore (make_config_root dir);
      make_fake_eio_exe dir;
      let bootstrapped_config = Filename.concat dir ".masc/config" in
      let capture = Filename.concat dir "captured-fallback.txt" in
      let code, stdout, stderr =
        run_shell ~cwd:dir
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("HOME", Filename.concat dir "empty-home");
              ("MASC_BASE_PATH", dir);
              ("MASC_CONFIG_DIR", "");
            ]
          (Printf.sprintf "%s --http --port 9959 --base-path %s"
             (quote script) (quote dir))
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code stdout stderr;
      let captured = read_file capture in
      check bool "defaults to base path config" true
        (contains_substring captured
           ("MASC_CONFIG_DIR=" ^ bootstrapped_config));
      check bool "repo config copied to base path config" true
        (Sys.file_exists (Filename.concat bootstrapped_config "cascade.json")))

let test_inherited_base_path_with_dual_masc_roots_is_sanitized () =
  with_temp_dir "start-masc-script" (fun dir ->
      let script = Filename.concat dir "start-masc-mcp.sh" in
      copy_script (script_path ()) script;
      make_fake_eio_exe dir;
      let stale_root = Filename.concat dir "stale-root" in
      let home_dir = Filename.concat dir "empty-home" in
      mkdir_p (Filename.concat dir ".masc");
      mkdir_p (Filename.concat stale_root ".masc");
      mkdir_p home_dir;
      let capture = Filename.concat dir "captured-sanitized.txt" in
      let code, stdout, stderr =
        run_shell ~cwd:dir
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("HOME", home_dir);
              ("MASC_BASE_PATH", stale_root);
              ("MASC_ALLOW_INHERITED_BASE_PATH", "");
            ]
          (Printf.sprintf "%s --http --port 9960" (quote script))
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let captured = read_file capture in
      check bool "inherited base path corrected to script root" true
        (contains_substring captured ("MASC_BASE_PATH=" ^ dir)))

let test_parent_project_base_path_with_dual_masc_roots_is_sanitized () =
  with_temp_dir "start-masc-script" (fun dir ->
      let parent = Filename.concat dir "parent-root" in
      let repo = Filename.concat parent "workspace/yousleepwhen/masc-mcp" in
      let home_dir = Filename.concat dir "empty-home" in
      mkdir_p repo;
      mkdir_p home_dir;
      mkdir_p (Filename.concat parent ".masc");
      mkdir_p (Filename.concat repo ".masc");
      let script = Filename.concat repo "start-masc-mcp.sh" in
      copy_script (script_path ()) script;
      make_fake_eio_exe repo;
      let capture = Filename.concat dir "captured-parent-sanitized.txt" in
      let code, stdout, stderr =
        run_shell ~cwd:repo
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("HOME", home_dir);
              ("MASC_BASE_PATH", parent);
              ("MASC_ALLOW_INHERITED_BASE_PATH", "");
            ]
          (Printf.sprintf "%s --http --port 9963" (quote script))
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let captured = read_file capture in
      check bool "parent root inheritance corrected to repo root" true
        (contains_substring captured ("MASC_BASE_PATH=" ^ repo)))

let test_zshenv_inherited_base_path_with_dual_roots_is_sanitized () =
  with_temp_dir "start-masc-script" (fun dir ->
      let parent = Filename.concat dir "parent-root" in
      let repo = Filename.concat parent "workspace/yousleepwhen/masc-mcp" in
      let home_dir = Filename.concat dir "home" in
      mkdir_p repo;
      mkdir_p home_dir;
      mkdir_p (Filename.concat parent ".masc");
      mkdir_p (Filename.concat repo ".masc");
      write_file (Filename.concat home_dir ".zshenv")
        (Printf.sprintf "export MASC_BASE_PATH=%s\n" parent);
      let script = Filename.concat repo "start-masc-mcp.sh" in
      copy_script (script_path ()) script;
      make_fake_eio_exe repo;
      let capture = Filename.concat dir "captured-zshenv-sanitized.txt" in
      let code, stdout, stderr =
        run_shell ~cwd:repo
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("HOME", home_dir);
              ("MASC_ALLOW_INHERITED_BASE_PATH", "");
            ]
          (Printf.sprintf "%s --http --port 9965" (quote script))
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let captured = read_file capture in
      check bool "zshenv inherited base path corrected to repo root" true
        (contains_substring captured ("MASC_BASE_PATH=" ^ repo)))

let test_dual_masc_roots_opt_in_preserves_inherited_base_path () =
  with_temp_dir "start-masc-script" (fun dir ->
      let script = Filename.concat dir "start-masc-mcp.sh" in
      copy_script (script_path ()) script;
      make_fake_eio_exe dir;
      let inherited_root = Filename.concat dir "shared-root" in
      let home_dir = Filename.concat dir "empty-home" in
      mkdir_p (Filename.concat dir ".masc");
      mkdir_p (Filename.concat inherited_root ".masc");
      mkdir_p home_dir;
      let capture = Filename.concat dir "captured-opt-in.txt" in
      let code, stdout, stderr =
        run_shell ~cwd:dir
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("HOME", home_dir);
              ("MASC_BASE_PATH", inherited_root);
              ("MASC_ALLOW_INHERITED_BASE_PATH", "1");
            ]
          (Printf.sprintf "%s --http --port 9964" (quote script))
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let captured = read_file capture in
      check bool "opt-in preserves inherited base path" true
        (contains_substring captured ("MASC_BASE_PATH=" ^ inherited_root)))

let test_worktree_prefers_local_build_over_workspace_build () =
  with_temp_dir "start-masc-script" (fun dir ->
      let repo_root = Filename.concat dir "repo-root" in
      let worktree = Filename.concat repo_root ".worktrees/fix-transport" in
      mkdir_p worktree;
      let script = Filename.concat worktree "start-masc-mcp.sh" in
      copy_script (script_path ()) script;
      let local_exe =
        Filename.concat worktree "_build/default/bin/main_eio.exe"
      in
      let workspace_exe =
        Filename.concat repo_root "_build/default/masc-mcp/bin/main_eio.exe"
      in
      write_fake_eio_exe local_exe ~marker:"local";
      write_fake_eio_exe workspace_exe ~marker:"workspace";
      let capture = Filename.concat dir "captured-pref.txt" in
      let code, stdout, stderr =
        run_shell ~cwd:worktree
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("MASC_BASE_PATH", repo_root);
            ]
          (Printf.sprintf "%s --http --port 9958 --base-path %s"
             (quote script) (quote repo_root))
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let captured = read_file capture in
      check bool "local build wins in worktree" true
        (contains_substring captured "FAKE_EXE_MARKER=local"))

let test_loopback_disables_keeper_autoboot_by_default_and_preserves_override ()
    =
  with_temp_dir "start-loopback-script" (fun dir ->
      let repo_root = Filename.concat dir "repo-root" in
      let scripts_dir = Filename.concat repo_root "scripts" in
      mkdir_p scripts_dir;
      let start_script = Filename.concat repo_root "start-masc-mcp.sh" in
      let loopback_script = Filename.concat scripts_dir "start-loopback.sh" in
      copy_script (script_path ()) start_script;
      copy_script (loopback_script_path ()) loopback_script;
      write_file (Filename.concat repo_root ".env.local")
        "MASC_KEEPER_BOOTSTRAP_ENABLED=true\n";
      make_fake_eio_exe repo_root;
      let home_dir = Filename.concat dir "home" in
      let capture_default = Filename.concat dir "captured-loopback-default.txt" in
      let code_default, stdout_default, stderr_default =
        run_shell ~cwd:repo_root
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture_default);
              ("HOME", home_dir);
              ("MASC_KEEPER_BOOTSTRAP_ENABLED", "");
            ]
          (Printf.sprintf "%s --port 9961 --base-path %s"
             (quote loopback_script) (quote repo_root))
      in
      if code_default <> 0 then
        failf "loopback script failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code_default stdout_default stderr_default;
      let captured_default = read_file capture_default in
      check bool "loopback disables keeper autoboot by default" true
        (contains_substring captured_default "MASC_KEEPER_BOOTSTRAP_ENABLED=false");
      let capture_override =
        Filename.concat dir "captured-loopback-override.txt"
      in
      let code_override, stdout_override, stderr_override =
        run_shell ~cwd:repo_root
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture_override);
              ("HOME", home_dir);
              ("MASC_KEEPER_BOOTSTRAP_ENABLED", "true");
            ]
          (Printf.sprintf "%s --port 9962 --base-path %s"
             (quote loopback_script) (quote repo_root))
      in
      if code_override <> 0 then
        failf "loopback script override failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code_override stdout_override stderr_override;
      let captured_override = read_file capture_override in
      check bool "loopback preserves explicit keeper autoboot override" true
        (contains_substring captured_override "MASC_KEEPER_BOOTSTRAP_ENABLED=true"))

let () =
  run "start_masc_mcp_script"
    [
      ( "script",
        [
          test_case "explicit env overrides repo env files" `Quick
            test_explicit_env_overrides_repo_env_files;
          test_case
            "realtime transports default to base path config and preserve override"
            `Quick
            test_realtime_transports_default_to_base_path_config_and_preserve_override;
          test_case "bootstraps base path config from repo when unset" `Quick
            test_bootstraps_base_path_config_from_repo_when_unset;
          test_case "inherited base path with dual .masc roots is sanitized" `Quick
            test_inherited_base_path_with_dual_masc_roots_is_sanitized;
          test_case "parent project inherited base path is sanitized" `Quick
            test_parent_project_base_path_with_dual_masc_roots_is_sanitized;
          test_case "zshenv inherited base path is sanitized" `Quick
            test_zshenv_inherited_base_path_with_dual_roots_is_sanitized;
          test_case "dual roots opt-in preserves inherited base path" `Quick
            test_dual_masc_roots_opt_in_preserves_inherited_base_path;
          test_case "worktree prefers local build over workspace build" `Quick
            test_worktree_prefers_local_build_over_workspace_build;
          test_case
            "loopback disables keeper autoboot by default and preserves override"
            `Quick
            test_loopback_disables_keeper_autoboot_by_default_and_preserves_override;
        ] );
    ]
