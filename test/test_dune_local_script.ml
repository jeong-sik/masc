open Alcotest

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

let dune_local_script_path () =
  Filename.concat (Filename.concat (source_root ()) "scripts") "dune-local.sh"

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

let substring_index haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop idx =
    if nlen = 0 then Some 0
    else if idx + nlen > hlen then None
    else if String.sub haystack idx nlen = needle then Some idx
    else loop (idx + 1)
  in
  loop 0

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

let write_executable path content =
  write_file path content;
  Unix.chmod path 0o755

let rec mkdir_p path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
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
    end else Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_dir prefix "" in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let run_shell ?(env = []) ?(unset_env = []) ~cwd cmd =
  let unset_prefix =
    unset_env
    |> List.map (fun name -> Printf.sprintf "-u %s" (quote name))
    |> String.concat " "
  in
  let env_prefix =
    env
    |> List.map (fun (k, v) -> Printf.sprintf "%s=%s" k (quote v))
    |> String.concat " "
  in
  let shell_prefix =
    match (String.trim unset_prefix, String.trim env_prefix) with
    | "", "" -> ""
    | up, "" -> Printf.sprintf "env %s" up
    | "", ep -> ep
    | up, ep -> Printf.sprintf "env %s %s" up ep
  in
  let full =
    if shell_prefix = "" then Printf.sprintf "cd %s && %s" (quote cwd) cmd
    else Printf.sprintf "cd %s && %s %s" (quote cwd) shell_prefix cmd
  in
  let out = Filename.temp_file "dune-local-out" ".txt" in
  let err = Filename.temp_file "dune-local-err" ".txt" in
  let wrapped = Printf.sprintf "%s > %s 2> %s" full (quote out) (quote err) in
  let code = Sys.command wrapped in
  let stdout = read_file out in
  let stderr = read_file err in
  Sys.remove out;
  Sys.remove err;
  (code, stdout, stderr)

(** Set up a minimal fake repo under [base]:
    - scripts/dune-local.sh  (copy of real script)
    - scripts/check-oas-pin.sh  (caller-supplied fake)
    - bin/dune  (fake: logs invocations, exits 0)
    - bin/opam  (fake: exists, exits 0)

    Returns [(bin_dir, dune_log)] where [dune_log] records each dune call. *)
let setup_fake_repo base ~pin_check_exit_code ~pin_check_stderr_msg =
  let scripts_dir = Filename.concat base "scripts" in
  let bin_dir = Filename.concat base "bin" in
  mkdir_p scripts_dir;
  mkdir_p bin_dir;
  (* Real dune-local.sh *)
  write_executable
    (Filename.concat scripts_dir "dune-local.sh")
    (read_file (dune_local_script_path ()));
  (* Fake check-oas-pin.sh — honours --local-only but ignores it *)
  let pin_check_content =
    Printf.sprintf
      {|#!/usr/bin/env bash
if [ %d -ne 0 ]; then
  printf '%%s\n' %s >&2
  exit %d
fi
printf 'OAS pin verified: main@e3e6683\n'
exit 0
|}
      pin_check_exit_code
      (quote pin_check_stderr_msg)
      pin_check_exit_code
  in
  write_executable (Filename.concat scripts_dir "check-oas-pin.sh") pin_check_content;
  (* Fake opam: present in PATH and echoes back the queried package
     for `opam list --installed --short PKG` so the deps-installed
     guard treats core deps (httpun/agent_sdk/...) as present.  Other
     subcommands return 0 with empty stdout. *)
  write_executable (Filename.concat bin_dir "opam")
    {|#!/bin/sh
if [ "$1" = "list" ] && [ "$2" = "--installed" ] && [ -n "$4" ]; then
  printf '%s\n' "$4"; exit 0
fi
if [ "$1" = "switch" ] && [ "$2" = "show" ]; then printf 'fake-switch\n'; exit 0; fi
exit 0
|};
  (* Fake dune: log subcommand and exit 0 *)
  let dune_log = Filename.concat base "dune-calls.log" in
  write_executable
    (Filename.concat bin_dir "dune")
    (Printf.sprintf
       {|#!/bin/sh
if [ "${1:-}" = "--version" ]; then printf '3.21.0\n'; exit 0; fi
printf '%%s\n' "${1:-build}" >> %s
exit 0
|}
       (quote dune_log));
  (bin_dir, dune_log)

(** Run [scripts/dune-local.sh] from [base] with fake bin/ prepended to PATH.
    [GIT_CEILING_DIRECTORIES] is set to [base] so that git cannot climb above
    the temp dir to find the real repository, making repo_root fall back to
    the temp dir via the [|| pwd] branch in the script.
    [DUNE_LOCAL_LOCK] is set to a per-test lock file to avoid contention with
    any concurrently running real dune invocations. *)
