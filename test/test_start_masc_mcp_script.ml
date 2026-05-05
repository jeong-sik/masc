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

let canonical_path path =
  try Unix.realpath path with _ -> path

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
  let scrubbed_env =
    [
      "MASC_STORAGE_TYPE";
      "MASC_KEEPER_BOOTSTRAP_ENABLED";
      "MASC_MCP_PORT";
      "MASC_HOST";
      "MASC_BASE_PATH";
      "MASC_SIDECAR_ROOT";
      "MASC_BASE_PATH_INPUT";
      "MASC_BASE_PATH_RESOLUTION_SOURCE";
      "MASC_CONFIG_DIR";
      "MASC_PERSONAS_DIR";
      "MASC_WS_ENABLED";
      "MASC_WEBRTC_ENABLED";
    ]
    |> List.map (fun name -> Printf.sprintf "-u %s" name)
    |> String.concat " "
  in
  let env_prefix =
    env
    |> List.map (fun (k, v) -> Printf.sprintf "%s=%s" k (quote v))
    |> String.concat " "
  in
  let shell_cmd =
    match String.trim env_prefix with
    | "" -> Printf.sprintf "env %s %s" scrubbed_env cmd
    | _ -> Printf.sprintf "env %s %s %s" scrubbed_env env_prefix cmd
  in
  let full =
    Printf.sprintf "cd %s && %s" (quote cwd) shell_cmd
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
  printf 'PWD=%%s\n' "$(pwd)"
  printf 'MASC_STORAGE_TYPE=%%s\n' "${MASC_STORAGE_TYPE:-}"
  printf 'MASC_POSTGRES_URL=%%s\n' "${MASC_POSTGRES_URL:-}"
  printf 'DATABASE_URL=%%s\n' "${DATABASE_URL:-}"
  printf 'SUPABASE_DB_URL=%%s\n' "${SUPABASE_DB_URL:-}"
  printf 'SB_PG_URL=%%s\n' "${SB_PG_URL:-}"
  printf 'MASC_BASE_PATH=%%s\n' "${MASC_BASE_PATH:-}"
  printf 'MASC_SIDECAR_ROOT=%%s\n' "${MASC_SIDECAR_ROOT:-}"
  printf 'MASC_CONFIG_DIR=%%s\n' "${MASC_CONFIG_DIR:-}"
  printf 'MASC_KEEPER_BOOTSTRAP_ENABLED=%%s\n' "${MASC_KEEPER_BOOTSTRAP_ENABLED:-}"
  printf 'MASC_GRPC_PORT=%%s\n' "${MASC_GRPC_PORT:-}"
  printf 'MASC_WS_PORT=%%s\n' "${MASC_WS_PORT:-}"
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

let make_fake_stdio_eio_exe repo_root =
  let exe_path =
    Filename.concat repo_root "_build/default/bin/main_stdio_eio.exe"
  in
  write_fake_eio_exe exe_path ~marker:"stdio"

