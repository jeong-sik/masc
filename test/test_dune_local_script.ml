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

let check_contains label haystack needle =
  if not (contains_substring haystack needle) then
    failf "%s: missing %S in stderr:\n%s" label needle haystack

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

let env_array ~unset_env overrides =
  let table = Hashtbl.create 64 in
  Unix.environment ()
  |> Array.iter (fun entry ->
         match String.index_opt entry '=' with
         | None -> ()
         | Some idx ->
             let key = String.sub entry 0 idx in
             let value =
               String.sub entry (idx + 1) (String.length entry - idx - 1)
             in
             Hashtbl.replace table key value);
  List.iter (fun key -> Hashtbl.remove table key) unset_env;
  List.iter (fun (key, value) -> Hashtbl.replace table key value) overrides;
  Hashtbl.fold
    (fun key value acc -> Printf.sprintf "%s=%s" key value :: acc)
    table []
  |> Array.of_list

let run_process ?(env = []) ?(unset_env = []) ~cwd prog argv =
  let out = Filename.temp_file "dune-local-out" ".txt" in
  let err = Filename.temp_file "dune-local-err" ".txt" in
  let out_fd = Unix.openfile out [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let err_fd = Unix.openfile err [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let original_cwd = Sys.getcwd () in
  let pid =
    Fun.protect
      ~finally:(fun () ->
        Sys.chdir original_cwd;
        Unix.close out_fd;
        Unix.close err_fd)
      (fun () ->
        Sys.chdir cwd;
        Unix.create_process_env prog argv
          (env_array ~unset_env env)
          Unix.stdin out_fd err_fd)
  in
  let _, status = Unix.waitpid [] pid in
  let code =
    match status with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 255
  in
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
  (* Fake findlib/ocamlobjinfo for the installed-agent-sdk interface marker.
     Keep this deterministic so tests never inspect the real opam switch. *)
  let fake_llm_provider_dir =
    Filename.concat (Filename.concat base "fake-agent-sdk") "llm_provider"
  in
  mkdir_p fake_llm_provider_dir;
  write_file
    (Filename.concat fake_llm_provider_dir "llm_provider__Provider_config.cmi")
    "fake-cmi";
  write_file
    (Filename.concat fake_llm_provider_dir "llm_provider__Provider_kind.cmi")
    "fake-cmi";
  write_executable
    (Filename.concat bin_dir "ocamlfind")
    (Printf.sprintf
       {|#!/bin/sh
if [ "$1" = "query" ] && [ "$2" = "agent_sdk.llm_provider" ]; then
  printf '%%s\n' %s
  exit 0
fi
exit 1
|}
       (quote fake_llm_provider_dir));
  write_executable
    (Filename.concat bin_dir "ocamlobjinfo")
    {|#!/bin/sh
case "$1" in
  *llm_provider__Provider_kind.cmi)
    unit=Llm_provider__Provider_kind
    crc="${MASC_TEST_PROVIDER_KIND_CRC:-8b2c2a1da7a2b790f36f2cdbb3512b8f}"
    ;;
  *)
    unit=Llm_provider__Provider_config
    crc="${MASC_TEST_PROVIDER_CONFIG_CRC:-feedfacefeedfacefeedfacefeedface}"
    ;;
esac
printf 'File %s\n' "$1"
printf 'Unit name: %s\n' "$unit"
printf 'Interfaces imported:\n'
printf '\t%s\t%s\n' "$crc" "$unit"
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
  (* Most tests exercise fake Dune behavior inside an isolated temp repo. The
     production bare-Dune guard scans the host process table, so unrelated
     developer Dune processes would otherwise make these hermetic tests flaky.
     Tests that target the guard pass [~unset_env] for this variable. *)
  let allow_bare_dune_env =
    if List.exists (String.equal "MASC_DUNE_ALLOW_BARE_DUNE") unset_env
    then []
    else [ ("MASC_DUNE_ALLOW_BARE_DUNE", "1") ]
  in
  let full_env =
    [
      ("PATH", path);
      ("GIT_CEILING_DIRECTORIES", base);
      ("DUNE_LOCAL_LOCK", lock_path);
      ("DUNE_BUILD_DIR", Filename.concat base "_build");
      ("MASC_OPAM_LOCK_PATH", opam_lock_path);
      ("MASC_DUNE_LOCK_HELD", "0");
      ("MASC_OPAM_LOCK_HELD", "0");
    ]
    @ allow_bare_dune_env
    @ List.filter
        (fun (k, _) ->
          k <> "PATH" && k <> "GIT_CEILING_DIRECTORIES" && k <> "DUNE_LOCAL_LOCK")
        env
  in
  let script = Filename.concat (Filename.concat base "scripts") "dune-local.sh" in
  let subcommand_argv =
    subcommand
    |> String.split_on_char ' '
    |> List.map String.trim
    |> List.filter (fun value -> value <> "")
  in
  run_process ~cwd:base ~env:full_env ~unset_env "/bin/bash"
    (Array.of_list ("/bin/bash" :: script :: subcommand_argv))

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

let test_skip_pin_check_still_cleans_on_provider_config_crc_change () =
  with_temp_dir "dune-local-provider-config-crc" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:1
          ~pin_check_stderr_msg:"pin mismatch"
      in
      let build_dir = Filename.concat dir "_build" in
      mkdir_p build_dir;
      write_file (Filename.concat build_dir ".last-agent-sdk-provider-config-crc")
        "oldcrc";
      write_file (Filename.concat build_dir "stale-object") "stale";
      let code, _stdout, stderr =
        run_dune_local dir bin_dir
          ~env:
            [
              ("MASC_SKIP_PIN_CHECK", "1");
              ("MASC_TEST_PROVIDER_CONFIG_CRC", "newcrc");
            ]
          ~unset_env:[ "GITHUB_ACTIONS" ]
          "build"
      in
      check int "exits zero when pin guard is skipped" 0 code;
      check bool "crc change message present" true
        (contains_substring stderr "Provider_config interface changed");
      check bool "stale build artifact removed" false
        (Sys.file_exists (Filename.concat build_dir "stale-object"));
      check string "crc marker refreshed" "newcrc"
        (read_file
           (Filename.concat build_dir ".last-agent-sdk-provider-config-crc"));
      check bool "dune was invoked after cleanup" true (Sys.file_exists dune_log))

