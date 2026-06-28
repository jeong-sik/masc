open Alcotest

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

let script_path () =
  Filename.concat (source_root ()) "start-masc.sh"

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

let scrubbed_env_names =
    [
      "MASC_KEEPER_BOOTSTRAP_ENABLED";
      "MASC_PORT";
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

let env_array overrides =
  let overrides =
    if List.mem_assoc "MASC_ALLOW_PORT_REUSE" overrides then overrides
    else ("MASC_ALLOW_PORT_REUSE", "1") :: overrides
  in
  let env = Hashtbl.create 64 in
  Unix.environment ()
  |> Array.iter (fun binding ->
         match String.index_opt binding '=' with
         | Some index ->
             let key = String.sub binding 0 index in
             if not (List.mem key scrubbed_env_names) then
               Hashtbl.replace env key
                 (String.sub binding (index + 1)
                    (String.length binding - index - 1))
         | None -> ());
  List.iter (fun (key, value) -> Hashtbl.replace env key value) overrides;
  Hashtbl.fold
    (fun key value acc -> Printf.sprintf "%s=%s" key value :: acc)
    env []
  |> Array.of_list

let process_exit_code = function
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 255

let run_process ?(env = []) ~cwd prog argv =
  let out = Filename.temp_file "start-masc-out" ".txt" in
  let err = Filename.temp_file "start-masc-err" ".txt" in
  let out_fd =
    Unix.openfile out [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600
  in
  Fun.protect
    ~finally:(fun () -> Unix.close out_fd)
    (fun () ->
      let err_fd =
        Unix.openfile err [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600
      in
      Fun.protect
        ~finally:(fun () -> Unix.close err_fd)
        (fun () ->
          let original_cwd = Sys.getcwd () in
          let code =
            Fun.protect
              ~finally:(fun () -> Sys.chdir original_cwd)
              (fun () ->
                Sys.chdir cwd;
                let pid =
                  Unix.create_process_env prog argv (env_array env) Unix.stdin
                    out_fd err_fd
                in
                let _, status = Unix.waitpid [] pid in
                process_exit_code status)
          in
          let stdout = read_file out in
          let stderr = read_file err in
          Sys.remove out;
          Sys.remove err;
          (code, stdout, stderr)))

let run_script ?env ~cwd script args =
  run_process ?env ~cwd "/bin/bash"
    (Array.of_list ("/bin/bash" :: script :: args))

let copy_script src dst =
  write_executable dst (read_file src)

let make_config_root root =
  let config = Filename.concat root "config" in
  mkdir_p (Filename.concat config "prompts");
  mkdir_p (Filename.concat config "keepers");
  mkdir_p (Filename.concat config "personas");
  write_file (Filename.concat config "runtime.toml") "# repo runtime seed\n";
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
  printf 'MASC_BASE_PATH=%%s\n' "${MASC_BASE_PATH:-}"
  printf 'MASC_SIDECAR_ROOT=%%s\n' "${MASC_SIDECAR_ROOT:-}"
  printf 'MASC_CONFIG_DIR=%%s\n' "${MASC_CONFIG_DIR:-}"
  printf 'MASC_KEEPER_BOOTSTRAP_ENABLED=%%s\n' "${MASC_KEEPER_BOOTSTRAP_ENABLED:-}"
  printf 'MASC_GRPC_PORT=%%s\n' "${MASC_GRPC_PORT:-}"
  printf 'MASC_WS_PORT=%%s\n' "${MASC_WS_PORT:-}"
  printf 'MASC_WS_ENABLED=%%s\n' "${MASC_WS_ENABLED:-}"
  printf 'MASC_WEBRTC_ENABLED=%%s\n' "${MASC_WEBRTC_ENABLED:-}"
  printf 'MASC_KEEPER_HOST_FD_HOTSPOT_HEADROOM=%%s\n' "${MASC_KEEPER_HOST_FD_HOTSPOT_HEADROOM:-}"
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

let write_failing_dashboard_build_helper repo_root marker =
  let scripts_dir = Filename.concat repo_root "scripts" in
  mkdir_p scripts_dir;
  write_executable
    (Filename.concat scripts_dir "build-dashboard-if-needed.sh")
    (Printf.sprintf
       {|
#!/bin/sh
set -eu
echo ran > %s
echo dashboard build failed >&2
exit 17
|}
       (quote marker))

let write_fake_dune_stale_then_success ~path ~state_file ~clean_marker =
  write_executable path
    (Printf.sprintf
       {|
#!/bin/sh
set -eu
state=%s
clean_marker=%s
cmd="${1:-}"
case "$cmd" in
  build)
    count=0
    if [ -f "$state" ]; then
      count="$(cat "$state")"
    fi
    if [ "$count" = "0" ]; then
      echo 1 > "$state"
      echo "Error: Files lib/.masc.objs/native/masc__Keeper_context_core.cmx" >&2
      echo "       and lib/.masc.objs/native/masc__Inference_utils.cmx" >&2
      echo "       make inconsistent assumptions over implementation Agent_sdk__Context_reducer" >&2
      exit 1
    fi
    mkdir -p _build/default/bin
    cat > _build/default/bin/main_eio.exe <<'EXE'
#!/bin/sh
set -eu
{
  printf 'FAKE_EXE_MARKER=eio-after-stale-retry\n'
  printf 'PWD=%%s\n' "$(pwd)"
  printf 'ARGS=%%s\n' "$*"
} >"${FAKE_CAPTURE_FILE:?}"
exit 0
EXE
    chmod +x _build/default/bin/main_eio.exe
    echo "fake dune build recovered" >&2
    ;;
  clean)
    echo clean > "$clean_marker"
    rm -rf _build
    ;;
  *)
    echo "unexpected dune command: $*" >&2
    exit 2
    ;;
esac
|}
       (quote state_file) (quote clean_marker))