let make_fake_eio_exe_with_stderr repo_root =
  let exe_path = Filename.concat repo_root "_build/default/bin/main_eio.exe" in
  mkdir_p (Filename.dirname exe_path);
  write_executable exe_path
    {|
#!/bin/sh
set -eu
echo "+[WARN] ℹ️  Running without TLS (plaintext h2c)" >&2
echo "+[INFO] gRPC server on 127.0.0.1:9952" >&2
echo "stderr-keep" >&2
exit 0
|}
let test_explicit_env_overrides_repo_env_files () =
  with_temp_dir "start-masc-script" (fun dir ->
      let script = Filename.concat dir "start-masc-mcp.sh" in
      copy_script (script_path ()) script;
      write_file (Filename.concat dir ".env.local")
        "MASC_STORAGE_TYPE=memory\n";
      make_fake_eio_exe dir;
      let capture = Filename.concat dir "captured-env.txt" in
      let code, stdout, stderr =
        run_shell ~cwd:dir
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("MASC_STORAGE_TYPE", "filesystem");
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
      check bool "explicit env wins over env file" true
        (contains_substring captured "MASC_STORAGE_TYPE=filesystem");
      check bool "base path passed through" true
        (contains_substring captured
           ("MASC_BASE_PATH=" ^ canonical_path dir));
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
      let bootstrapped_config =
        Filename.concat (canonical_path dir) ".masc/config"
      in
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
      let bootstrapped_config =
        Filename.concat (canonical_path dir) ".masc/config"
      in
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

let test_default_base_path_falls_back_to_home_when_unset () =
  with_temp_dir "start-masc-script-home-fallback" (fun dir ->
      let script = Filename.concat dir "start-masc-mcp.sh" in
      copy_script (script_path ()) script;
      ignore (make_config_root dir);
      make_fake_eio_exe dir;
      let home_dir = Filename.concat dir "home" in
      mkdir_p home_dir;
      let capture = Filename.concat dir "captured-home-fallback.txt" in
      let code, stdout, stderr =
        run_shell ~cwd:dir
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("HOME", home_dir);
              ("MASC_BASE_PATH", "");
              ("MASC_CONFIG_DIR", "");
            ]
          (Printf.sprintf "%s --http --port 9969" (quote script))
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code stdout stderr;
      let captured = read_file capture in
      let expected_home = canonical_path home_dir in
      check bool "default base path falls back to home" true
        (contains_substring captured ("MASC_BASE_PATH=" ^ expected_home));
      check bool "default config root follows home fallback" true
        (contains_substring captured
           ("MASC_CONFIG_DIR=" ^ Filename.concat expected_home ".masc/config")))

let test_absolute_env_base_path_is_preserved () =
  with_temp_dir "start-masc-script" (fun dir ->
      let script = Filename.concat dir "start-masc-mcp.sh" in
      copy_script (script_path ()) script;
      make_fake_eio_exe dir;
      let stale_root = Filename.concat dir "stale-root" in
      let home_dir = Filename.concat dir "empty-home" in
      mkdir_p (Filename.concat dir Common.masc_dirname);
      mkdir_p (Filename.concat stale_root Common.masc_dirname);
      mkdir_p home_dir;
      let capture = Filename.concat dir "captured-sanitized.txt" in
      let code, stdout, stderr =
        run_shell ~cwd:dir
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("HOME", home_dir);
              ("MASC_BASE_PATH", stale_root);
            ]
          (Printf.sprintf "%s --http --port 9960" (quote script))
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let captured = read_file capture in
      let expected_root = canonical_path stale_root in
      check bool "absolute env base path preserved" true
        (contains_substring captured ("MASC_BASE_PATH=" ^ expected_root)))

let test_absolute_parent_project_base_path_is_preserved () =
  with_temp_dir "start-masc-script" (fun dir ->
      let parent = Filename.concat dir "parent-root" in
      let repo = Filename.concat parent "workspace/yousleepwhen/masc-mcp" in
      let home_dir = Filename.concat dir "empty-home" in
      mkdir_p repo;
      mkdir_p home_dir;
      mkdir_p (Filename.concat parent Common.masc_dirname);
      mkdir_p (Filename.concat repo Common.masc_dirname);
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
            ]
          (Printf.sprintf "%s --http --port 9963" (quote script))
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let captured = read_file capture in
      let expected_root = canonical_path parent in
      check bool "absolute parent root inheritance preserved" true
        (contains_substring captured ("MASC_BASE_PATH=" ^ expected_root)))