let run_dune_local base bin_dir ?(env = []) ?(unset_env = []) subcommand =
  let system_path =
    match Sys.getenv_opt "PATH" with Some p -> p | None -> "/usr/bin:/bin"
  in
  let path = Printf.sprintf "%s:%s" bin_dir system_path in
  let lock_path = Filename.concat base "dune-local.lock" in
  let opam_lock_path = Filename.concat base "opam-switch.lock" in
  let full_env =
    [
      ("PATH", path);
      ("GIT_CEILING_DIRECTORIES", base);
      ("DUNE_LOCAL_LOCK", lock_path);
      ("MASC_OPAM_LOCK_PATH", opam_lock_path);
    ]
    @ List.filter
        (fun (k, _) ->
          k <> "PATH" && k <> "GIT_CEILING_DIRECTORIES" && k <> "DUNE_LOCAL_LOCK")
        env
  in
  let script = Filename.concat (Filename.concat base "scripts") "dune-local.sh" in
  run_shell ~cwd:base ~env:full_env ~unset_env
    (Printf.sprintf "bash %s %s" (quote script) subcommand)

(* --- tests ------------------------------------------------------------ *)

let test_pin_drift_aborts_build () =
  with_temp_dir "dune-local-pin-drift" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:1
          ~pin_check_stderr_msg:
            "agent_sdk pin source does not match SSOT\nrepair: bash scripts/opam-pin-external-deps.sh"
      in
      let code, _stdout, stderr =
        run_dune_local dir bin_dir
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_SKIP_PIN_CHECK" ]
          "build"
      in
      check int "exits non-zero on pin drift" 1 code;
      check bool "drift message present" true
        (contains_substring stderr "pin drift detected");
      check bool "repair hint present" true
        (contains_substring stderr "opam-pin-external-deps.sh");
      check bool "skip hint present" true
        (contains_substring stderr "MASC_SKIP_PIN_CHECK=1");
      check bool "dune not invoked" false (Sys.file_exists dune_log))

let test_skip_pin_check_env_bypasses_guard () =
  with_temp_dir "dune-local-skip-pin" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:1
          ~pin_check_stderr_msg:"pin mismatch"
      in
      let code, _stdout, _stderr =
        run_dune_local dir bin_dir
          ~env:[ ("MASC_SKIP_PIN_CHECK", "1") ]
          ~unset_env:[ "GITHUB_ACTIONS" ]
          "build"
      in
      check int "exits zero when MASC_SKIP_PIN_CHECK=1" 0 code;
      check bool "dune was invoked" true (Sys.file_exists dune_log))

let test_github_actions_bypasses_pin_guard () =
  with_temp_dir "dune-local-ci-bypass" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:1
          ~pin_check_stderr_msg:"pin mismatch"
      in
      let code, _stdout, _stderr =
        run_dune_local dir bin_dir
          ~env:[ ("GITHUB_ACTIONS", "true") ]
          ~unset_env:[ "MASC_SKIP_PIN_CHECK" ]
          "build"
      in
      check int "exits zero when GITHUB_ACTIONS=true" 0 code;
      check bool "dune was invoked" true (Sys.file_exists dune_log))

let test_opam_absent_skips_pin_guard () =
  with_temp_dir "dune-local-no-opam" (fun dir ->
      (* Set up repo with failing pin check but no fake opam in PATH *)
      let scripts_dir = Filename.concat dir "scripts" in
      let bin_dir = Filename.concat dir "bin" in
      mkdir_p scripts_dir;
      mkdir_p bin_dir;
      write_executable
        (Filename.concat scripts_dir "dune-local.sh")
        (read_file (dune_local_script_path ()));
      (* Failing pin check: should never be called when opam is absent *)
      write_executable
        (Filename.concat scripts_dir "check-oas-pin.sh")
        "#!/bin/sh\necho 'pin mismatch' >&2\nexit 1\n";
      let dune_log = Filename.concat dir "dune-calls.log" in
      write_executable
        (Filename.concat bin_dir "dune")
        (Printf.sprintf
           {|#!/bin/sh
if [ "${1:-}" = "--version" ]; then printf '3.21.0\n'; exit 0; fi
printf '%%s\n' "${1:-build}" >> %s
exit 0
|}
           (quote dune_log));
      let opam_lock_path = Filename.concat dir "opam.lock" in
      let lockf_log = Filename.concat dir "lockf-calls.log" in
      write_executable
        (Filename.concat bin_dir "lockf")
        (Printf.sprintf
           {|#!/bin/sh
printf 'argv=%%s\n' "$*" >> %s
while [ "${1#-}" != "$1" ]; do
  case "$1" in
    -t) shift 2 ;;
    *) shift ;;
  esac
done
lock_path="$1"
printf 'lock=%%s\n' "$lock_path" >> %s
if [ "$lock_path" = %s ]; then exit 97; fi
shift
exec "$@"
|}
           (quote lockf_log) (quote lockf_log) (quote opam_lock_path));
      (* Use a minimal PATH (no opam install directories) so that
         'command -v opam' fails and the guard is skipped.
         opam is typically in ~/.opam/SWITCH/bin/, not in /usr/bin or /bin. *)
      let minimal_path = Printf.sprintf "%s:/usr/bin:/bin" bin_dir in
      let lock_path = Filename.concat dir "dune-local.lock" in
      let code, _stdout, _stderr =
        run_shell ~cwd:dir
          ~env:
            [
              ("PATH", minimal_path);
              ("GIT_CEILING_DIRECTORIES", dir);
              ("DUNE_LOCAL_LOCK", lock_path);
              ("MASC_OPAM_LOCK_PATH", opam_lock_path);
            ]
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_SKIP_PIN_CHECK" ]
          (Printf.sprintf "bash %s build"
             (quote (Filename.concat scripts_dir "dune-local.sh")))
      in
      check int "exits zero when opam absent" 0 code;
      let lock_log =
        if Sys.file_exists lockf_log then read_file lockf_log else ""
      in
      check bool "opam lockf not invoked" false
        (contains_substring lock_log opam_lock_path);
      check bool "dune was invoked" true (Sys.file_exists dune_log))