let write_fake_dune_cache_temp_then_success ~path ~state_file ~clean_marker =
  write_executable path
    (Printf.sprintf
       {|
#!/bin/sh
set -eu
state=%s
clean_marker=%s
cmd="${1:-}"
case "$cmd" in
  build)
    count=0
    if [ -f "$state" ]; then
      count="$(cat "$state")"
    fi
    if [ "$count" = "0" ]; then
      echo 1 > "$state"
      echo "Error:" >&2
      echo "rmdir(/Users/test/.cache/dune/db/temp/dune_6eb519_artifacts): Directory not empty" >&2
      exit 1
    fi
    if [ "${DUNE_CACHE:-}" != "disabled" ]; then
      echo "expected DUNE_CACHE=disabled on cache-temp retry, got ${DUNE_CACHE:-<unset>}" >&2
      exit 3
    fi
    mkdir -p _build/default/bin
    cat > _build/default/bin/main_eio.exe <<'EXE'
#!/bin/sh
set -eu
{
  printf 'FAKE_EXE_MARKER=eio-after-cache-temp-retry\n'
  printf 'PWD=%%s\n' "$(pwd)"
  printf 'ARGS=%%s\n' "$*"
} >"${FAKE_CAPTURE_FILE:?}"
exit 0
EXE
    chmod +x _build/default/bin/main_eio.exe
    echo "fake dune build recovered with cache disabled" >&2
    ;;
  clean)
    echo clean > "$clean_marker"
    ;;
  *)
    echo "unexpected dune command: $*" >&2
    exit 2
    ;;
esac
|}
       (quote state_file) (quote clean_marker))

let write_fake_dune_local ~path ~log_file =
  write_executable path
    (Printf.sprintf
       {|
#!/bin/sh
set -eu
printf 'dune-local %%s DUNE_JOBS=%%s DUNE_LOCAL_JOBS=%%s DUNE_CACHE=%%s\n' "$*" "${DUNE_JOBS:-}" "${DUNE_LOCAL_JOBS:-}" "${DUNE_CACHE:-}" >> %s
exec dune "$@"
|}
       (quote log_file))

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
      let script = Filename.concat dir "start-masc.sh" in
      copy_script (script_path ()) script;
      write_file (Filename.concat dir ".env.local")
        "MASC_WS_ENABLED=0\n";
      make_fake_eio_exe dir;
      let capture = Filename.concat dir "captured-env.txt" in
      let code, stdout, stderr =
        run_script ~cwd:dir script
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("MASC_WS_ENABLED", "1");
              ("MASC_BASE_PATH", dir);
              ("MASC_CONFIG_DIR", Filename.concat dir "config");
            ]
          [ "--http"; "--port"; "9955"; "--base-path"; dir ]
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let captured = read_file capture in
      check bool "explicit env wins over env file" true
        (contains_substring captured "MASC_WS_ENABLED=1");
      check bool "base path passed through" true
        (contains_substring captured
           ("MASC_BASE_PATH=" ^ canonical_path dir));
      check bool "explicit config dir preserved" true
        (contains_substring captured ("MASC_CONFIG_DIR=" ^ Filename.concat dir "config"));
      check bool "Docker hotspot blocking default is exported as disabled" true
        (contains_substring captured "MASC_KEEPER_HOST_FD_HOTSPOT_HEADROOM=0"))

let test_fd_hotspot_headworkspace_override_is_preserved () =
  with_temp_dir "start-masc-script" (fun dir ->
      let script = Filename.concat dir "start-masc.sh" in
      copy_script (script_path ()) script;
      make_fake_eio_exe dir;
      let capture = Filename.concat dir "captured-fd-hotspot.txt" in
      let code, stdout, stderr =
        run_script ~cwd:dir script
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("MASC_BASE_PATH", dir);
              ("MASC_KEEPER_HOST_FD_HOTSPOT_HEADROOM", "1024");
            ]
          [ "--http"; "--port"; "9973"; "--base-path"; dir ]
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let captured = read_file capture in
      check bool "explicit Docker hotspot headroom is preserved" true
        (contains_substring captured "MASC_KEEPER_HOST_FD_HOTSPOT_HEADROOM=1024"))