let test_cli_sidecar_root_is_exported () =
  with_temp_dir "start-masc-script-sidecar-root" (fun dir ->
      let script = Filename.concat dir "start-masc-mcp.sh" in
      copy_script (script_path ()) script;
      make_fake_eio_exe dir;
      let base_path = Filename.concat dir "runtime-root" in
      let sidecar_root = Filename.concat dir "workspace/yousleepwhen/masc-mcp" in
      mkdir_p base_path;
      mkdir_p sidecar_root;
      let capture = Filename.concat dir "captured-sidecar-root.txt" in
      let code, stdout, stderr =
        run_shell ~cwd:dir
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("MASC_BASE_PATH", base_path);
            ]
          (Printf.sprintf "%s --http --port 9970 --base-path %s --sidecar-root %s"
             (quote script) (quote base_path) (quote sidecar_root))
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let captured = read_file capture in
      check bool "sidecar root exported to server env" true
        (contains_substring captured
           ("MASC_SIDECAR_ROOT=" ^ canonical_path sidecar_root)))

let test_zshenv_absolute_base_path_is_preserved () =
  with_temp_dir "start-masc-script" (fun dir ->
      let parent = Filename.concat dir "parent-root" in
      let repo = Filename.concat parent "workspace/yousleepwhen/masc-mcp" in
      let home_dir = Filename.concat dir "home" in
      mkdir_p repo;
      mkdir_p home_dir;
      mkdir_p (Filename.concat parent Common.masc_dirname);
      mkdir_p (Filename.concat repo Common.masc_dirname);
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
            ]
          (Printf.sprintf "%s --http --port 9965" (quote script))
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let captured = read_file capture in
      let expected_root = canonical_path parent in
      check bool "zshenv absolute base path preserved" true
        (contains_substring captured ("MASC_BASE_PATH=" ^ expected_root)))

let test_shared_root_env_base_path_is_preserved () =
  with_temp_dir "start-masc-script" (fun dir ->
      let script = Filename.concat dir "start-masc-mcp.sh" in
      copy_script (script_path ()) script;
      make_fake_eio_exe dir;
      let inherited_root = Filename.concat dir "shared-root" in
      let home_dir = Filename.concat dir "empty-home" in
      mkdir_p (Filename.concat dir Common.masc_dirname);
      mkdir_p (Filename.concat inherited_root Common.masc_dirname);
      mkdir_p home_dir;
      let capture = Filename.concat dir "captured-opt-in.txt" in
      let code, stdout, stderr =
        run_shell ~cwd:dir
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("HOME", home_dir);
              ("MASC_BASE_PATH", inherited_root);
            ]
          (Printf.sprintf "%s --http --port 9964" (quote script))
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let captured = read_file capture in
      let expected_root = canonical_path inherited_root in
      check bool "shared-root env base path preserved" true
        (contains_substring captured ("MASC_BASE_PATH=" ^ expected_root)))

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

let test_explicit_base_path_execs_from_base_path () =
  with_temp_dir "start-masc-script" (fun dir ->
      let parent = Filename.concat dir "parent-root" in
      let repo = Filename.concat parent "workspace/yousleepwhen/masc-mcp" in
      let home_dir = Filename.concat dir "empty-home" in
      mkdir_p repo;
      mkdir_p home_dir;
      mkdir_p (Filename.concat parent Common.masc_dirname);
      mkdir_p (Filename.concat repo Common.masc_dirname);
      let script = Filename.concat repo "start-masc-mcp.sh" in
      copy_script (script_path ()) script;
      make_fake_eio_exe repo;
      let capture = Filename.concat dir "captured-explicit-cwd.txt" in
      let code, stdout, stderr =
        run_shell ~cwd:repo
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("HOME", home_dir);
              ("MASC_BASE_PATH", parent);
            ]
          (Printf.sprintf "%s --http --port 9966 --base-path %s"
             (quote script) (quote parent))
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let captured = read_file capture in
      let expected_root = canonical_path parent in
      check bool "exec cwd matches explicit base path" true
        (contains_substring captured ("PWD=" ^ expected_root)))