let test_opam_lockf_reexec_env_passthrough () =
  with_temp_dir "dune-local-opam-lockf" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:0
          ~pin_check_stderr_msg:"pin ok"
      in
      let lockf_log = Filename.concat dir "lockf-calls.log" in
      write_executable
        (Filename.concat bin_dir "lockf")
        (Printf.sprintf
           {|#!/bin/sh
printf 'held=%%s argv=%%s\n' "${MASC_OPAM_LOCK_HELD:-unset}" "$*" >> %s
while [ "${1#-}" != "$1" ]; do
  case "$1" in
    -t) shift 2 ;;
    *) shift ;;
  esac
done
shift
exec "$@"
|}
           (quote lockf_log));
      let opam_lock_path = Filename.concat dir "opam.lock" in
      let code, _stdout, _stderr =
        run_dune_local dir bin_dir
          ~env:[ ("MASC_OPAM_LOCK_PATH", opam_lock_path) ]
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_OPAM_LOCK_HELD" ]
          "build"
      in
      check int "exits zero through lockf reexec" 0 code;
      check bool "lockf invoked" true (Sys.file_exists lockf_log);
      let lock_log = read_file lockf_log in
      let dune_lock_path = Filename.concat dir "dune-local.lock" in
      check bool "lock path passed to lockf" true
        (contains_substring lock_log opam_lock_path);
      check bool "dune lock acquired before opam lock" true
        (match
           ( substring_index lock_log dune_lock_path,
             substring_index lock_log opam_lock_path )
         with
        | Some dune_pos, Some opam_pos -> dune_pos < opam_pos
        | _ -> false);
      check bool "held env passed through argv" true
        (contains_substring lock_log "MASC_OPAM_LOCK_HELD=1");
      check bool "dune held env passed through argv" true
        (contains_substring lock_log "MASC_DUNE_LOCK_HELD=1");
      check bool "dune was invoked after reexec" true
        (Sys.file_exists dune_log))

let test_opam_lock_timeout_releases_dune_lock () =
  with_temp_dir "dune-local-opam-lock-timeout" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:0
          ~pin_check_stderr_msg:"pin ok"
      in
      let lockf_log = Filename.concat dir "lockf-calls.log" in
      let opam_lock_path = Filename.concat dir "opam.lock" in
      write_executable
        (Filename.concat bin_dir "lockf")
        (Printf.sprintf
           {|#!/bin/sh
printf 'argv=%%s\n' "$*" >> %s
while [ "${1#-}" != "$1" ]; do
  case "$1" in
    -t) shift 2 ;;
    *) shift ;;
  esac
done
lock_path="$1"
printf 'lock=%%s\n' "$lock_path" >> %s
if [ "$lock_path" = %s ]; then exit 75; fi
shift
exec "$@"
|}
           (quote lockf_log) (quote lockf_log) (quote opam_lock_path));
      let code, _stdout, stderr =
        run_dune_local dir bin_dir
          ~env:
            [
              ("MASC_OPAM_LOCK_PATH", opam_lock_path);
              ("MASC_OPAM_LOCK_AFTER_DUNE_TIMEOUT", "1");
            ]
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_OPAM_LOCK_HELD" ]
          "build"
      in
      check int "opam lock timeout exits with lockf status" 75 code;
      check bool "timeout explains Dune lock release" true
        (contains_substring stderr "releasing Dune lock");
      check bool "dune was not invoked after opam timeout" false
        (Sys.file_exists dune_log))

let test_unset_opam_lock_timeout_waits_forever () =
  with_temp_dir "dune-local-opam-lock-timeout-unset" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:0
          ~pin_check_stderr_msg:"pin ok"
      in
      let lockf_log = Filename.concat dir "lockf-calls.log" in
      write_executable
        (Filename.concat bin_dir "lockf")
        (Printf.sprintf
           {|#!/bin/sh
printf 'argv=%%s\n' "$*" >> %s
while [ "${1#-}" != "$1" ]; do
  case "$1" in
    -t) printf 'timeout=%%s\n' "$2" >> %s; exit 98 ;;
    *) shift ;;
  esac
