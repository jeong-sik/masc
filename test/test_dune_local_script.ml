open Alcotest

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

let dune_local_script_path () =
  Filename.concat (Filename.concat (source_root ()) "scripts") "dune-local.sh"

let opam_switch_rw_lock_script_path () =
  Filename.concat
    (Filename.concat (source_root ()) "scripts")
    "opam-switch-rw-lock.sh"

let quote = Filename.quote

let read_file path =
  In_channel.with_open_bin path In_channel.input_all

let check_contains label haystack needle =
  if not (String_util.contains_substring haystack needle) then
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
    - bin/dune  (fake: logs invocations, exits 0)
    - bin/opam  (fake: exists, exits 0)

    Returns [(bin_dir, dune_log)] where [dune_log] records each dune call. *)
let setup_fake_repo ?(ocaml_version = "5.5.0") base =
  let scripts_dir = Filename.concat base "scripts" in
  let bin_dir = Filename.concat base "bin" in
  mkdir_p scripts_dir;
  mkdir_p bin_dir;
  write_file (Filename.concat base "dune-project")
    (Printf.sprintf
       {|(lang dune 3.22)
(package
 (name masc)
 (depends
  (ocaml (= %s))))
|}
       ocaml_version);
  (* Real dune-local.sh *)
  write_executable
    (Filename.concat scripts_dir "dune-local.sh")
    (read_file (dune_local_script_path ()));
  write_executable
    (Filename.concat scripts_dir "opam-switch-rw-lock.sh")
    (read_file (opam_switch_rw_lock_script_path ()));
  (* Fake opam: present in PATH and echoes back the queried package
     for `opam list --installed --short PKG` so the deps-installed
     guard treats core deps as present. Other
     subcommands return 0 with empty stdout. *)
  write_executable (Filename.concat bin_dir "opam")
    (Printf.sprintf
       {|#!/bin/sh
if [ "$1" = "list" ] && [ "$2" = "--installed" ] && [ -n "$4" ]; then
  printf '%%s\n' "$4"; exit 0
fi
if [ "$1" = "switch" ] && [ "$2" = "show" ]; then printf 'fake-switch\n'; exit 0; fi
if [ "$1" = "var" ] && [ "$2" = "prefix" ]; then printf '%%s\n' %s; exit 0; fi
exit 0
|}
       (quote base));
  (* Fake findlib/ocamlobjinfo provider surface. Keep this deterministic so
     tests never inspect the real opam switch. *)
  let fake_llm_provider_dir =
    Filename.concat (Filename.concat base "fake-agent-core") "llm_provider"
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
if [ "$1" = "query" ] && [ "$2" = "masc.agent_core.llm_provider" ]; then
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
printf '%%s read_lease=%%s\n' "${1:-build}" "${MASC_OPAM_READ_LEASE_HELD:-0}" >> %s
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
  let default_skip_env name =
    if List.exists (String.equal name) unset_env || List.mem_assoc name env
    then []
    else [ (name, "1") ]
  in
  let full_env =
    [
      ("PATH", path);
      ("GIT_CEILING_DIRECTORIES", base);
      ("DUNE_LOCAL_LOCK", lock_path);
      ("DUNE_BUILD_DIR", Filename.concat base "_build");
      ("MASC_DUNE_LOCK_HELD", "0");
      ("MASC_OPAM_READ_LEASE_HELD", "0");
    ]
    @ default_skip_env "MASC_SKIP_DEPS_CHECK"
    @ default_skip_env "MASC_SKIP_OCAML_VERSION_CHECK"
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

let test_opam_absent_aborts_before_dune () =
  with_temp_dir "dune-local-no-opam" (fun dir ->
      (* Set up a repo with no fake opam in PATH. *)
      let scripts_dir = Filename.concat dir "scripts" in
      let bin_dir = Filename.concat dir "bin" in
      mkdir_p scripts_dir;
      mkdir_p bin_dir;
      write_file (Filename.concat dir "dune-project")
        {|(lang dune 3.22)
(package
 (name masc)
 (depends
  (ocaml (= 5.5.0))))
|};
      write_executable
        (Filename.concat scripts_dir "dune-local.sh")
        (read_file (dune_local_script_path ()));
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
      (* Use a minimal PATH (no opam install directories) so that
         'command -v opam' fails and the guard is skipped.
         opam is typically in ~/.opam/SWITCH/bin/, not in /usr/bin or /bin. *)
      let minimal_path = Printf.sprintf "%s:/usr/bin:/bin" bin_dir in
      let lock_path = Filename.concat dir "dune-local.lock" in
      let script = Filename.concat scripts_dir "dune-local.sh" in
      let code, _stdout, stderr =
        run_process ~cwd:dir "/bin/bash"
          ~env:
            [
              ("PATH", minimal_path);
              ("GIT_CEILING_DIRECTORIES", dir);
              ("DUNE_LOCAL_LOCK", lock_path);
            ]
          ~unset_env:[ "GITHUB_ACTIONS" ]
          [| "/bin/bash"; script; "build" |]
      in
      check int "exits non-zero when opam absent" 1 code;
      check_contains "opam requirement is explicit" stderr
        "opam is unavailable; MASC requires an opam-managed OCaml 5.5.0 switch";
      check bool "dune was not invoked" false (Sys.file_exists dune_log))