let test_skip_pin_check_still_cleans_on_provider_kind_crc_change () =
  with_temp_dir "dune-local-provider-kind-crc" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:1
          ~pin_check_stderr_msg:"pin mismatch"
      in
      let build_dir = Filename.concat dir "_build" in
      mkdir_p build_dir;
      write_file (Filename.concat build_dir ".last-agent-sdk-provider-kind-crc")
        "oldcrc";
      write_file (Filename.concat build_dir "stale-object") "stale";
      let code, _stdout, stderr =
        run_dune_local dir bin_dir
          ~env:
            [
              ("MASC_SKIP_PIN_CHECK", "1");
              ("MASC_TEST_PROVIDER_KIND_CRC", "newcrc");
            ]
          ~unset_env:[ "GITHUB_ACTIONS" ]
          "build"
      in
      check int "exits zero when pin guard is skipped" 0 code;
      check bool "crc change message present" true
        (contains_substring stderr "Provider_kind interface changed");
      check bool "stale build artifact removed" false
        (Sys.file_exists (Filename.concat build_dir "stale-object"));
      check string "crc marker refreshed" "newcrc"
        (read_file
           (Filename.concat build_dir ".last-agent-sdk-provider-kind-crc"));
      check bool "dune was invoked after cleanup" true (Sys.file_exists dune_log))

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
         opam is typically in ~/.opam/SWITCH/bin/, not in /usr/bin or /bin.
         The bare-Dune guard is not under test here, so keep the isolated fake
         repo independent of host Dune processes. *)
      let minimal_path = Printf.sprintf "%s:/usr/bin:/bin" bin_dir in
      let lock_path = Filename.concat dir "dune-local.lock" in
      let script = Filename.concat scripts_dir "dune-local.sh" in
      let code, _stdout, _stderr =
        run_process ~cwd:dir "/bin/bash"
          ~env:
            [
              ("PATH", minimal_path);
              ("GIT_CEILING_DIRECTORIES", dir);
              ("DUNE_LOCAL_LOCK", lock_path);
              ("MASC_OPAM_LOCK_PATH", opam_lock_path);
              ("MASC_DUNE_ALLOW_BARE_DUNE", "1");
            ]
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_SKIP_PIN_CHECK" ]
          [| "/bin/bash"; script; "build" |]
      in
      check int "exits zero when opam absent" 0 code;
      let lock_log =
        if Sys.file_exists lockf_log then read_file lockf_log else ""
      in
      check bool "opam lockf not invoked" false
        (contains_substring lock_log opam_lock_path);
      check bool "dune was invoked" true (Sys.file_exists dune_log))