done
shift
exec "$@"
|}
           (quote lockf_log) (quote lockf_log));
      let code, _stdout, stderr =
        run_dune_local dir bin_dir
          ~unset_env:
            [
              "GITHUB_ACTIONS";
              "MASC_OPAM_LOCK_HELD";
              "MASC_OPAM_LOCK_AFTER_DUNE_TIMEOUT";
            ]
          "build"
      in
      check int "unset timeout keeps historical wait-forever path" 0 code;
      let lock_log = read_file lockf_log in
      check bool "lockf timeout flag not used by default" false
        (contains_substring lock_log "timeout=");
      check bool "timeout message not emitted" false
        (contains_substring stderr "releasing Dune lock");
      check bool "dune was invoked" true (Sys.file_exists dune_log))

let test_opam_lockf_wrapped_failure_does_not_claim_timeout () =
  with_temp_dir "dune-local-opam-lock-wrapped-failure" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:42
          ~pin_check_stderr_msg:"pin check failed after opam lock"
      in
      write_executable
        (Filename.concat bin_dir "lockf")
        {|#!/bin/sh
while [ "${1#-}" != "$1" ]; do
  case "$1" in
    -t) shift 2 ;;
    *) shift ;;
  esac
done
shift
exec "$@"
|};
      let code, _stdout, stderr =
        run_dune_local dir bin_dir
          ~env:[ ("MASC_OPAM_LOCK_AFTER_DUNE_TIMEOUT", "1") ]
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_OPAM_LOCK_HELD" ]
          "build"
      in
      check int "wrapped command status propagates" 1 code;
      check bool "timeout message suppressed for wrapped failure" false
        (contains_substring stderr "releasing Dune lock");
      check bool "dune was not invoked after pin failure" false
        (Sys.file_exists dune_log))

let test_opam_lock_timeout_env_must_be_numeric () =
  with_temp_dir "dune-local-opam-timeout-invalid" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:0
          ~pin_check_stderr_msg:"pin ok"
      in
      write_executable (Filename.concat bin_dir "lockf")
        {|#!/bin/sh
while [ "${1#-}" != "$1" ]; do
  case "$1" in
    -t) shift 2 ;;
    *) shift ;;
  esac
done
shift
exec "$@"
|};
      let code, _stdout, stderr =
        run_dune_local dir bin_dir
          ~env:[ ("MASC_OPAM_LOCK_AFTER_DUNE_TIMEOUT", "abc") ]
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_OPAM_LOCK_HELD" ]
          "build"
      in
      check int "invalid timeout exits usage error" 2 code;
      check bool "invalid timeout named" true
        (contains_substring stderr "invalid MASC_OPAM_LOCK_AFTER_DUNE_TIMEOUT");
      check bool "dune was not invoked" false (Sys.file_exists dune_log))

let test_missing_lock_tools_warn_once () =
  with_temp_dir "dune-local-no-lock-tools" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:0
          ~pin_check_stderr_msg:"pin ok"
      in
      write_executable (Filename.concat bin_dir "dirname")
        {|#!/bin/sh
case "$1" in
  */*) printf '%s\n' "${1%/*}" ;;
  *) printf '.\n' ;;
esac
|};
      write_executable (Filename.concat bin_dir "basename")
        {|#!/bin/sh
base="${1##*/}"
printf '%s\n' "$base"
|};
      let opam_path = Filename.concat bin_dir "opam" in
      let script =
        Filename.concat (Filename.concat dir "scripts") "dune-local.sh"
      in
      let code, _stdout, stderr =
        run_shell ~cwd:dir
          ~env:
            [
              ("PATH", bin_dir);
              ("GIT_CEILING_DIRECTORIES", dir);
              ("DUNE_LOCAL_LOCK", Filename.concat dir "dune-local.lock");
              ("MASC_SKIP_PIN_CHECK", "1");
              ("MASC_SKIP_DEPS_CHECK", "1");
              ("MASC_SKIP_OCAML_VERSION_CHECK", "1");
            ]
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_DUNE_LOCK_HELD" ]
          (Printf.sprintf "/bin/bash %s build" (quote script))
      in
      let needle = "neither lockf nor flock found; running unlocked" in
      let only_once =
        match substring_index stderr needle with
        | None -> false
        | Some idx ->
            let start = idx + String.length needle in
            let tail = String.sub stderr start (String.length stderr - start) in
            substring_index tail needle = None
      in
      check int "no-lock-tools run exits zero" 0 code;
      check bool "fake opam kept in PATH" true (Sys.file_exists opam_path);
      check bool "warning emitted exactly once" true only_once;
      check bool "opam lock warning suppressed" false
        (contains_substring stderr
           "neither lockf nor flock found; opam switch checks are unlocked");
      check bool "dune was invoked" true (Sys.file_exists dune_log))