let test_realtime_transports_default_to_base_path_config_and_preserve_override ()
    =
  with_temp_dir "start-masc-script" (fun dir ->
      let script = Filename.concat dir "start-masc.sh" in
      copy_script (script_path ()) script;
      ignore (make_config_root dir);
      make_fake_eio_exe dir;
      let ignored_dir = Filename.concat dir "ignored" in
      mkdir_p (Filename.concat ignored_dir "config/prompts");
      write_file (Filename.concat ignored_dir "config/runtime.toml") "";
      let bootstrapped_config =
        Filename.concat (canonical_path dir) ".masc/config"
      in
      let capture_default = Filename.concat dir "captured-default.txt" in
      let code_default, stdout_default, stderr_default =
        run_script ~cwd:dir script
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture_default);
              ("HOME", ignored_dir);
              ("MASC_BASE_PATH", dir);
              ("MASC_CONFIG_DIR", "");
            ]
          [ "--http"; "--port"; "9956"; "--base-path"; dir ]
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
        (Sys.file_exists (Filename.concat bootstrapped_config "runtime.toml"));
      let capture_override = Filename.concat dir "captured-override.txt" in
      let code_override, stdout_override, stderr_override =
        run_script ~cwd:dir script
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture_override);
              ("MASC_BASE_PATH", dir);
              ("MASC_CONFIG_DIR", Filename.concat dir "custom-config");
              ("MASC_WS_ENABLED", "0");
              ("MASC_WEBRTC_ENABLED", "0");
            ]
          [ "--http"; "--port"; "9957"; "--base-path"; dir ]
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
      let script = Filename.concat dir "start-masc.sh" in
      copy_script (script_path ()) script;
      ignore (make_config_root dir);
      make_fake_eio_exe dir;
      let bootstrapped_config =
        Filename.concat (canonical_path dir) ".masc/config"
      in
      let capture = Filename.concat dir "captured-fallback.txt" in
      let code, stdout, stderr =
        run_script ~cwd:dir script
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("HOME", Filename.concat dir "empty-home");
              ("MASC_BASE_PATH", dir);
              ("MASC_CONFIG_DIR", "");
            ]
          [ "--http"; "--port"; "9959"; "--base-path"; dir ]
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code stdout stderr;
      let captured = read_file capture in
      check bool "defaults to base path config" true
        (contains_substring captured
           ("MASC_CONFIG_DIR=" ^ bootstrapped_config));
      check bool "repo config copied to base path config" true
        (Sys.file_exists (Filename.concat bootstrapped_config "runtime.toml")))

let test_default_base_path_requires_explicit_base_path () =
  with_temp_dir "start-masc-script-no-home-default" (fun dir ->
      let script = Filename.concat dir "start-masc.sh" in
      copy_script (script_path ()) script;
      ignore (make_config_root dir);
      make_fake_eio_exe dir;
      let home_dir = Filename.concat dir "home" in
      let me_root = Filename.concat home_dir "me" in
      mkdir_p me_root;
      let capture = Filename.concat dir "captured-no-home-default.txt" in
      let code, stdout, stderr =
        run_script ~cwd:dir script
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("HOME", home_dir);
              ("MASC_BASE_PATH", "");
              ("MASC_CONFIG_DIR", "");
            ]
          [ "--http"; "--port"; "9969" ]
      in
      check int "start script fails without explicit base path" 2 code;
      check bool "does not invoke server executable" false
        (Sys.file_exists capture);
      check bool "stderr names required base path" true
        (contains_substring stderr "MASC base path is required");
      check bool "stderr rejects HOME inference" true
        (contains_substring stderr "Refusing to infer a runtime root from HOME");
      ignore stdout)

let test_absolute_env_base_path_is_preserved () =
  with_temp_dir "start-masc-script" (fun dir ->
      let script = Filename.concat dir "start-masc.sh" in
      copy_script (script_path ()) script;
      make_fake_eio_exe dir;
      let stale_root = Filename.concat dir "stale-root" in
      let home_dir = Filename.concat dir "empty-home" in
      mkdir_p (Filename.concat dir Common.masc_dirname);
      mkdir_p (Filename.concat stale_root Common.masc_dirname);
      mkdir_p home_dir;
      let capture = Filename.concat dir "captured-sanitized.txt" in
      let code, stdout, stderr =
        run_script ~cwd:dir script
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("HOME", home_dir);
              ("MASC_BASE_PATH", stale_root);
            ]
          [ "--http"; "--port"; "9960" ]
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
      let repo = Filename.concat parent "workspace/yousleepwhen/masc" in
      let home_dir = Filename.concat dir "empty-home" in
      mkdir_p repo;
      mkdir_p home_dir;
      mkdir_p (Filename.concat parent Common.masc_dirname);
      mkdir_p (Filename.concat repo Common.masc_dirname);
      let script = Filename.concat repo "start-masc.sh" in
      copy_script (script_path ()) script;
      make_fake_eio_exe repo;
      let capture = Filename.concat dir "captured-parent-sanitized.txt" in
      let code, stdout, stderr =
        run_script ~cwd:repo script
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("HOME", home_dir);
              ("MASC_BASE_PATH", parent);
            ]
          [ "--http"; "--port"; "9963" ]
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
      let script = Filename.concat dir "start-masc.sh" in
      copy_script (script_path ()) script;
      make_fake_eio_exe dir;
      let base_path = Filename.concat dir "runtime-root" in
      let sidecar_root = Filename.concat dir "workspace/yousleepwhen/masc" in
      mkdir_p base_path;
      mkdir_p sidecar_root;
      let capture = Filename.concat dir "captured-sidecar-root.txt" in
      let code, stdout, stderr =
        run_script ~cwd:dir script
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("MASC_BASE_PATH", base_path);
            ]
          [
            "--http";
            "--port";
            "9970";
            "--base-path";
            base_path;
            "--sidecar-root";
            sidecar_root;
          ]
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let captured = read_file capture in
      check bool "sidecar root exported to server env" true
        (contains_substring captured
           ("MASC_SIDECAR_ROOT=" ^ canonical_path sidecar_root)))