let test_dune_lock_wait_reports_holder () =
  with_temp_dir "dune-local-lock-diag" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:0
          ~pin_check_stderr_msg:"pin ok"
      in
      let dune_lock_path = Filename.concat dir "dune-local.lock" in
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
shift
exec "$@"
|}
           (quote lockf_log));
      write_executable
        (Filename.concat bin_dir "lsof")
        (Printf.sprintf
           {|#!/bin/sh
if [ "${1:-}" = "-t" ] && [ "${2:-}" = %s ]; then
  printf '1234\n'
  exit 0
fi
exit 1
|}
           (quote dune_lock_path));
      write_executable
        (Filename.concat bin_dir "ps")
        {|#!/bin/sh
if [ "${1:-}" = "-p" ] && [ "${2:-}" = "1234" ]; then
  printf ' 1234 999 S 00:42 fake-dune-holder --target test\n'
  exit 0
fi
exit 1
|};
      let code, _stdout, stderr =
        run_dune_local dir bin_dir ~unset_env:[ "GITHUB_ACTIONS" ] "build"
      in
      check int "exits zero through lockf reexec" 0 code;
      check bool "reports Dune lock holders" true
        (contains_substring stderr "Dune lock holder(s)");
      check bool "reports holder command" true
        (contains_substring stderr "fake-dune-holder --target test");
      check bool "dune was invoked after reexec" true
        (Sys.file_exists dune_log))

let test_live_build_lock_aborts_before_dune () =
  with_temp_dir "dune-local-live-build-lock" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:0
          ~pin_check_stderr_msg:"pin ok"
      in
      let build_dir = Filename.concat dir "_build" in
      mkdir_p build_dir;
      let build_lock_path = Filename.concat build_dir ".lock" in
      write_file build_lock_path "";
      write_executable
        (Filename.concat bin_dir "lsof")
        {|#!/bin/sh
case "${1:-} ${2:-}" in
  "-t "*/_build/.lock)
  printf '4321\n'
  exit 0
  ;;
esac
exit 1
|};
      write_executable
        (Filename.concat bin_dir "ps")
        {|#!/bin/sh
if [ "${1:-}" = "-p" ] && [ "${2:-}" = "4321" ]; then
  printf ' 4321 1 S 12:34 dune build --root stale-worktree\n'
  exit 0
fi
exit 1
|};
      let code, _stdout, stderr =
        run_dune_local dir bin_dir ~unset_env:[ "GITHUB_ACTIONS" ] "build"
      in
      check int "exits tempfail on live build-dir lock" 75 code;
      check bool "reports live build-dir lock" true
        (contains_substring stderr "live Dune build-dir lock holder");
      check bool "reports holder command" true
        (contains_substring stderr "dune build --root stale-worktree");
      check bool "explains bare dune bypass" true
        (contains_substring stderr "bare `dune` process");
      check bool "dune was not invoked" false (Sys.file_exists dune_log))