let test_dune_lock_wait_reports_holder () =
  with_temp_dir "dune-local-lock-diag" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir
      in
      let dune_lock_path = Filename.concat dir "dune-local.lock" in
      let lockf_log = Filename.concat dir "lockf-calls.log" in
      write_executable
        (Filename.concat bin_dir "lockf")
        (Printf.sprintf
           {|#!/bin/sh
printf 'argv=%%s\n' "$*" >> %s
last=""
for arg in "$@"; do last="$arg"; done
case "$*:$last" in
  *"/readers/reader."*:true) exit 75 ;;
esac
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
        (String_util.contains_substring stderr "Dune lock holder(s)");
      check bool "reports holder command" true
        (String_util.contains_substring stderr "fake-dune-holder --target test");
      check bool "dune was invoked after reexec" true
        (Sys.file_exists dune_log))

let test_live_build_lock_aborts_before_dune () =
  with_temp_dir "dune-local-live-build-lock" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir
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
        (String_util.contains_substring stderr "live Dune build-dir lock holder");
      check bool "reports holder command" true
        (String_util.contains_substring stderr "dune build --root stale-worktree");
      check bool "explains bare dune bypass" true
        (String_util.contains_substring stderr "bare `dune` process");
      check bool "dune was not invoked" false (Sys.file_exists dune_log))

let test_opam_read_leases_overlap_and_exclude_writer () =
  with_temp_dir "opam-switch-rw-lock" (fun dir ->
      let script = opam_switch_rw_lock_script_path () in
      let lock_base = Filename.concat dir "switch" in
      let readers_dir = lock_base ^ ".state/readers" in
      let reader_one_started = Filename.concat dir "reader-one-started" in
      let reader_two_started = Filename.concat dir "reader-two-started" in
      let writer_started = Filename.concat dir "writer-started" in
      let command =
        Printf.sprintf
          {|set -eu
export OPAM_SWITCH_PREFIX=/tmp/masc-test-switch
export MASC_OPAM_LOCK_PATH=%s
%s read -- /bin/sh -c %s &
first_reader=$!
for _ in $(seq 1 50); do
  test -f %s && break
  sleep 0.02
done
%s read -- /bin/sh -c %s &
second_reader=$!
for _ in $(seq 1 50); do
  test -f %s && break
  sleep 0.02
done
test -f %s
test -f %s
set +e
%s write -- true
writer_while_readers=$?
set -e
wait "$first_reader"
wait "$second_reader"
test "$writer_while_readers" -eq 75
%s write -- /bin/sh -c %s &
writer=$!
for _ in $(seq 1 50); do
  test -f %s && break
  sleep 0.02
done
set +e
%s read -- true
reader_while_writer=$?
set -e
wait "$writer"
test "$reader_while_writer" -eq 75
%s write -- true
printf 'stale-reader-lock\n' > %s/$$
%s write -- true
test ! -e %s/$$
|}
          (quote lock_base)
          (quote script)
          (quote (Printf.sprintf "touch %s; sleep 1" (quote reader_one_started)))
          (quote reader_one_started)
          (quote script)
          (quote (Printf.sprintf "touch %s; sleep 1" (quote reader_two_started)))
          (quote reader_two_started)
          (quote reader_one_started)
          (quote reader_two_started)
          (quote script)
          (quote script)
          (quote (Printf.sprintf "touch %s; sleep 1" (quote writer_started)))
          (quote writer_started)
          (quote script)
          (quote script)
          (quote readers_dir)
          (quote script)
          (quote readers_dir)
      in
      let code, _stdout, stderr =
        run_process ~cwd:dir "/bin/bash" [| "/bin/bash"; "-c"; command |]
      in
      check int "reader overlap and writer exclusion" 0 code;
      check bool "writer rejection is explicit" true
        (String_util.contains_substring stderr "switch readers are active");
      check bool "reader rejection is explicit" true
        (String_util.contains_substring stderr "switch mutation is active"))