let test_opam_flock_reexec_env_passthrough () =
  with_temp_dir "dune-local-opam-flock" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:0
          ~pin_check_stderr_msg:"pin ok"
      in
      write_executable (Filename.concat bin_dir "dirname")
        {|#!/bin/sh
case "$1" in
  */*) printf '%s\n' "${1%/*}" ;;
  *) printf '.\n' ;;
esac
|};
      write_executable (Filename.concat bin_dir "basename")
        {|#!/bin/sh
base="${1##*/}"
printf '%s\n' "$base"
|};
      let flock_log = Filename.concat dir "flock-calls.log" in
      write_executable
        (Filename.concat bin_dir "flock")
        (Printf.sprintf
           {|#!/bin/sh
printf 'held=%%s argv=%%s\n' "${MASC_OPAM_LOCK_HELD:-unset}" "$*" >> %s
shift
if [ "${1:-}" = "env" ]; then
  shift
  export "$1"
  shift
fi
exec "$@"
|}
           (quote flock_log));
      let opam_lock_path = Filename.concat dir "opam.lock" in
      let dune_lock_path = Filename.concat dir "dune-local.lock" in
      let code, _stdout, _stderr =
        run_shell ~cwd:dir
          ~env:
            [
              ("PATH", Printf.sprintf "%s:/bin" bin_dir);
              ("GIT_CEILING_DIRECTORIES", dir);
              ("DUNE_LOCAL_LOCK", dune_lock_path);
              ("MASC_OPAM_LOCK_PATH", opam_lock_path);
              ("MASC_SKIP_DEPS_CHECK", "1");
              ("MASC_SKIP_OCAML_VERSION_CHECK", "1");
            ]
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_OPAM_LOCK_HELD" ]
          (Printf.sprintf "bash %s build"
             (quote
                (Filename.concat
                   (Filename.concat dir "scripts")
                   "dune-local.sh")))
      in
      check int "exits zero through flock reexec" 0 code;
      check bool "flock invoked" true (Sys.file_exists flock_log);
      let lock_log = read_file flock_log in
      check bool "lock path passed to flock" true
        (contains_substring lock_log opam_lock_path);
      check bool "held env passed through argv" true
        (contains_substring lock_log "MASC_OPAM_LOCK_HELD=1");
      check bool "dune was invoked after flock reexec" true
        (Sys.file_exists dune_log))

let test_opam_flock_timeout_releases_dune_lock () =
  with_temp_dir "dune-local-opam-flock-timeout" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:0
          ~pin_check_stderr_msg:"pin ok"
      in
      write_executable (Filename.concat bin_dir "dirname")
        {|#!/bin/sh
case "$1" in
  */*) printf '%s\n' "${1%/*}" ;;
  *) printf '.\n' ;;
esac
|};
      write_executable (Filename.concat bin_dir "basename")
        {|#!/bin/sh
base="${1##*/}"
printf '%s\n' "$base"
|};
      let flock_log = Filename.concat dir "flock-calls.log" in
      let opam_lock_path = Filename.concat dir "opam.lock" in
      let dune_lock_path = Filename.concat dir "dune-local.lock" in
      write_executable
        (Filename.concat bin_dir "flock")
        (Printf.sprintf
           {|#!/bin/sh
printf 'argv=%%s\n' "$*" >> %s
timeout=""
while [ "${1#-}" != "$1" ]; do
  case "$1" in
    -w) timeout="$2"; shift 2 ;;
    *) shift ;;
  esac
done
lock_path="$1"
printf 'lock=%%s timeout=%%s\n' "$lock_path" "$timeout" >> %s
if [ "$lock_path" = %s ] && [ -n "$timeout" ]; then exit 1; fi
shift
if [ "${1:-}" = "env" ]; then
  shift
  export "$1"
  shift
fi
exec "$@"
|}
           (quote flock_log) (quote flock_log) (quote opam_lock_path));
      let code, _stdout, stderr =
        run_shell ~cwd:dir
          ~env:
            [
              ("PATH", Printf.sprintf "%s:/bin" bin_dir);
              ("GIT_CEILING_DIRECTORIES", dir);
              ("DUNE_LOCAL_LOCK", dune_lock_path);
              ("MASC_OPAM_LOCK_PATH", opam_lock_path);
              ("MASC_OPAM_LOCK_AFTER_DUNE_TIMEOUT", "2");
              ("MASC_SKIP_DEPS_CHECK", "1");
              ("MASC_SKIP_OCAML_VERSION_CHECK", "1");
            ]
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_OPAM_LOCK_HELD" ]
          (Printf.sprintf "bash %s build"
             (quote
                (Filename.concat
                   (Filename.concat dir "scripts")
                   "dune-local.sh")))
      in
      check int "opam flock timeout exits with flock status" 1 code;
      let lock_log = read_file flock_log in
      check bool "flock timeout flag used" true
        (contains_substring lock_log "timeout=2");
      check bool "timeout explains Dune lock release" true
        (contains_substring stderr "releasing Dune lock");
      check bool "dune was not invoked after opam timeout" false
        (Sys.file_exists dune_log))

let test_clean_subcommand_skips_pin_guard () =
  with_temp_dir "dune-local-clean" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:1
          ~pin_check_stderr_msg:"pin mismatch"
      in
      let code, _stdout, _stderr =
        run_dune_local dir bin_dir
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_SKIP_PIN_CHECK" ]
          "clean"
      in
      check int "exits zero for clean subcommand" 0 code;
      check bool "dune was invoked" true (Sys.file_exists dune_log))