let write_bare_dune_ps bin_dir =
  write_executable
    (Filename.concat bin_dir "ps")
    {|#!/bin/sh
if [ "${1:-}" = "ax" ]; then
  cat <<'PS'
 111 1 dune exec --root . test/test_config_dir_resolver.exe
 112 1 dune --root . build
 113 1 opam exec -- dune --build-dir _build test
 114 1 dune clean --root .
 222 333 dune build --root wrapped-worktree
 333 1 lockf -k /tmp/me-dune-local.lock /usr/bin/env MASC_DUNE_LOCK_HELD=1 scripts/dune-local.sh build
PS
  exit 0
fi
exit 1
|}

let test_bare_dune_bypass_aborts_before_dune () =
  with_temp_dir "dune-local-bare-dune-bypass" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:0
          ~pin_check_stderr_msg:"pin ok"
      in
      write_bare_dune_ps bin_dir;
      let code, _stdout, stderr =
        run_dune_local dir bin_dir
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_DUNE_ALLOW_BARE_DUNE" ]
          "build"
      in
      check int "exits tempfail on bare dune bypass" 75 code;
      check bool "reports unwrapped Dune" true
        (contains_substring stderr "outside scripts/dune-local.sh");
      check bool "reports bare dune command" true
        (contains_substring stderr
           "dune exec --root . test/test_config_dir_resolver.exe");
      check bool "reports dune with leading global option" true
        (contains_substring stderr "dune --root . build");
      check bool "reports opam exec dune with leading global option" true
        (contains_substring stderr "opam exec -- dune --build-dir _build test");
      check bool "reports bare dune clean" true
        (contains_substring stderr "dune clean --root .");
      check bool "does not report wrapped child" false
        (contains_substring stderr "wrapped-worktree");
      check bool "dune was not invoked" false (Sys.file_exists dune_log))

let test_bare_dune_bypass_can_be_overridden () =
  with_temp_dir "dune-local-bare-dune-override" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir ~pin_check_exit_code:0
          ~pin_check_stderr_msg:"pin ok"
      in
      write_bare_dune_ps bin_dir;
      let code, _stdout, _stderr =
        run_dune_local dir bin_dir
          ~env:[ ("MASC_DUNE_ALLOW_BARE_DUNE", "1") ]
          ~unset_env:[ "GITHUB_ACTIONS" ] "build"
      in
      check int "exits zero when bare dune guard is overridden" 0 code;
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