let test_opam_reader_admission_requires_held_inode_and_keeps_writer_file () =
  with_temp_dir "opam-switch-rw-lock-inode" (fun dir ->
      let script = opam_switch_rw_lock_script_path () in
      let lock_base = Filename.concat dir "switch" in
      let writer_path = lock_base ^ ".state/writer" in
      let reader_path = lock_base ^ ".state/readers/unheld" in
      let command =
        Printf.sprintf
          {|set -eu
export OPAM_SWITCH_PREFIX=/tmp/masc-test-switch
export MASC_OPAM_LOCK_PATH=%s
%s write -- true
test -f %s
printf 'not-held\n' > %s
if stat -f '%%d:%%i' %s >/dev/null 2>&1; then
  identity=$(stat -f '%%d:%%i' %s)
else
  identity=$(stat -c '%%d:%%i' %s)
fi
set +e
%s __admit_read %s "$identity"
status=$?
set -e
test "$status" -eq 75
|}
          (quote lock_base)
          (quote script)
          (quote writer_path)
          (quote reader_path)
          (quote reader_path)
          (quote reader_path)
          (quote reader_path)
          (quote script)
          (quote reader_path)
      in
      let code, _stdout, stderr =
        run_process ~cwd:dir "/bin/bash" [| "/bin/bash"; "-c"; command |]
      in
      check int "unheld reader is rejected" 0 code;
      check bool "writer inode remains addressable" true
        (Sys.file_exists writer_path);
      check bool "reader rejection identifies the inode race" true
        (String_util.contains_substring
           stderr
           "no longer names its locked inode"))

let minimal_lock_script_path dir =
  let bin_dir = Filename.concat dir "minimal-bin" in
  mkdir_p bin_dir;
  List.iter
    (fun (name, target) ->
       write_executable
         (Filename.concat bin_dir name)
         (Printf.sprintf "#!/bin/sh\nexec %s \"$@\"\n" target))
    [ "awk", "/usr/bin/awk"
    ; "basename", "/usr/bin/basename"
    ; "bash", "/bin/bash"
    ; "chmod", "/bin/chmod"
    ; "dirname", "/usr/bin/dirname"
    ; "mkdir", "/bin/mkdir"
    ];
  write_executable
    (Filename.concat bin_dir "cksum")
    "#!/bin/sh\nprintf '1 1\\n'\n";
  bin_dir
;;

let run_lock_script ~dir ~bin_dir ~lock_base ~marker =
  run_process
    ~cwd:dir
    "/bin/bash"
    ~env:
      [ "PATH", bin_dir
      ; "OPAM_SWITCH_PREFIX", "/tmp/masc-test-switch"
      ; "MASC_OPAM_LOCK_PATH", lock_base
      ]
    [| "/bin/bash"
     ; opam_switch_rw_lock_script_path ()
     ; "write"
     ; "--"
     ; "/bin/sh"
     ; "-c"
     ; "touch " ^ quote marker
    |]
;;

let test_opam_lock_backend_absence_fails_closed () =
  with_temp_dir "opam-switch-rw-lock-no-backend" (fun dir ->
    let bin_dir = minimal_lock_script_path dir in
    let marker = Filename.concat dir "wrapped-command-ran" in
    let code, _stdout, stderr =
      run_lock_script
        ~dir
        ~bin_dir
        ~lock_base:(Filename.concat dir "switch")
        ~marker
    in
    check int "missing lock tools fail closed" 69 code;
    check bool "wrapped command did not run" false (Sys.file_exists marker);
    check bool
      "missing backend is explicit"
      true
      (String_util.contains_substring
         stderr
         "neither lockf nor flock is available"))
;;

let test_opam_gate_timeout_has_admission_diagnostic () =
  with_temp_dir "opam-switch-rw-lock-gate-timeout" (fun dir ->
    let bin_dir = minimal_lock_script_path dir in
    write_executable
      (Filename.concat bin_dir "lockf")
      {|#!/bin/sh
while [ "$#" -gt 0 ]; do
  case "$1" in
    -k) shift ;;
    -t) shift 2 ;;
    *) break ;;
  esac
