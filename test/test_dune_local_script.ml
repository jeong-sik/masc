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
  let full_env =
    [ ("PATH", path); ("GIT_CEILING_DIRECTORIES", base); ("DUNE_LOCAL_LOCK", lock_path) ]
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
            ]
          ~unset_env:[ "GITHUB_ACTIONS"; "MASC_SKIP_PIN_CHECK" ]
          (Printf.sprintf "bash %s build"
             (quote (Filename.concat scripts_dir "dune-local.sh")))
      in
      check int "exits zero when opam absent" 0 code;
      check bool "dune was invoked" true (Sys.file_exists dune_log))

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
          test_case "clean subcommand skips pin guard" `Quick
            test_clean_subcommand_skips_pin_guard;
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