(* PR #13117 review (P2): the original guards checked args[0], so prefixing
   global options like `--root .` before `clean` misclassified the call as
   a non-clean target and ran pin/deps/ocaml-version guards on a target
   that does not compile.  Pin the new subcommand-detection helper so
   guard-skipping still kicks in. *)
let test_clean_subcommand_with_global_flag_skips_pin_guard () =
  with_temp_dir "dune-local-clean-flag" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:1
          ~pin_check_stderr_msg:"pin mismatch"
      in
      let code, _stdout, _stderr =
        run_dune_local dir bin_dir
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_SKIP_PIN_CHECK" ]
          "--root . clean"
      in
      check int
        "exits zero for `--root . clean` even when pin guard would fail"
        0 code;
      check bool "dune was invoked" true (Sys.file_exists dune_log))

let test_clean_subcommand_with_eq_flag_skips_pin_guard () =
  with_temp_dir "dune-local-clean-eq-flag" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:1
          ~pin_check_stderr_msg:"pin mismatch"
      in
      let code, _stdout, _stderr =
        run_dune_local dir bin_dir
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_SKIP_PIN_CHECK" ]
          "--display=quiet clean"
      in
      check int
        "exits zero for `--display=quiet clean` even when pin guard would fail"
        0 code;
      check bool "dune was invoked" true (Sys.file_exists dune_log))

(* Codex-connector follow-ups (#13117, 2026-05-05):
   - `--auto-promote` is a BOOLEAN common option (no arg).  Treating
     it as value-taking made `--auto-promote clean` skip both tokens
     and fall back to `build`.
   - `-p PACKAGES` and `-x VAL` are SHORT value-taking common
     options; the original `[[ "$a" == -* ]]` fallback consumed
     only the flag and misread the value as the subcommand. *)
let test_clean_subcommand_after_auto_promote_skips_pin_guard () =
  with_temp_dir "dune-local-clean-auto-promote" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:1
          ~pin_check_stderr_msg:"pin mismatch"
      in
      let code, _stdout, _stderr =
        run_dune_local dir bin_dir
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_SKIP_PIN_CHECK" ]
          "--auto-promote clean"
      in
      check int
        "`--auto-promote clean` (boolean flag, NOT value-taking) skips guards"
        0 code;
      check bool "dune was invoked" true (Sys.file_exists dune_log))

let test_clean_subcommand_after_short_packages_flag_skips_pin_guard () =
  with_temp_dir "dune-local-clean-short-p" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:1
          ~pin_check_stderr_msg:"pin mismatch"
      in
      let code, _stdout, _stderr =
        run_dune_local dir bin_dir
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_SKIP_PIN_CHECK" ]
          "-p mypkg clean"
      in
      check int
        "`-p mypkg clean` (short value-taking flag) skips guards"
        0 code;
      check bool "dune was invoked" true (Sys.file_exists dune_log))

let test_clean_subcommand_after_short_x_flag_skips_pin_guard () =
  with_temp_dir "dune-local-clean-short-x" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:1
          ~pin_check_stderr_msg:"pin mismatch"
      in
      let code, _stdout, _stderr =
        run_dune_local dir bin_dir
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_SKIP_PIN_CHECK" ]
          "-x dev clean"
      in
      check int "`-x dev clean` (short value-taking flag) skips guards" 0
        code;
      check bool "dune was invoked" true (Sys.file_exists dune_log))

let test_clean_subcommand_after_cache_storage_mode_skips_pin_guard () =
  with_temp_dir "dune-local-clean-cache-storage-mode" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:1
          ~pin_check_stderr_msg:"pin mismatch"
      in
      let code, _stdout, _stderr =
        run_dune_local dir bin_dir
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_SKIP_PIN_CHECK" ]
          "--cache-storage-mode copy clean"
      in
      check int
        "`--cache-storage-mode copy clean` (value-taking flag) skips guards"
        0 code;
      check bool "dune was invoked" true (Sys.file_exists dune_log))

let test_clean_subcommand_after_cache_check_probability_skips_pin_guard () =
  with_temp_dir "dune-local-clean-cache-check-probability" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:1
          ~pin_check_stderr_msg:"pin mismatch"
      in
      let code, _stdout, _stderr =
        run_dune_local dir bin_dir
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_SKIP_PIN_CHECK" ]
          "--cache-check-probability 0.5 clean"
      in
      check int
        "`--cache-check-probability 0.5 clean` (value-taking flag) skips guards"
        0 code;
      check bool "dune was invoked" true (Sys.file_exists dune_log))

let test_pin_ok_build_proceeds () =
  with_temp_dir "dune-local-pin-ok" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:0 ~pin_check_stderr_msg:""
      in
      let code, _stdout, stderr =
        run_dune_local dir bin_dir
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_SKIP_PIN_CHECK" ]
          "build"
      in
      check int "exits zero when pin OK" 0 code;
      check bool "dune was invoked" true (Sys.file_exists dune_log);
      check bool "pin OK message present" true
        (contains_substring stderr "agent_sdk pin OK"))