done
lock_path="$1"
shift
case "$lock_path" in
  *.gate) exit 75 ;;
  *) exec "$@" ;;
esac
|};
    let marker = Filename.concat dir "wrapped-command-ran" in
    let code, _stdout, stderr =
      run_lock_script
        ~dir
        ~bin_dir
        ~lock_base:(Filename.concat dir "switch")
        ~marker
    in
    check int "gate timeout is admission rejection" 75 code;
    check bool "wrapped command did not run" false (Sys.file_exists marker);
    check bool
      "gate timeout is explicit"
      true
      (String_util.contains_substring
         stderr
         "gate acquisition or lease admission rejected within 5s"))
;;

let test_dune_runs_under_opam_read_lease () =
  with_temp_dir "dune-local-opam-read-lease" (fun dir ->
      let bin_dir, dune_log = setup_fake_repo dir in
      let code, _stdout, _stderr =
        run_dune_local dir bin_dir ~unset_env:[ "GITHUB_ACTIONS" ] "build"
      in
      check int "wrapper succeeds" 0 code;
      check bool "Dune inherits the admitted read lease" true
        (String_util.contains_substring (read_file dune_log) "read_lease=1"))

let test_clean_subcommand_reaches_dune () =
  with_temp_dir "dune-local-clean" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir
      in
      let code, _stdout, _stderr =
        run_dune_local dir bin_dir
          ~unset_env:[ "GITHUB_ACTIONS" ]
          "clean"
      in
      check int "exits zero for clean subcommand" 0 code;
      check bool "dune was invoked" true (Sys.file_exists dune_log))

(* PR #13117 review (P2): the original guards checked args[0], so prefixing
   global options like `--root .` before `clean` misclassified the call as
   a non-clean target and ran compile-time guards on a target
   that does not compile.  Pin the new subcommand-detection helper so
   guard-skipping still kicks in. *)
let test_clean_subcommand_with_global_flag_reaches_dune () =
  with_temp_dir "dune-local-clean-flag" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir
      in
      let code, _stdout, _stderr =
        run_dune_local dir bin_dir
          ~unset_env:[ "GITHUB_ACTIONS" ]
          "--root . clean"
      in
      check int
        "exits zero for `--root . clean` even when compile guards are skipped"
        0 code;
      check bool "dune was invoked" true (Sys.file_exists dune_log))

let test_clean_subcommand_with_eq_flag_reaches_dune () =
  with_temp_dir "dune-local-clean-eq-flag" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir
      in
      let code, _stdout, _stderr =
        run_dune_local dir bin_dir
          ~unset_env:[ "GITHUB_ACTIONS" ]
          "--display=quiet clean"
      in
      check int
        "exits zero for `--display=quiet clean` even when compile guards are skipped"
        0 code;
      check bool "dune was invoked" true (Sys.file_exists dune_log))

(* CLI-connector follow-ups (#13117, 2026-05-05):
   - `--auto-promote` is a BOOLEAN common option (no arg).  Treating
     it as value-taking made `--auto-promote clean` skip both tokens
     and fall back to `build`.
   - `-p PACKAGES` and `-x VAL` are SHORT value-taking common
     options; the original `[[ "$a" == -* ]]` fallback consumed
     only the flag and misread the value as the subcommand. *)
let test_clean_subcommand_after_auto_promote_reaches_dune () =
  with_temp_dir "dune-local-clean-auto-promote" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir
      in
      let code, _stdout, _stderr =
        run_dune_local dir bin_dir
          ~unset_env:[ "GITHUB_ACTIONS" ]
          "--auto-promote clean"
      in
      check int
        "`--auto-promote clean` (boolean flag, NOT value-taking) skips guards"
        0 code;
      check bool "dune was invoked" true (Sys.file_exists dune_log))

let test_clean_subcommand_after_short_packages_flag_reaches_dune () =
  with_temp_dir "dune-local-clean-short-p" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir
      in
      let code, _stdout, _stderr =
        run_dune_local dir bin_dir
          ~unset_env:[ "GITHUB_ACTIONS" ]
          "-p mypkg clean"
      in
      check int
        "`-p mypkg clean` (short value-taking flag) skips guards"
        0 code;
      check bool "dune was invoked" true (Sys.file_exists dune_log))