let test_zshenv_absolute_base_path_is_ignored () =
  with_temp_dir "start-masc-script" (fun dir ->
      let parent = Filename.concat dir "parent-root" in
      let repo = Filename.concat parent "workspace/yousleepwhen/masc" in
      let home_dir = Filename.concat dir "home" in
      mkdir_p repo;
      mkdir_p home_dir;
      mkdir_p (Filename.concat parent Common.masc_dirname);
      mkdir_p (Filename.concat repo Common.masc_dirname);
      write_file (Filename.concat home_dir ".zshenv")
        (Printf.sprintf "export MASC_BASE_PATH=%s\n" parent);
      let script = Filename.concat repo "start-masc.sh" in
      copy_script (script_path ()) script;
      make_fake_eio_exe repo;
      let capture = Filename.concat dir "captured-zshenv-sanitized.txt" in
      let code, stdout, stderr =
        run_script ~cwd:repo script
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("HOME", home_dir);
            ]
          [ "--http"; "--port"; "9965" ]
      in
      let _ = stdout in
      check bool "zshenv base path alone is rejected" true (code <> 0);
      check bool "stderr rejects HOME/profile inference" true
        (contains_substring stderr
           "Refusing to infer a runtime root from HOME"))

let test_shared_root_env_base_path_is_preserved () =
  with_temp_dir "start-masc-script" (fun dir ->
      let script = Filename.concat dir "start-masc.sh" in
      copy_script (script_path ()) script;
      make_fake_eio_exe dir;
      let inherited_root = Filename.concat dir "shared-root" in
      let home_dir = Filename.concat dir "empty-home" in
      mkdir_p (Filename.concat dir Common.masc_dirname);
      mkdir_p (Filename.concat inherited_root Common.masc_dirname);
      mkdir_p home_dir;
      let capture = Filename.concat dir "captured-opt-in.txt" in
      let code, stdout, stderr =
        run_script ~cwd:dir script
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("HOME", home_dir);
              ("MASC_BASE_PATH", inherited_root);
            ]
          [ "--http"; "--port"; "9964" ]
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
      let script = Filename.concat worktree "start-masc.sh" in
      copy_script (script_path ()) script;
      let local_exe =
        Filename.concat worktree "_build/default/bin/main_eio.exe"
      in
      let workspace_exe =
        Filename.concat repo_root "_build/default/masc/bin/main_eio.exe"
      in
      write_fake_eio_exe local_exe ~marker:"local";
      write_fake_eio_exe workspace_exe ~marker:"workspace";
      let capture = Filename.concat dir "captured-pref.txt" in
      let code, stdout, stderr =
        run_script ~cwd:worktree script
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("MASC_BASE_PATH", repo_root);
            ]
          [ "--http"; "--port"; "9958"; "--base-path"; repo_root ]
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
      let repo = Filename.concat parent "workspace/yousleepwhen/masc" in
      let home_dir = Filename.concat dir "empty-home" in
      mkdir_p repo;
      mkdir_p home_dir;
      mkdir_p (Filename.concat parent Common.masc_dirname);
      mkdir_p (Filename.concat repo Common.masc_dirname);
      let script = Filename.concat repo "start-masc.sh" in
      copy_script (script_path ()) script;
      make_fake_eio_exe repo;
      let capture = Filename.concat dir "captured-explicit-cwd.txt" in
      let code, stdout, stderr =
        run_script ~cwd:repo script
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("HOME", home_dir);
              ("MASC_BASE_PATH", parent);
            ]
          [ "--http"; "--port"; "9966"; "--base-path"; parent ]
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let captured = read_file capture in
      let expected_root = canonical_path parent in
      check bool "exec cwd matches explicit base path" true
        (contains_substring captured ("PWD=" ^ expected_root)))