let test_explicit_base_path_ignores_repo_local_config_from_zshenv () =
  with_temp_dir "start-masc-script" (fun dir ->
      let parent = Filename.concat dir "parent-root" in
      let repo = Filename.concat parent "workspace/yousleepwhen/masc-mcp" in
      let home_dir = Filename.concat dir "home" in
      mkdir_p repo;
      mkdir_p home_dir;
      ignore (make_config_root repo);
      write_file (Filename.concat home_dir ".zshenv")
        (Printf.sprintf
           "export MASC_CONFIG_DIR=%s\nexport MASC_PERSONAS_DIR=%s\n"
           (Filename.concat repo "config")
           (Filename.concat repo "config/personas"));
      let script = Filename.concat repo "start-masc-mcp.sh" in
      copy_script (script_path ()) script;
      make_fake_eio_exe repo;
      let capture = Filename.concat dir "captured-explicit-base-config.txt" in
      let code, stdout, stderr =
        run_shell ~cwd:repo
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("HOME", home_dir);
            ]
          (Printf.sprintf "%s --http --port 9967 --base-path %s"
             (quote script) (quote parent))
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let captured = read_file capture in
      let expected_parent = canonical_path parent in
      check bool "explicit base path resets config root to base path" true
        (contains_substring captured
           ("MASC_CONFIG_DIR=" ^ Filename.concat expected_parent ".masc/config"));
      check bool "stderr explains repo-local config ignore" true
        (contains_substring stderr "Ignoring repo-local MASC_CONFIG_DIR");
      check bool "stderr explains repo-local personas ignore" true
        (contains_substring stderr "Ignoring repo-local MASC_PERSONAS_DIR"))

let test_zshenv_retired_pg_envs_are_scrubbed_before_exec () =
  with_temp_dir "start-masc-script" (fun dir ->
      let parent = Filename.concat dir "parent-root" in
      let repo = Filename.concat parent "workspace/yousleepwhen/masc-mcp" in
      let home_dir = Filename.concat dir "home" in
      mkdir_p repo;
      mkdir_p home_dir;
      mkdir_p (Filename.concat parent Common.masc_dirname);
      write_file (Filename.concat home_dir ".zshenv")
        "export SUPABASE_DB_URL=postgres://legacy/supabase\nexport SB_PG_URL=postgres://legacy/sb\n";
      let script = Filename.concat repo "start-masc-mcp.sh" in
      copy_script (script_path ()) script;
      make_fake_eio_exe repo;
      let capture = Filename.concat dir "captured-retired-pg-envs.txt" in
      let code, stdout, stderr =
        run_shell ~cwd:repo
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("HOME", home_dir);
            ]
          (Printf.sprintf "%s --http --port 9969 --base-path %s"
             (quote script) (quote parent))
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let captured = read_file capture in
      check bool "filesystem storage is reasserted after env file load" true
        (contains_substring captured "MASC_STORAGE_TYPE=filesystem");
      check bool "SUPABASE_DB_URL scrubbed before exec" true
        (contains_substring captured "SUPABASE_DB_URL=");
      check bool "SB_PG_URL scrubbed before exec" true
        (contains_substring captured "SB_PG_URL=");
      check bool "MASC_POSTGRES_URL remains scrubbed before exec" true
        (contains_substring captured "MASC_POSTGRES_URL=");
      check bool "DATABASE_URL remains scrubbed before exec" true
        (contains_substring captured "DATABASE_URL="))

let test_explicit_base_path_ignores_repo_local_config_from_parent_env () =
  with_temp_dir "start-masc-script" (fun dir ->
      let parent = Filename.concat dir "parent-root" in
      let repo = Filename.concat parent "workspace/yousleepwhen/masc-mcp" in
      mkdir_p repo;
      ignore (make_config_root repo);
      let script = Filename.concat repo "start-masc-mcp.sh" in
      copy_script (script_path ()) script;
      make_fake_eio_exe repo;
      let capture = Filename.concat dir "captured-explicit-parent-env.txt" in
      let code, stdout, stderr =
        run_shell ~cwd:repo
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("MASC_CONFIG_DIR", Filename.concat repo "config");
              ("MASC_PERSONAS_DIR", Filename.concat repo "config/personas");
            ]
          (Printf.sprintf "%s --http --port 9968 --base-path %s"
             (quote script) (quote parent))
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let captured = read_file capture in
      let expected_parent = canonical_path parent in
      check bool "parent env repo-local config ignored under external base path"
        true
        (contains_substring captured
           ("MASC_CONFIG_DIR=" ^ Filename.concat expected_parent ".masc/config"));
      check bool "parent env repo-local config ignore is logged" true
        (contains_substring stderr "Ignoring repo-local MASC_CONFIG_DIR"))