let test_clean_subcommand_after_short_x_flag_reaches_dune () =
  with_temp_dir "dune-local-clean-short-x" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir
      in
      let code, _stdout, _stderr =
        run_dune_local dir bin_dir
          ~unset_env:[ "GITHUB_ACTIONS" ]
          "-x dev clean"
      in
      check int "`-x dev clean` (short value-taking flag) skips guards" 0
        code;
      check bool "dune was invoked" true (Sys.file_exists dune_log))

let test_clean_subcommand_after_cache_storage_mode_reaches_dune () =
  with_temp_dir "dune-local-clean-cache-storage-mode" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir
      in
      let code, _stdout, _stderr =
        run_dune_local dir bin_dir
          ~unset_env:[ "GITHUB_ACTIONS" ]
          "--cache-storage-mode copy clean"
      in
      check int
        "`--cache-storage-mode copy clean` (value-taking flag) skips guards"
        0 code;
      check bool "dune was invoked" true (Sys.file_exists dune_log))

let test_clean_subcommand_after_cache_check_probability_reaches_dune () =
  with_temp_dir "dune-local-clean-cache-check-probability" (fun dir ->
      let bin_dir, dune_log =
        setup_fake_repo dir
      in
      let code, _stdout, _stderr =
        run_dune_local dir bin_dir
          ~unset_env:[ "GITHUB_ACTIONS" ]
          "--cache-check-probability 0.5 clean"
      in
      check int
        "`--cache-check-probability 0.5 clean` (value-taking flag) skips guards"
        0 code;
      check bool "dune was invoked" true (Sys.file_exists dune_log))

(* --- required findlib guard tests -------------------------------------
   Helper: fake a dependency environment where opam package installation
   may have succeeded but [ocamlfind query] resolves no public libraries.
   The wrapper preflight passes so the test isolates the findlib guard. *)

let setup_repo_with_missing_deps base =
  let bin_dir, dune_log = setup_fake_repo base in
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

(* --- external pin guard tests ------------------------------------------
   The guard runs the real scripts/opam-pin-external-deps.sh --check against a
   fake opam whose `pin list` the test writes. Phase one hands it an empty
   table and reads the expectations out of the report; phase two hands those
   back. So the SHAs stay in the script and the test still pins both answers. *)

let pin_script_path () =
  Filename.concat (Filename.concat (source_root ()) "scripts")
    "opam-pin-external-deps.sh"

let setup_repo_for_pin_check base =
  let scripts_dir = Filename.concat base "scripts" in
  let bin_dir = Filename.concat base "bin" in
  mkdir_p scripts_dir;
  mkdir_p bin_dir;
  write_file (Filename.concat base "dune-project")
    {|(lang dune 3.22)
(package
 (name masc)
 (depends
  (ocaml (= 5.5.0))))
|};
  write_executable
    (Filename.concat scripts_dir "opam-pin-external-deps.sh")
    (read_file (pin_script_path ()));
  let table_path = Filename.concat base "pin-table.txt" in
  write_file table_path "";
  write_executable (Filename.concat bin_dir "opam")
    (Printf.sprintf
       {|#!/bin/sh
case "$1 $2" in
  "switch show") printf 'fake-switch
'; exit 0 ;;
  "var prefix") printf '%%s
' %s; exit 0 ;;
  "pin list") cat %s; exit 0 ;;
esac
if [ "$1" = "exec" ] && [ "$3" = "ocamlc" ]; then printf '5.5.0
'; exit 0; fi
exit 0
|}
       (quote base) (quote table_path));
  (bin_dir, table_path)

let run_pin_check base bin_dir =
  let system_path =
    match Sys.getenv_opt "PATH" with Some p -> p | None -> "/usr/bin:/bin"
  in
  run_process ~cwd:base
    ~env:
      [ ("PATH", Printf.sprintf "%s:%s" bin_dir system_path)
      ; ("MASC_OPAM_READ_LEASE_HELD", "1")
      ]
    ~unset_env:[ "OPAM_SWITCH_PREFIX"; "MASC_OPAM_WRITE_LEASE_HELD" ]
    "/bin/bash"
    [| "/bin/bash"
     ; Filename.concat (Filename.concat base "scripts") "opam-pin-external-deps.sh"
     ; "--check"
    |]