let test_explicit_base_path_ignores_config_from_zshenv () =
  with_temp_dir "start-masc-script" (fun dir ->
      let parent = Filename.concat dir "parent-root" in
      let repo = Filename.concat parent "workspace/yousleepwhen/masc" in
      let home_dir = Filename.concat dir "home" in
      mkdir_p repo;
      mkdir_p home_dir;
      ignore (make_config_root repo);
      write_file (Filename.concat home_dir ".zshenv")
        (Printf.sprintf
           "export MASC_CONFIG_DIR=%s\nexport MASC_PERSONAS_DIR=%s\n"
           (Filename.concat repo "config")
           (Filename.concat repo "config/personas"));
      let script = Filename.concat repo "start-masc.sh" in
      copy_script (script_path ()) script;
      make_fake_eio_exe repo;
      let capture = Filename.concat dir "captured-explicit-base-config.txt" in
      let code, stdout, stderr =
        run_script ~cwd:repo script
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("HOME", home_dir);
            ]
          [ "--http"; "--port"; "9967"; "--base-path"; parent ]
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let captured = read_file capture in
      let expected_parent = canonical_path parent in
      check bool "explicit base path resets config root to base path" true
        (contains_substring captured
           ("MASC_CONFIG_DIR=" ^ Filename.concat expected_parent ".masc/config"));
      check bool "zshenv config was not imported" false
        (contains_substring stderr "Ignoring repo-local MASC_CONFIG_DIR");
      check bool "zshenv personas were not imported" false
        (contains_substring stderr "Ignoring repo-local MASC_PERSONAS_DIR"))

let test_explicit_base_path_ignores_repo_local_config_from_parent_env () =
  with_temp_dir "start-masc-script" (fun dir ->
      let parent = Filename.concat dir "parent-root" in
      let repo = Filename.concat parent "workspace/yousleepwhen/masc" in
      mkdir_p repo;
      ignore (make_config_root repo);
      let script = Filename.concat repo "start-masc.sh" in
      copy_script (script_path ()) script;
      make_fake_eio_exe repo;
      let capture = Filename.concat dir "captured-explicit-parent-env.txt" in
      let code, stdout, stderr =
        run_script ~cwd:repo script
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("MASC_CONFIG_DIR", Filename.concat repo "config");
              ("MASC_PERSONAS_DIR", Filename.concat repo "config/personas");
            ]
          [ "--http"; "--port"; "9968"; "--base-path"; parent ]
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
      let script = Filename.concat dir "start-masc.sh" in
      copy_script (script_path ()) script;
      make_fake_eio_exe dir;
      let capture = Filename.concat dir "captured-sidecar-ports.txt" in
      let code, stdout, stderr =
        run_script ~cwd:dir script
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("MASC_BASE_PATH", dir);
            ]
          [ "--http"; "--port"; "9951"; "--base-path"; dir ]
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
      let script = Filename.concat dir "start-masc.sh" in
      copy_script (script_path ()) script;
      make_fake_eio_exe_with_stderr dir;
      let code, stdout, stderr =
        run_script ~cwd:dir script
          ~env:
            [
              ("MASC_BASE_PATH", dir);
            ]
          [ "--http"; "--port"; "9951"; "--base-path"; dir ]
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

let test_stale_dune_artifacts_are_cleaned_and_retried () =
  with_temp_dir "start-masc-script-stale-dune" (fun dir ->
      with_temp_dir "start-masc-stale-dune-fake-bin" (fun fake_bin ->
          let script = Filename.concat dir "start-masc.sh" in
          let scripts_dir = Filename.concat dir "scripts" in
          let dune_state = Filename.concat dir "dune-build-count.txt" in
          let clean_marker = Filename.concat dir "dune-clean-ran.txt" in
          let dune_local_log = Filename.concat dir "dune-local-calls.txt" in
          let capture = Filename.concat dir "captured-stale-dune.txt" in
          copy_script (script_path ()) script;
          ignore (make_config_root dir);
          mkdir_p scripts_dir;
          mkdir_p fake_bin;
          write_executable (Filename.concat fake_bin "opam")
            "#!/bin/sh\nexit 0\n";
          write_fake_dune_stale_then_success
            ~path:(Filename.concat fake_bin "dune")
            ~state_file:dune_state ~clean_marker;
          write_fake_dune_local
            ~path:(Filename.concat scripts_dir "dune-local.sh")
            ~log_file:dune_local_log;
          let code, stdout, stderr =
            run_script ~cwd:dir script
              ~env:
                [
                  ("FAKE_CAPTURE_FILE", capture);
                  ("MASC_BASE_PATH", dir);
                  ("MASC_DUNE_JOBS", "2");
                  ("PATH", fake_bin ^ ":" ^ Sys.getenv "PATH");
                ]
              [ "--http"; "--port"; "9971"; "--base-path"; dir ]
          in
          if code <> 0 then
            failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s"
              code stdout stderr;
          let captured = read_file capture in
          check bool "server started from retry-built executable" true
            (contains_substring captured
               "FAKE_EXE_MARKER=eio-after-stale-retry");
          check bool "dune clean ran before retry" true
            (Sys.file_exists clean_marker);
          let dune_local_calls = read_file dune_local_log in
          check bool "startup build uses dune-local wrapper" true
            (contains_substring dune_local_calls
               "dune-local build bin/main_eio.exe");
          check bool "startup forwards DUNE_JOBS into wrapper under CI" true
            (contains_substring dune_local_calls
               "DUNE_JOBS=2 DUNE_LOCAL_JOBS=2");
          check bool "stale cleanup uses dune-local wrapper" true
            (contains_substring dune_local_calls "dune-local clean");
          check bool "original stale artifact error preserved" true
            (contains_substring stderr
               "make inconsistent assumptions over implementation Agent_sdk__Context_reducer");
          check bool "retry is explained" true
            (contains_substring stderr
               "Stale Dune artifacts detected while building main_eio.exe");
          check bool "retry output preserved" true
            (contains_substring stderr "fake dune build recovered")))