let test_explicit_http_port_derives_sidecar_ports () =
  with_temp_dir "start-masc-script" (fun dir ->
      let script = Filename.concat dir "start-masc-mcp.sh" in
      copy_script (script_path ()) script;
      make_fake_eio_exe dir;
      let capture = Filename.concat dir "captured-sidecar-ports.txt" in
      let code, stdout, stderr =
        run_shell ~cwd:dir
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("MASC_BASE_PATH", dir);
            ]
          (Printf.sprintf "%s --http --port 9951 --base-path %s"
             (quote script) (quote dir))
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let captured = read_file capture in
      check bool "grpc port derived from explicit http port" true
        (contains_substring captured "MASC_GRPC_PORT=9952");
      check bool "ws port derived from explicit http port" true
        (contains_substring captured "MASC_WS_PORT=9953"))

let test_grpc_direct_banner_is_preserved_in_stderr () =
  with_temp_dir "start-masc-script" (fun dir ->
      let script = Filename.concat dir "start-masc-mcp.sh" in
      copy_script (script_path ()) script;
      make_fake_eio_exe_with_stderr dir;
      let code, stdout, stderr =
        run_shell ~cwd:dir
          ~env:
            [
              ("MASC_BASE_PATH", dir);
            ]
          (Printf.sprintf "%s --http --port 9951 --base-path %s"
             (quote script) (quote dir))
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      check bool "grpc-direct tls banner preserved" true
        (contains_substring stderr "Running without TLS (plaintext h2c)");
      check bool "grpc-direct server banner preserved" true
        (contains_substring stderr "gRPC server on 127.0.0.1:9952");
      check bool "other stderr preserved" true
        (contains_substring stderr "stderr-keep"))

let test_stdio_skips_dashboard_build_and_http_preflight () =
  with_temp_dir "start-masc-script-stdio" (fun dir ->
      let script = Filename.concat dir "start-masc-mcp.sh" in
      let scripts_dir = Filename.concat dir "scripts" in
      let fake_bin = Filename.concat dir "fake-bin" in
      let dashboard_marker = Filename.concat dir "dashboard-build-ran.txt" in
      let capture = Filename.concat dir "captured-stdio.txt" in
      copy_script (script_path ()) script;
      ignore (make_config_root dir);
      mkdir_p scripts_dir;
      mkdir_p fake_bin;
      write_executable
        (Filename.concat scripts_dir "build-dashboard-if-needed.sh")
        (Printf.sprintf
           {|
#!/bin/sh
set -eu
echo ran > %s
exit 0
|} (quote dashboard_marker));
      write_executable (Filename.concat fake_bin "lsof")
        {|
#!/bin/sh
echo "4242"
exit 0
|};
      make_fake_stdio_eio_exe dir;
      let code, stdout, stderr =
        run_shell ~cwd:dir
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("MASC_BASE_PATH", dir);
              ("PATH", fake_bin ^ ":" ^ Sys.getenv "PATH");
            ]
          (Printf.sprintf "%s --stdio --base-path %s"
             (quote script) (quote dir))
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let captured = read_file capture in
      check bool "stdio executable selected without HTTP build" true
        (contains_substring captured "FAKE_EXE_MARKER=stdio");
      check bool "dashboard helper not invoked in stdio mode" false
        (Sys.file_exists dashboard_marker);
      check bool "stderr explains stdio dashboard skip" true
        (contains_substring stderr "Skipping SPA build in stdio mode."))