let test_dry_run_skips_pin_check () =
  with_temp_dir "dune-local-dry-run" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:1
          ~pin_check_stderr_msg:"pin mismatch"
      in
      let code, _stdout, _stderr =
        run_dune_local dir bin_dir
          ~env:[ ("MASC_DUNE_DRY_RUN", "1") ]
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_SKIP_PIN_CHECK" ]
          "build"
      in
      check int "exits zero for dry run" 0 code;
      check bool "dune not actually invoked" false (Sys.file_exists dune_log))

(* --- deps guard tests (#13117 review) ---------------------------------
   Helper: fake a missing-deps environment by overriding [opam] in PATH
   with one that responds to [list --installed --short <pkg>] with an
   empty body (the case the guard is supposed to catch).  pin check
   passes so the test isolates the deps-guard branch. *)

let setup_repo_with_missing_deps base =
  let bin_dir, dune_log = setup_fake_repo base ~pin_check_exit_code:0
                            ~pin_check_stderr_msg:"" in
  let opam_path = Filename.concat bin_dir "opam" in
  let opam_script =
    {|#!/bin/sh
case "$1 $2 $3" in
  "list --installed")
    case "$5" in
      *) ;;
    esac
    exit 0 ;;
  "switch show "*) printf 'fake-switch\n' ;;
esac
exit 0
|}
  in
  write_executable opam_path opam_script;
  (bin_dir, dune_log)

let test_missing_deps_aborts_build () =
  with_temp_dir "dune-local-missing-deps" (fun dir ->
    let bin_dir, dune_log = setup_repo_with_missing_deps dir in
    let code, _stdout, stderr =
      run_dune_local dir bin_dir
        ~unset_env:[ "GITHUB_ACTIONS"; "MASC_SKIP_PIN_CHECK"; "MASC_SKIP_DEPS_CHECK" ]
        "build"
    in
    check int "exits non-zero on missing deps" 1 code;
    check bool "missing deps message present" true
      (contains_substring stderr "missing opam packages");
    check bool "repair hint present" true
      (contains_substring stderr "opam install . --deps-only");
    check bool "skip hint present" true
      (contains_substring stderr "MASC_SKIP_DEPS_CHECK=1");
    check bool "dune not invoked" false (Sys.file_exists dune_log))

let test_skip_deps_check_env_bypasses_guard () =
  with_temp_dir "dune-local-skip-deps" (fun dir ->
    let bin_dir, dune_log = setup_repo_with_missing_deps dir in
    let code, _stdout, _stderr =
      run_dune_local dir bin_dir
        ~env:[ ("MASC_SKIP_DEPS_CHECK", "1") ]
        ~unset_env:[ "GITHUB_ACTIONS"; "MASC_SKIP_PIN_CHECK" ]
        "build"
    in
    check int "exits zero when MASC_SKIP_DEPS_CHECK=1" 0 code;
    check bool "dune was invoked" true (Sys.file_exists dune_log))