let test_dune_cache_temp_error_retries_with_cache_disabled () =
  with_temp_dir "start-masc-script-cache-temp-dune" (fun dir ->
      with_temp_dir "start-masc-cache-temp-fake-bin" (fun fake_bin ->
          let script = Filename.concat dir "start-masc.sh" in
          let scripts_dir = Filename.concat dir "scripts" in
          let dune_state = Filename.concat dir "dune-build-count.txt" in
          let clean_marker = Filename.concat dir "dune-clean-ran.txt" in
          let dune_local_log = Filename.concat dir "dune-local-calls.txt" in
          let capture = Filename.concat dir "captured-cache-temp-dune.txt" in
          copy_script (script_path ()) script;
          ignore (make_config_root dir);
          mkdir_p scripts_dir;
          mkdir_p fake_bin;
          write_executable (Filename.concat fake_bin "opam")
            "#!/bin/sh\nexit 0\n";
          write_fake_dune_cache_temp_then_success
            ~path:(Filename.concat fake_bin "dune")
            ~state_file:dune_state ~clean_marker;
          write_fake_dune_local
            ~path:(Filename.concat scripts_dir "dune-local.sh")
            ~log_file:dune_local_log;
          let code, stdout, stderr =
            run_script ~cwd:dir script
              ~env:
                [
                  ("FAKE_CAPTURE_FILE", capture);
                  ("MASC_BASE_PATH", dir);
                  ("MASC_DUNE_JOBS", "2");
                  ("PATH", fake_bin ^ ":" ^ Sys.getenv "PATH");
                ]
              [ "--http"; "--port"; "9972"; "--base-path"; dir ]
          in
          if code <> 0 then
            failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s"
              code stdout stderr;
          let captured = read_file capture in
          check bool "server started from cache-disabled retry executable" true
            (contains_substring captured
               "FAKE_EXE_MARKER=eio-after-cache-temp-retry");
          check bool "dune clean was not used for cache temp retry" false
            (Sys.file_exists clean_marker);
          let dune_local_calls = read_file dune_local_log in
          check bool "initial startup build used cache default" true
            (contains_substring dune_local_calls
               "dune-local build bin/main_eio.exe DUNE_JOBS=2 DUNE_LOCAL_JOBS=2 DUNE_CACHE=");
          check bool "retry disabled Dune cache" true
            (contains_substring dune_local_calls
               "dune-local build bin/main_eio.exe DUNE_JOBS=2 DUNE_LOCAL_JOBS=2 DUNE_CACHE=disabled");
          check bool "original cache temp error preserved" true
            (contains_substring stderr
               "rmdir(/Users/test/.cache/dune/db/temp/dune_6eb519_artifacts): Directory not empty");
          check bool "cache retry is explained" true
            (contains_substring stderr
               "Dune cache temp cleanup failed while building main_eio.exe");
          check bool "cache retry output preserved" true
            (contains_substring stderr
               "fake dune build recovered with cache disabled")))

let test_stale_executable_requires_build_lock () =
  with_temp_dir "start-masc-script-build-lock" (fun dir ->
      with_temp_dir "start-masc-build-lock-fake-bin" (fun fake_bin ->
          let script = Filename.concat dir "start-masc.sh" in
          let lock_dir = Filename.concat dir "masc-build.lock" in
          let capture = Filename.concat dir "captured-stale-lock.txt" in
          let source = Filename.concat dir "bin/main_eio.ml" in
          copy_script (script_path ()) script;
          ignore (make_config_root dir);
          make_fake_eio_exe dir;
          mkdir_p (Filename.dirname source);
          write_file source "let () = ()\n";
          let future = Unix.time () +. 10.0 in
          Unix.utimes source future future;
          mkdir_p lock_dir;
          write_file (Filename.concat lock_dir "pid") (string_of_int (Unix.getpid ()));
          mkdir_p fake_bin;
          write_executable (Filename.concat fake_bin "dune")
            "#!/bin/sh\necho 'dune should not run while build lock is held' >&2\nexit 99\n";
          let code, _stdout, stderr =
            run_script ~cwd:dir script
              ~env:
                [
                  ("FAKE_CAPTURE_FILE", capture);
                  ("MASC_BASE_PATH", dir);
                  ("MASC_BUILD_LOCK_PATH", lock_dir);
                  ("PATH", fake_bin ^ ":" ^ Sys.getenv "PATH");
                ]
              [ "--http"; "--port"; "9972"; "--base-path"; dir ]
          in
          check bool "startup refuses stale executable when build lock is held" true
            (code <> 0);
          check bool "stale executable was not started" false
            (Sys.file_exists capture);
          check bool "lock holder is reported" true
            (contains_substring stderr "Another MASC build in progress");
	          check bool "stale executable refusal is explicit" true
	            (contains_substring stderr
	               "refusing to continue with a stale or missing executable")))