let test_zero_like_opam_lock_timeout_waits_forever () =
  with_temp_dir "dune-local-opam-lock-timeout-zero-like" (fun dir ->
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
          ~env:[ ("MASC_OPAM_LOCK_AFTER_DUNE_TIMEOUT", "00") ]
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_OPAM_LOCK_HELD" ]
          "build"
      in
      check int "zero-like timeout waits forever" 0 code;
      let lock_log = read_file lockf_log in
      check bool "lockf timeout flag not used for zero-like value" false
        (contains_substring lock_log "timeout=");
      check bool "timeout message not emitted for zero-like value" false
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
      write_executable (Filename.concat bin_dir "awk")
        {|#!/bin/sh
while read -r first second rest; do
  if [ "$second" = "Llm_provider__Provider_config" ]; then
    printf '%s\n' "$first"
    exit 0
  fi
done
exit 1
|};
      let build_dir = Filename.concat dir "_build" in
      mkdir_p build_dir;
      let opam_path = Filename.concat bin_dir "opam" in
      let script =
        Filename.concat (Filename.concat dir "scripts") "dune-local.sh"
      in
      let code, _stdout, stderr =
        run_process ~cwd:dir "/bin/bash"
          ~env:
            [
              ("PATH", bin_dir);
              ("GIT_CEILING_DIRECTORIES", dir);
              ("DUNE_LOCAL_LOCK", Filename.concat dir "dune-local.lock");
              ("DUNE_BUILD_DIR", build_dir);
              ("MASC_SKIP_PIN_CHECK", "1");
              ("MASC_SKIP_DEPS_CHECK", "1");
              ("MASC_SKIP_OCAML_VERSION_CHECK", "1");
              ("MASC_DUNE_ALLOW_BARE_DUNE", "1");
            ]
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_DUNE_LOCK_HELD" ]
          [| "/bin/bash"; script; "build" |]
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
      let script =
        Filename.concat (Filename.concat dir "scripts") "dune-local.sh"
      in
      let code, _stdout, _stderr =
        run_process ~cwd:dir "/bin/bash"
          ~env:
            [
              ("PATH", Printf.sprintf "%s:/bin" bin_dir);
              ("GIT_CEILING_DIRECTORIES", dir);
              ("DUNE_LOCAL_LOCK", dune_lock_path);
              ("MASC_OPAM_LOCK_PATH", opam_lock_path);
              ("MASC_SKIP_DEPS_CHECK", "1");
              ("MASC_SKIP_OCAML_VERSION_CHECK", "1");
              ("MASC_DUNE_ALLOW_BARE_DUNE", "1");
            ]
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_OPAM_LOCK_HELD" ]
          [| "/bin/bash"; script; "build" |]
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
      let script =
        Filename.concat (Filename.concat dir "scripts") "dune-local.sh"
      in
      let code, _stdout, stderr =
        run_process ~cwd:dir "/bin/bash"
          ~env:
            [
              ("PATH", Printf.sprintf "%s:/bin" bin_dir);
              ("GIT_CEILING_DIRECTORIES", dir);
              ("DUNE_LOCAL_LOCK", dune_lock_path);
              ("MASC_OPAM_LOCK_PATH", opam_lock_path);
              ("MASC_OPAM_LOCK_AFTER_DUNE_TIMEOUT", "2");
              ("MASC_SKIP_DEPS_CHECK", "1");
              ("MASC_SKIP_OCAML_VERSION_CHECK", "1");
              ("MASC_DUNE_ALLOW_BARE_DUNE", "1");
            ]
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_OPAM_LOCK_HELD" ]
          [| "/bin/bash"; script; "build" |]
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

(* CLI-connector follow-ups (#13117, 2026-05-05):
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
    check_contains "OCaml version message present" stderr "OCaml 5.0 detected";
    check_contains "minimum 5.4 mentioned" stderr "5.4";
    check_contains "skip hint present" stderr
      "MASC_SKIP_OCAML_VERSION_CHECK=1";
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
          test_case
            "MASC_SKIP_PIN_CHECK=1 still cleans on Provider_config CRC change"
            `Quick
            test_skip_pin_check_still_cleans_on_provider_config_crc_change;
          test_case
            "MASC_SKIP_PIN_CHECK=1 still cleans on Provider_kind CRC change"
            `Quick
            test_skip_pin_check_still_cleans_on_provider_kind_crc_change;
          test_case "GITHUB_ACTIONS=true bypasses pin guard" `Quick
            test_github_actions_bypasses_pin_guard;
          test_case "opam absent skips pin guard" `Quick
            test_opam_absent_skips_pin_guard;
          test_case "Dune lock wait reports holder" `Quick
            test_dune_lock_wait_reports_holder;
          test_case "live build-dir lock aborts before Dune" `Quick
            test_live_build_lock_aborts_before_dune;
          test_case "bare Dune bypass aborts before Dune" `Quick
            test_bare_dune_bypass_aborts_before_dune;
          test_case "MASC_DUNE_ALLOW_BARE_DUNE=1 bypasses bare Dune guard"
            `Quick test_bare_dune_bypass_can_be_overridden;
          test_case "opam lockf reexec propagates env" `Quick
            test_opam_lockf_reexec_env_passthrough;
          test_case "opam lock timeout releases Dune lock" `Quick
            test_opam_lock_timeout_releases_dune_lock;
          test_case "unset opam lock timeout waits forever" `Quick
            test_unset_opam_lock_timeout_waits_forever;
          test_case "zero-like opam lock timeout waits forever" `Quick
            test_zero_like_opam_lock_timeout_waits_forever;
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