(* "[opam-pin]   package: not pinned; expected <target>" -> (package, target) *)
let expectation_of_line line =
  let line =
    (* Every line the script writes carries its own tag, and the package name
       starts after it. Without this cut the tag joins the package name. *)
    match substring_index line "] " with
    | Some at -> String.sub line (at + 2) (String.length line - at - 2)
    | None -> line
  in
  let line = String.trim line in
  match String.index_opt line ':' with
  | None -> None
  | Some colon ->
    let package = String.sub line 0 colon in
    let rest = String.sub line (colon + 1) (String.length line - colon - 1) in
    let marker = "expected " in
    (match substring_index rest marker with
     | None -> None
     | Some at ->
       let start = at + String.length marker in
       Some (package, String.trim (String.sub rest start (String.length rest - start))))

let test_pin_check_names_every_absent_pin () =
  with_temp_dir "opam-pin-check-empty" (fun dir ->
    let bin_dir, _table = setup_repo_for_pin_check dir in
    let code, _stdout, stderr = run_pin_check dir bin_dir in
    check int "an empty switch fails the check" 1 code;
    check_contains "the report names cohttp-eio" stderr "cohttp-eio: not pinned";
    check_contains "the report names the repair" stderr
      "scripts/opam-pin-external-deps.sh --install")

let test_pin_check_accepts_what_it_asks_for () =
  with_temp_dir "opam-pin-check-satisfied" (fun dir ->
    let bin_dir, table_path = setup_repo_for_pin_check dir in
    let _code, _stdout, stderr = run_pin_check dir bin_dir in
    let expectations =
      String.split_on_char '\n' stderr |> List.filter_map expectation_of_line
    in
    check bool "the empty run stated some expectations" true (expectations <> []);
    let rows =
      List.map
        (fun (package, target) ->
          Printf.sprintf "%s.0.0    git    git+%s    (at deadbeef)" package target)
        expectations
    in
    write_file table_path (String.concat "\n" rows ^ "\n");
    let code, stdout, stderr = run_pin_check dir bin_dir in
    if code <> 0 then failf "check rejected its own expectations: %s%s" stdout stderr;
    check_contains "the report says the pins are in place" stdout "pins are in place")

let test_pin_drift_aborts_build () =
  with_temp_dir "dune-local-pin-drift" (fun dir ->
    let bin_dir, dune_log = setup_fake_repo dir in
    (* The wiring, not the check: dune-local must stop on a non-zero --check
       and say what it read. setup_fake_repo copies no pin script, so every
       other case in this suite leaves the guard inert. *)
    write_executable
      (Filename.concat (Filename.concat dir "scripts") "opam-pin-external-deps.sh")
      {|#!/bin/sh
echo "[opam-pin] the active switch does not carry these pins:" >&2
echo "[opam-pin]   cohttp-eio: not pinned; expected https://example.invalid/repo.git#sha" >&2
exit 1
|};
    let code, _stdout, stderr =
      run_dune_local dir bin_dir ~unset_env:[ "GITHUB_ACTIONS"; "MASC_SKIP_DEPS_CHECK" ] "build"
    in
    check int "exits non-zero on pin drift" 1 code;
    check_contains "the pin report reaches the caller" stderr
      "cohttp-eio: not pinned";
    check_contains "the bypass is named" stderr "MASC_SKIP_DEPS_CHECK=1";
    check bool "dune not invoked" false (Sys.file_exists dune_log))

let test_missing_deps_aborts_build () =
  with_temp_dir "dune-local-missing-deps" (fun dir ->
    let bin_dir, dune_log = setup_repo_with_missing_deps dir in
    let code, _stdout, stderr =
      run_dune_local dir bin_dir
        ~unset_env:[ "GITHUB_ACTIONS"; "MASC_SKIP_DEPS_CHECK" ]
        "build"
    in
    check int "exits non-zero on missing deps" 1 code;
    check bool "missing deps message present" true
      (String_util.contains_substring stderr "missing or incompatible findlib libraries");
    check_contains "piaf stream is checked" stderr "piaf.stream";
    check_contains "OpenTelemetry API layout is checked" stderr
      "opentelemetry.client";
    check bool "repair hint present" true
      (String_util.contains_substring stderr "opam-pin-external-deps.sh --install");
    check bool "skip hint present" true
      (String_util.contains_substring stderr "MASC_SKIP_DEPS_CHECK=1");
    check bool "dune not invoked" false (Sys.file_exists dune_log))