(* --- OCaml minimum version guard tests (#13117 review) ---------------- *)

let setup_repo_with_old_ocaml base =
  let bin_dir, dune_log = setup_fake_repo base ~pin_check_exit_code:0
                            ~pin_check_stderr_msg:"" in
  (* opam list --installed --short returns the dep so deps-guard passes;
     we test the OCaml branch in isolation. *)
  let opam_path = Filename.concat bin_dir "opam" in
  let opam_script =
    {|#!/bin/sh
# Echo back the requested package name for `opam list --installed --short PKG`
# (args: $1=list $2=--installed $3=--short $4=PKG) so the deps-installed
# guard sees every package as present and we can isolate the OCaml-version
# branch in this fixture.
if [ "$1" = "list" ] && [ "$2" = "--installed" ] && [ -n "$4" ]; then
  printf '%s\n' "$4"; exit 0
fi
if [ "$1" = "switch" ] && [ "$2" = "show" ]; then printf 'fake-switch\n'; exit 0; fi
exit 0
|}
  in
  write_executable opam_path opam_script;
  (* Fake ocaml that reports an old version. *)
  let ocaml_path = Filename.concat bin_dir "ocaml" in
  write_executable ocaml_path
    "#!/bin/sh\nif [ \"$1\" = \"-version\" ]; then printf 'The OCaml toplevel, version 5.0.0\\n'; fi\nexit 0\n";
  (bin_dir, dune_log)

let test_old_ocaml_aborts_build () =
  with_temp_dir "dune-local-old-ocaml" (fun dir ->
    let bin_dir, dune_log = setup_repo_with_old_ocaml dir in
    let code, _stdout, stderr =
      run_dune_local dir bin_dir
        ~unset_env:
          [ "GITHUB_ACTIONS"; "MASC_SKIP_PIN_CHECK"
          ; "MASC_SKIP_DEPS_CHECK"; "MASC_SKIP_OCAML_VERSION_CHECK" ]
        "build"
    in
    check int "exits non-zero on old OCaml" 1 code;
    check bool "OCaml version message present" true
      (contains_substring stderr "OCaml 5.0 detected");
    check bool "minimum 5.4 mentioned" true
      (contains_substring stderr ">= 5.4");
    check bool "skip hint present" true
      (contains_substring stderr "MASC_SKIP_OCAML_VERSION_CHECK=1");
    check bool "dune not invoked" false (Sys.file_exists dune_log))

let test_skip_ocaml_version_env_bypasses_guard () =
  with_temp_dir "dune-local-skip-ocaml" (fun dir ->
    let bin_dir, dune_log = setup_repo_with_old_ocaml dir in
    let code, _stdout, _stderr =
      run_dune_local dir bin_dir
        ~env:[ ("MASC_SKIP_OCAML_VERSION_CHECK", "1") ]
        ~unset_env:
          [ "GITHUB_ACTIONS"; "MASC_SKIP_PIN_CHECK"; "MASC_SKIP_DEPS_CHECK" ]
        "build"
    in
    check int "exits zero when MASC_SKIP_OCAML_VERSION_CHECK=1" 0 code;
    check bool "dune was invoked" true (Sys.file_exists dune_log))

let () =
  run "dune_local_script"
    [
      ( "pin_guard",
        [
          test_case "pin drift aborts build with clear message" `Quick
            test_pin_drift_aborts_build;
          test_case "MASC_SKIP_PIN_CHECK=1 bypasses pin guard" `Quick
            test_skip_pin_check_env_bypasses_guard;
          test_case "GITHUB_ACTIONS=true bypasses pin guard" `Quick
            test_github_actions_bypasses_pin_guard;
          test_case "opam absent skips pin guard" `Quick
            test_opam_absent_skips_pin_guard;
          test_case "opam lockf reexec propagates env" `Quick
            test_opam_lockf_reexec_env_passthrough;
          test_case "opam lock timeout releases Dune lock" `Quick
            test_opam_lock_timeout_releases_dune_lock;
          test_case "unset opam lock timeout waits forever" `Quick
            test_unset_opam_lock_timeout_waits_forever;
          test_case "opam lock wrapped failure is not labeled timeout" `Quick
            test_opam_lockf_wrapped_failure_does_not_claim_timeout;
          test_case "opam lock timeout env must be numeric" `Quick
            test_opam_lock_timeout_env_must_be_numeric;
          test_case "missing lock tools warn once" `Quick
            test_missing_lock_tools_warn_once;
          test_case "opam flock reexec propagates env" `Quick
            test_opam_flock_reexec_env_passthrough;
          test_case "opam flock timeout releases Dune lock" `Quick
            test_opam_flock_timeout_releases_dune_lock;
          test_case "clean subcommand skips pin guard" `Quick
            test_clean_subcommand_skips_pin_guard;
          test_case
            "`--root . clean` (global flag before subcommand) skips pin guard"
            `Quick test_clean_subcommand_with_global_flag_skips_pin_guard;
          test_case
            "`--display=quiet clean` (--flag=value before subcommand) skips \
             pin guard"
            `Quick test_clean_subcommand_with_eq_flag_skips_pin_guard;
          test_case
            "`--auto-promote clean` (boolean flag is NOT value-taking) skips \
             pin guard"
            `Quick test_clean_subcommand_after_auto_promote_skips_pin_guard;
          test_case
            "`-p mypkg clean` (short -p IS value-taking) skips pin guard"
            `Quick
            test_clean_subcommand_after_short_packages_flag_skips_pin_guard;
          test_case
            "`-x dev clean` (short -x IS value-taking) skips pin guard"
            `Quick test_clean_subcommand_after_short_x_flag_skips_pin_guard;
          test_case
            "`--cache-storage-mode copy clean` skips pin guard"
            `Quick
            test_clean_subcommand_after_cache_storage_mode_skips_pin_guard;
          test_case
            "`--cache-check-probability 0.5 clean` skips pin guard"
            `Quick
            test_clean_subcommand_after_cache_check_probability_skips_pin_guard;
          test_case "pin OK allows build to proceed" `Quick
            test_pin_ok_build_proceeds;
          test_case "MASC_DUNE_DRY_RUN=1 skips pin check" `Quick
            test_dry_run_skips_pin_check;
        ] );
      ( "deps_guard",
        [
          test_case "missing deps abort build with clear message" `Quick
            test_missing_deps_aborts_build;
          test_case "MASC_SKIP_DEPS_CHECK=1 bypasses deps guard" `Quick
            test_skip_deps_check_env_bypasses_guard;
        ] );
      ( "ocaml_version_guard",
        [
          test_case "old OCaml aborts build with clear message" `Quick
            test_old_ocaml_aborts_build;
          test_case "MASC_SKIP_OCAML_VERSION_CHECK=1 bypasses ocaml guard"
            `Quick test_skip_ocaml_version_env_bypasses_guard;
        ] );
    ]