let test_default_build_lock_is_worktree_local () =
  let source = read_file (script_path ()) in
  check bool "default build lock is worktree-local" true
    (contains_substring source
       "MASC_BUILD_LOCK=\"${MASC_BUILD_LOCK_PATH:-$SCRIPT_DIR/.masc-build.lock}\"");
  check bool "default build lock is not global /tmp" false
    (contains_substring source "MASC_BUILD_LOCK_PATH:-/tmp/masc-build.lock")

let test_stdio_entrypoint_uses_shared_base_path_guard () =
  let source = read_file "bin/main_stdio_eio.ml" in
  check bool "stdio guards self repo base path" true
    (contains_substring source "Server_base_path_guard.guard_self_repo_base_path");
  check bool "stdio rejects implicit base path" true
    (contains_substring source "Server_base_path_guard.guard_implicit_base_path")

let test_stdio_skips_dashboard_build_and_http_preflight () =
  with_temp_dir "start-masc-script-stdio" (fun dir ->
      let script = Filename.concat dir "start-masc.sh" in
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
        run_script ~cwd:dir script
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("MASC_BASE_PATH", dir);
              ("PATH", fake_bin ^ ":" ^ Sys.getenv "PATH");
            ]
          [ "--stdio"; "--base-path"; dir ]
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

let test_http_dashboard_build_failure_is_non_blocking_by_default () =
  with_temp_dir "start-masc-script-dashboard-nonblocking" (fun dir ->
      let script = Filename.concat dir "start-masc.sh" in
      let dashboard_marker = Filename.concat dir "dashboard-build-ran.txt" in
      let capture = Filename.concat dir "captured-http.txt" in
      copy_script (script_path ()) script;
      ignore (make_config_root dir);
      make_fake_eio_exe dir;
      write_failing_dashboard_build_helper dir dashboard_marker;
      let code, stdout, stderr =
        run_script ~cwd:dir script
          ~env:[ ("FAKE_CAPTURE_FILE", capture); ("MASC_BASE_PATH", dir) ]
          [ "--http"; "--port"; "9956"; "--base-path"; dir ]
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let captured = read_file capture in
      check bool "HTTP server starts despite dashboard helper failure" true
        (contains_substring captured "FAKE_EXE_MARKER=local");
      check bool "dashboard build is non-blocking by default" true
        (contains_substring stderr "Background SPA build started"))

let test_http_dashboard_build_blocking_mode_fails_closed () =
  with_temp_dir "start-masc-script-dashboard-blocking" (fun dir ->
      let script = Filename.concat dir "start-masc.sh" in
      let dashboard_marker = Filename.concat dir "dashboard-build-ran.txt" in
      let capture = Filename.concat dir "captured-http.txt" in
      copy_script (script_path ()) script;
      ignore (make_config_root dir);
      make_fake_eio_exe dir;
      write_failing_dashboard_build_helper dir dashboard_marker;
      let code, _stdout, stderr =
        run_script ~cwd:dir script
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("MASC_BASE_PATH", dir);
              ("MASC_DASHBOARD_BUILD_BLOCKING", "1");
            ]
          [ "--http"; "--port"; "9957"; "--base-path"; dir ]
      in
      check bool "blocking dashboard build failure stops startup" true
        (code <> 0);
      check bool "HTTP server is not launched after blocking build failure" false
        (Sys.file_exists capture);
      check bool "blocking dashboard build is explicit in stderr" true
        (contains_substring stderr "Building SPA before server start");
      check bool "helper failure is surfaced in blocking mode" true
        (contains_substring stderr "dashboard build failed"))

let test_http_preflight_waits_for_port_to_clear_before_build () =
  with_temp_dir "start-masc-script-port-wait" (fun dir ->
      let script = Filename.concat dir "start-masc.sh" in
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
        run_script ~cwd:dir script
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture);
              ("MASC_BASE_PATH", dir);
              ("MASC_ALLOW_PORT_REUSE", "0");
              ("MASC_PORT_PREFLIGHT_WAIT_MAX_SEC", "1");
              ("PATH", fake_bin ^ ":" ^ Sys.getenv "PATH");
            ]
          [ "--http"; "--port"; "9954"; "--base-path"; dir ]
      in
      if code <> 0 then
        failf "start script failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      let captured = read_file capture in
      check bool "server started after transient port conflict" true
        (contains_substring captured "FAKE_EXE_MARKER=local");
      check bool "preflight waited before build" true
        (contains_substring stderr
           "HTTP Port 9954 in use, waiting before build/init"))