let test_skip_deps_check_env_bypasses_guard () =
  with_temp_dir "dune-local-skip-deps" (fun dir ->
    let bin_dir, dune_log = setup_repo_with_missing_deps dir in
    let code, _stdout, _stderr =
      run_dune_local dir bin_dir
        ~env:[ ("MASC_SKIP_DEPS_CHECK", "1") ]
        ~unset_env:[ "GITHUB_ACTIONS" ]
        "build"
    in
    check int "exits zero when MASC_SKIP_DEPS_CHECK=1" 0 code;
    check bool "dune was invoked" true (Sys.file_exists dune_log))

(* --- exact OCaml toolchain guard tests -------------------------------- *)

let setup_repo_with_ocaml ?(required_version = "5.5.0")
    ?(ocaml_version = "5.4.0") base =
  let bin_dir, dune_log =
    setup_fake_repo base ~ocaml_version:required_version
  in
  (* The exact-toolchain tests exercise opam prefix identity before any
     dependency checks, so provide one coherent fake switch and prefix. *)
  let opam_path = Filename.concat bin_dir "opam" in
  let opam_script =
    Printf.sprintf
      {|#!/bin/sh
if [ "$1" = "switch" ] && [ "$2" = "show" ]; then
  printf 'fake-switch\n'; exit 0
fi
if [ "$1" = "var" ] && [ "$2" = "prefix" ]; then
  printf '%%s\n' %s; exit 0
fi
exit 0
|}
      (quote base)
  in
  write_executable opam_path opam_script;
  (* Fake compiler that reports the requested exact version. *)
  let ocamlc_path = Filename.concat bin_dir "ocamlc" in
  write_executable ocamlc_path
    (Printf.sprintf
       "#!/bin/sh\nif [ \"$1\" = \"-version\" ]; then printf '%s\\n'; fi\nexit 0\n"
       ocaml_version);
  (bin_dir, dune_log)

let test_old_ocaml_aborts_build () =
  with_temp_dir "dune-local-old-ocaml" (fun dir ->
    let bin_dir, dune_log = setup_repo_with_ocaml dir in
    let code, _stdout, stderr =
      run_dune_local dir bin_dir
        ~env:[ ("OPAM_SWITCH_PREFIX", dir) ]
        ~unset_env:
          [ "GITHUB_ACTIONS"
          ; "MASC_SKIP_DEPS_CHECK"; "MASC_SKIP_OCAML_VERSION_CHECK" ]
        "build"
    in
    check int "exits non-zero on old OCaml" 1 code;
    check_contains "OCaml version message present" stderr "OCaml 5.4.0 detected";
    check_contains "exact 5.5.0 mentioned" stderr "exactly 5.5.0";
    check_contains "skip hint present" stderr
      "MASC_SKIP_OCAML_VERSION_CHECK=1";
    check bool "dune not invoked" false (Sys.file_exists dune_log))

let test_skip_ocaml_version_env_bypasses_guard () =
  with_temp_dir "dune-local-skip-ocaml" (fun dir ->
    let bin_dir, dune_log = setup_repo_with_ocaml dir in
    let code, _stdout, _stderr =
      run_dune_local dir bin_dir
        ~env:[ ("MASC_SKIP_OCAML_VERSION_CHECK", "1") ]
        ~unset_env:[ "GITHUB_ACTIONS" ]
        "build"
    in
    check int "exits zero when MASC_SKIP_OCAML_VERSION_CHECK=1" 0 code;
    check bool "dune was invoked" true (Sys.file_exists dune_log))

let test_ocaml_version_comes_from_dune_project () =
  with_temp_dir "dune-local-ocaml-version-ssot" (fun dir ->
    let bin_dir, dune_log =
      setup_repo_with_ocaml dir ~required_version:"5.6.0"
        ~ocaml_version:"5.5.0"
    in
    let code, _stdout, stderr =
      run_dune_local dir bin_dir
        ~env:[ ("OPAM_SWITCH_PREFIX", dir) ]
        ~unset_env:
          [ "GITHUB_ACTIONS"
          ; "MASC_SKIP_DEPS_CHECK"; "MASC_SKIP_OCAML_VERSION_CHECK" ]
        "build"
    in
    check int "exits non-zero on dune-project version mismatch" 1 code;
    check bool "live OCaml version message present" true
      (String_util.contains_substring stderr "OCaml 5.5.0 detected");
    check bool "dune-project exact version mentioned" true
      (String_util.contains_substring stderr "exactly 5.6.0");
    check bool "dune not invoked" false (Sys.file_exists dune_log))