let test_http_preflight_waits_for_port_to_clear_before_build () =
  with_temp_dir "start-masc-script-port-wait" (fun dir ->
      let script = Filename.concat dir "start-masc-mcp.sh" in
      let fake_bin = Filename.concat dir "fake-bin" in
      let lsof_seen = Filename.concat dir "lsof-seen" in
      let capture = Filename.concat dir "captured-port-wait.txt" in
      copy_script (script_path ()) script;
      ignore (make_config_root dir);
      mkdir_p fake_bin;
      write_executable (Filename.concat fake_bin "lsof")
        (Printf.sprintf
           {|
#!/bin/sh
case "$*" in
  *9954*)
    if [ ! -f %s ]; then
      echo "4242"
      : > %s
      exit 0
    fi
    ;;
esac
exit 1
|}
           (quote lsof_seen) (quote lsof_seen));
      make_fake_eio_exe dir;
      let code, stdout, stderr =
        run_shell ~cwd:dir
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("MASC_BASE_PATH", dir);
              ("MASC_ALLOW_PORT_REUSE", "0");
              ("MASC_PORT_PREFLIGHT_WAIT_MAX_SEC", "1");
              ("PATH", fake_bin ^ ":" ^ Sys.getenv "PATH");
            ]
          (Printf.sprintf "%s --http --port 9954 --base-path %s"
             (quote script) (quote dir))
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let captured = read_file capture in
      check bool "server started after transient port conflict" true
        (contains_substring captured "FAKE_EXE_MARKER=eio");
      check bool "preflight waited before build" true
        (contains_substring stderr
           "HTTP Port 9954 in use, waiting before build/init"))

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
          test_case "default base path falls back to home when unset" `Quick
            test_default_base_path_falls_back_to_home_when_unset;
          test_case
            "absolute env base path is preserved"
            `Quick
            test_absolute_env_base_path_is_preserved;
          test_case
            "absolute parent project env base path is preserved"
            `Quick
            test_absolute_parent_project_base_path_is_preserved;
          test_case "CLI sidecar root is exported" `Quick
            test_cli_sidecar_root_is_exported;
          test_case "explicit base path execs from base path" `Quick
            test_explicit_base_path_execs_from_base_path;
          test_case
            "explicit base path ignores repo-local config from zshenv"
            `Quick
            test_explicit_base_path_ignores_repo_local_config_from_zshenv;
          test_case
            "zshenv retired pg envs are scrubbed before exec"
            `Quick
            test_zshenv_retired_pg_envs_are_scrubbed_before_exec;
          test_case
            "explicit base path ignores repo-local config from parent env"
            `Quick
            test_explicit_base_path_ignores_repo_local_config_from_parent_env;
          test_case "explicit http port derives sidecar ports" `Quick
            test_explicit_http_port_derives_sidecar_ports;
          test_case "grpc-direct banner is preserved in stderr" `Quick
            test_grpc_direct_banner_is_preserved_in_stderr;
          test_case "stdio skips dashboard build and HTTP preflight" `Quick
            test_stdio_skips_dashboard_build_and_http_preflight;
          test_case "HTTP preflight waits for transient port conflict" `Quick
            test_http_preflight_waits_for_port_to_clear_before_build;
          test_case "zshenv absolute base path is preserved" `Quick
            test_zshenv_absolute_base_path_is_preserved;
          test_case "shared-root env base path is preserved" `Quick
            test_shared_root_env_base_path_is_preserved;
          test_case "worktree prefers local build over workspace build" `Quick
            test_worktree_prefers_local_build_over_workspace_build;
          test_case
            "loopback disables keeper autoboot by default and preserves override"
            `Quick
            test_loopback_disables_keeper_autoboot_by_default_and_preserves_override;
        ] );
    ]