let test_loopback_disables_keeper_autoboot_by_default_and_requires_opt_in ()
    =
  with_temp_dir "start-loopback-script" (fun dir ->
      let repo_root = Filename.concat dir "repo-root" in
      let scripts_dir = Filename.concat repo_root "scripts" in
      mkdir_p scripts_dir;
      let start_script = Filename.concat repo_root "start-masc.sh" in
      let loopback_script = Filename.concat scripts_dir "start-loopback.sh" in
      copy_script (script_path ()) start_script;
      copy_script (loopback_script_path ()) loopback_script;
      write_file (Filename.concat repo_root ".env.local")
        "MASC_KEEPER_BOOTSTRAP_ENABLED=true\n";
      make_fake_eio_exe repo_root;
      let home_dir = Filename.concat dir "home" in
      let capture_default = Filename.concat dir "captured-loopback-default.txt" in
      let code_default, stdout_default, stderr_default =
        run_script ~cwd:repo_root loopback_script
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture_default);
              ("HOME", home_dir);
              ("MASC_KEEPER_BOOTSTRAP_ENABLED", "true");
            ]
          [ "--port"; "9961"; "--base-path"; repo_root ]
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
        run_script ~cwd:repo_root loopback_script
          ~env:
            [
              ("FAKE_CAPTURE_FILE", capture_override);
              ("HOME", home_dir);
              ("MASC_KEEPER_BOOTSTRAP_ENABLED", "");
            ]
          [ "--with-keeper-bootstrap"; "--port"; "9962"; "--base-path"; repo_root ]
      in
      if code_override <> 0 then
        failf "loopback script override failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code_override stdout_override stderr_override;
      let captured_override = read_file capture_override in
      check bool "loopback honors explicit keeper autoboot opt-in" true
        (contains_substring captured_override "MASC_KEEPER_BOOTSTRAP_ENABLED=true"))

let () =
  run "start_masc_script"
    [
      ( "script",
        [
          test_case "explicit env overrides repo env files" `Quick
            test_explicit_env_overrides_repo_env_files;
          test_case "FD hotspot headroom override is preserved" `Quick
            test_fd_hotspot_headworkspace_override_is_preserved;
          test_case
            "realtime transports default to base path config and preserve override"
            `Quick
            test_realtime_transports_default_to_base_path_config_and_preserve_override;
          test_case "bootstraps base path config from repo when unset" `Quick
            test_bootstraps_base_path_config_from_repo_when_unset;
          test_case "default base path requires explicit base path" `Quick
            test_default_base_path_requires_explicit_base_path;
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
            "explicit base path ignores config from zshenv"
            `Quick
            test_explicit_base_path_ignores_config_from_zshenv;
          test_case
            "explicit base path ignores repo-local config from parent env"
            `Quick
            test_explicit_base_path_ignores_repo_local_config_from_parent_env;
          test_case "explicit http port derives sidecar ports" `Quick
            test_explicit_http_port_derives_sidecar_ports;
          test_case "grpc-direct banner is preserved in stderr" `Quick
            test_grpc_direct_banner_is_preserved_in_stderr;
          test_case "stale Dune artifacts are cleaned and retried" `Quick
            test_stale_dune_artifacts_are_cleaned_and_retried;
          test_case "Dune cache temp errors retry with cache disabled" `Quick
            test_dune_cache_temp_error_retries_with_cache_disabled;
	          test_case "stale executable requires build lock" `Quick
	            test_stale_executable_requires_build_lock;
	          test_case "default build lock is worktree-local" `Quick
	            test_default_build_lock_is_worktree_local;
	          test_case "stdio entrypoint uses shared base path guard" `Quick
	            test_stdio_entrypoint_uses_shared_base_path_guard;
	          test_case "stdio skips dashboard build and HTTP preflight" `Quick
            test_stdio_skips_dashboard_build_and_http_preflight;
          test_case
            "dashboard build failure is non-blocking by default in HTTP mode"
            `Quick
            test_http_dashboard_build_failure_is_non_blocking_by_default;
          test_case
            "dashboard build failure stops startup in explicit blocking mode"
            `Quick test_http_dashboard_build_blocking_mode_fails_closed;
          test_case "HTTP preflight waits for transient port conflict" `Quick
            test_http_preflight_waits_for_port_to_clear_before_build;
          test_case "zshenv absolute base path is ignored" `Quick
            test_zshenv_absolute_base_path_is_ignored;
          test_case "shared-root env base path is preserved" `Quick
            test_shared_root_env_base_path_is_preserved;
          test_case "worktree prefers local build over workspace build" `Quick
            test_worktree_prefers_local_build_over_workspace_build;
          test_case
            "loopback disables keeper autoboot by default and requires opt-in"
            `Quick
            test_loopback_disables_keeper_autoboot_by_default_and_requires_opt_in;
        ] );
    ]