let test_split_opam_prefix_aborts_build () =
  with_temp_dir "dune-local-split-opam-prefix" (fun dir ->
    let bin_dir, dune_log = setup_repo_with_ocaml dir ~ocaml_version:"5.5.0" in
    let wrong_prefix = Filename.concat dir "other-switch" in
    let code, _stdout, stderr =
      run_dune_local dir bin_dir
        ~env:[ ("OPAM_SWITCH_PREFIX", wrong_prefix) ]
        ~unset_env:
          [ "GITHUB_ACTIONS"
          ; "MASC_SKIP_OCAML_VERSION_CHECK" ]
        "build"
    in
    check int "exits non-zero on split opam prefix" 1 code;
    check_contains "split environment message present" stderr
      "split opam environment";
    check_contains "selected prefix present" stderr dir;
    check_contains "stale prefix present" stderr wrong_prefix;
    check_contains "repair command present" stderr
      "opam env --switch=5.5.0 --set-switch";
    check bool "dune not invoked" false (Sys.file_exists dune_log))

let () =
  run "dune_local_script"
    [
      ( "wrapper_guard",
        [
          test_case "opam absent aborts before Dune" `Quick
            test_opam_absent_aborts_before_dune;
          test_case "Dune lock wait reports holder" `Quick
            test_dune_lock_wait_reports_holder;
          test_case "live build-dir lock aborts before Dune" `Quick
            test_live_build_lock_aborts_before_dune;
          test_case "opam read leases overlap and exclude mutation" `Quick
            test_opam_read_leases_overlap_and_exclude_writer;
          test_case "opam reader admission requires its held inode" `Quick
            test_opam_reader_admission_requires_held_inode_and_keeps_writer_file;
          test_case "missing opam lock tools fail closed" `Quick
            test_opam_lock_backend_absence_fails_closed;
          test_case "opam gate timeout emits admission diagnostic" `Quick
            test_opam_gate_timeout_has_admission_diagnostic;
          test_case "Dune executes under an opam read lease" `Quick
            test_dune_runs_under_opam_read_lease;
          test_case "clean subcommand reaches Dune" `Quick
            test_clean_subcommand_reaches_dune;
          test_case
            "`--root . clean` (global flag before subcommand) reaches Dune"
            `Quick test_clean_subcommand_with_global_flag_reaches_dune;
          test_case
            "`--display=quiet clean` (--flag=value before subcommand) reaches Dune"
            `Quick test_clean_subcommand_with_eq_flag_reaches_dune;
          test_case
            "`--auto-promote clean` (boolean flag) reaches Dune"
            `Quick test_clean_subcommand_after_auto_promote_reaches_dune;
          test_case
            "`-p mypkg clean` (short -p is value-taking) reaches Dune"
            `Quick
            test_clean_subcommand_after_short_packages_flag_reaches_dune;
          test_case
            "`-x dev clean` (short -x is value-taking) reaches Dune"
            `Quick test_clean_subcommand_after_short_x_flag_reaches_dune;
          test_case
            "`--cache-storage-mode copy clean` reaches Dune"
            `Quick
            test_clean_subcommand_after_cache_storage_mode_reaches_dune;
          test_case
            "`--cache-check-probability 0.5 clean` reaches Dune"
            `Quick
            test_clean_subcommand_after_cache_check_probability_reaches_dune;
        ] );
      ( "deps_guard",
        [
          test_case "missing deps abort build with clear message" `Quick
            test_missing_deps_aborts_build;
          test_case "MASC_SKIP_DEPS_CHECK=1 bypasses deps guard" `Quick
            test_skip_deps_check_env_bypasses_guard;
        ] );
      ( "pin_guard",
        [
          test_case "an absent pin is named" `Quick
            test_pin_check_names_every_absent_pin;
          test_case "the check accepts what it asks for" `Quick
            test_pin_check_accepts_what_it_asks_for;
          test_case "pin drift aborts the build" `Quick
            test_pin_drift_aborts_build;
        ] );
      ( "ocaml_version_guard",
        [
          test_case "old OCaml aborts build with clear message" `Quick
            test_old_ocaml_aborts_build;
          test_case "MASC_SKIP_OCAML_VERSION_CHECK=1 bypasses ocaml guard"
            `Quick test_skip_ocaml_version_env_bypasses_guard;
          test_case "exact OCaml version is read from dune-project" `Quick
            test_ocaml_version_comes_from_dune_project;
          test_case "split opam prefix aborts with repair command" `Quick
            test_split_opam_prefix_aborts_build;
        ] );
    ]
