open Alcotest

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when String.trim root <> "" -> root
  | _ -> Sys.getcwd ()

let quote = Filename.quote

let read_file path =
  In_channel.with_open_bin path In_channel.input_all

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

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

let contains_substring haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop idx =
    idx + nlen <= hlen
    && (String.sub haystack idx nlen = needle || loop (idx + 1))
  in
  nlen = 0 || loop 0

let run_shell ?(env = []) ~cwd cmd =
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
  let out = Filename.temp_file "disk-hygiene-out" ".txt" in
  let err = Filename.temp_file "disk-hygiene-err" ".txt" in
  let wrapped =
    Printf.sprintf "%s > %s 2> %s" full (quote out) (quote err)
  in
  let code = Sys.command wrapped in
  let stdout = read_file out in
  let stderr = read_file err in
  Sys.remove out;
  Sys.remove err;
  (code, stdout, stderr)

let init_repo dir =
  ignore (run_shell ~cwd:dir "git init -q");
  ignore (run_shell ~cwd:dir "git config user.email test@example.com");
  ignore (run_shell ~cwd:dir "git config user.name tester")

let copy_script ~repo_root rel_path =
  let src = Filename.concat (source_root ()) rel_path in
  let dst = Filename.concat repo_root rel_path in
  mkdir_p (Filename.dirname dst);
  write_file dst (read_file src);
  Unix.chmod dst 0o755

let install_fake_dune ~dir =
  let bin_dir = Filename.concat dir "bin" in
  mkdir_p bin_dir;
  let dune_path = Filename.concat bin_dir "dune" in
  write_file dune_path
    {|#!/bin/sh
set -eu
log_file="${FAKE_DUNE_LOG:?}"
if [ "${1:-}" = "cache" ] && [ "${2:-}" = "size" ]; then
  printf '5.11GB\n'
  exit 0
fi
if [ "${1:-}" = "cache" ] && [ "${2:-}" = "trim" ]; then
  printf '%s\n' "$*" >>"$log_file"
  printf 'Freed 0B (0 files removed)\n'
  exit 0
fi
printf 'unexpected dune invocation: %s\n' "$*" >&2
exit 1
|}
  ;
  Unix.chmod dune_path 0o755;
  bin_dir

let install_fake_java ~dir =
  let bin_dir = Filename.concat dir "bin-java" in
  mkdir_p bin_dir;
  let java_path = Filename.concat bin_dir "java" in
  write_file java_path
    {|#!/bin/sh
exit 0
|}
  ;
  Unix.chmod java_path 0o755;
  bin_dir

let test_disk_hygiene_fix_path () =
  with_temp_dir "disk-hygiene-fix" (fun dir ->
      let repo_dir = Filename.concat dir "repo" in
      let home_dir = Filename.concat dir "home" in
      let dune_log = Filename.concat dir "fake-dune.log" in
      mkdir_p repo_dir;
      mkdir_p home_dir;
      init_repo repo_dir;
      copy_script ~repo_root:repo_dir "scripts/cleanup-tlc-artifacts.sh";
      copy_script ~repo_root:repo_dir "scripts/disk-hygiene.sh";
      mkdir_p (Filename.concat repo_dir "specs/states");
      mkdir_p (Filename.concat repo_dir "specs/keeper-state-machine");
      mkdir_p (Filename.concat repo_dir "_build");
      mkdir_p (Filename.concat repo_dir "_build_extra");
      mkdir_p (Filename.concat repo_dir ".worktrees/alpha");
      write_file (Filename.concat repo_dir "specs/states/blob") "x";
      write_file
        (Filename.concat repo_dir "specs/keeper-state-machine/TraceData.tla")
        "trace";
      write_file (Filename.concat repo_dir "_build/keep") "main-build";
      write_file (Filename.concat repo_dir "_build_extra/tmp") "extra-build";
      mkdir_p (Filename.concat home_dir ".cache/dune/db/files/v4");
      write_file
        (Filename.concat home_dir ".cache/dune/db/files/v4/blob")
        (String.make 4096 'a');
      let fake_bin = install_fake_dune ~dir in
      let path =
        Printf.sprintf "%s:%s" fake_bin
          (match Sys.getenv_opt "PATH" with Some p -> p | None -> "")
      in
      let env =
        [
          ("HOME", home_dir);
          ("PATH", path);
          ("FAKE_DUNE_LOG", dune_log);
          ("MASC_DISK_HYGIENE_DUNE_CACHE_WARN_MB", "1");
          ("MASC_DISK_HYGIENE_DUNE_CACHE_MISMATCH_WARN_MB", "1");
          ("MASC_DISK_HYGIENE_TLC_WARN_MB", "1");
          ("MASC_DISK_HYGIENE_EXTRA_BUILD_WARN_MB", "1");
          ("MASC_DISK_HYGIENE_WORKTREE_WARN_COUNT", "5");
        ]
      in
      let script = Filename.concat repo_dir "scripts/disk-hygiene.sh" in
      let code1, stdout1, stderr1 =
        run_shell ~cwd:repo_dir ~env
          (Printf.sprintf "%s" (quote script))
      in
      check bool "warn-only run returns nonzero" true (code1 <> 0);
      check bool "reports dune cache warning" true
        (contains_substring stdout1 "dune_cache");
      check bool "reports tlc artefacts warning" true
        (contains_substring stdout1 "tlc_artifacts");
      check bool "reports build dirs warning" true
        (contains_substring stdout1 "build_dirs");
      check bool "stderr empty on report run" true (String.trim stderr1 = "");

      let code2, stdout2, stderr2 =
        run_shell ~cwd:repo_dir ~env
          (Printf.sprintf "%s --fix --reset-dune-cache --clean-extra-build-dirs"
             (quote script))
      in
      if code2 <> 0 then
        failf "disk hygiene fix failed (%d)\nstdout:\n%s\nstderr:\n%s"
          code2 stdout2 stderr2;
      check bool "trace data removed" false
        (Sys.file_exists
           (Filename.concat repo_dir "specs/keeper-state-machine/TraceData.tla"));
      check bool "states dir removed" false
        (Sys.file_exists (Filename.concat repo_dir "specs/states"));
      check bool "extra build dir removed" false
        (Sys.file_exists (Filename.concat repo_dir "_build_extra"));
      check bool "main _build preserved" true
        (Sys.file_exists (Filename.concat repo_dir "_build"));
      check bool "dune cache reset removed cache dir" false
        (Sys.file_exists (Filename.concat home_dir ".cache/dune"));
      let dune_log_contents = read_file dune_log in
      check bool "trim invoked with default size" true
        (contains_substring dune_log_contents "cache trim --size=20GB");
      check bool "post-fix summary printed" true
        (contains_substring stdout2 "Post-fix:");
      check bool "post-fix summary is clean" true
        (contains_substring stdout2 "summary ok=4 warn=0"))

let test_tla_check_cleans_generated_artifacts_by_default () =
  with_temp_dir "tla-check-cleanup" (fun dir ->
      let repo_dir = Filename.concat dir "repo" in
      let tlc_dir = Filename.concat dir "tlc" in
      let java_bin = install_fake_java ~dir in
      mkdir_p repo_dir;
      init_repo repo_dir;
      copy_script ~repo_root:repo_dir "scripts/cleanup-tlc-artifacts.sh";
      copy_script ~repo_root:repo_dir "scripts/tla-check.sh";
      mkdir_p (Filename.concat repo_dir "specs/states");
      mkdir_p (Filename.concat repo_dir "specs/keeper-state-machine");
      write_file (Filename.concat repo_dir "specs/states/blob") "x";
      write_file
        (Filename.concat repo_dir "specs/keeper-state-machine/TraceData.tla")
        "trace";
      write_file
        (Filename.concat repo_dir "specs/keeper-state-machine/Foo_TTrace_1.tla")
        "trace";
      mkdir_p tlc_dir;
      write_file (Filename.concat tlc_dir "tla2tools-1.8.0.jar") "jar";
      let path =
        Printf.sprintf "%s:%s" java_bin
          (match Sys.getenv_opt "PATH" with Some p -> p | None -> "")
      in
      let env = [ ("PATH", path); ("TLC_DIR", tlc_dir) ] in
      let script = Filename.concat repo_dir "scripts/tla-check.sh" in
      let code, stdout, stderr =
        run_shell ~cwd:repo_dir ~env (Printf.sprintf "%s" (quote script))
      in
      if code <> 0 then
        failf "tla-check failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      check bool "cleanup message emitted" true
        (contains_substring stdout "cleanup-tlc-artifacts:");
      check bool "states dir removed" false
        (Sys.file_exists (Filename.concat repo_dir "specs/states"));
      check bool "trace data removed" false
        (Sys.file_exists
           (Filename.concat repo_dir "specs/keeper-state-machine/TraceData.tla")))

let test_tla_check_respects_keep_tlc_artifacts () =
  with_temp_dir "tla-check-keep" (fun dir ->
      let repo_dir = Filename.concat dir "repo" in
      let tlc_dir = Filename.concat dir "tlc" in
      let java_bin = install_fake_java ~dir in
      mkdir_p repo_dir;
      init_repo repo_dir;
      copy_script ~repo_root:repo_dir "scripts/cleanup-tlc-artifacts.sh";
      copy_script ~repo_root:repo_dir "scripts/tla-check.sh";
      mkdir_p (Filename.concat repo_dir "specs/states");
      mkdir_p (Filename.concat repo_dir "specs/keeper-state-machine");
      write_file (Filename.concat repo_dir "specs/states/blob") "x";
      write_file
        (Filename.concat repo_dir "specs/keeper-state-machine/TraceData.tla")
        "trace";
      mkdir_p tlc_dir;
      write_file (Filename.concat tlc_dir "tla2tools-1.8.0.jar") "jar";
      let path =
        Printf.sprintf "%s:%s" java_bin
          (match Sys.getenv_opt "PATH" with Some p -> p | None -> "")
      in
      let env =
        [ ("PATH", path); ("TLC_DIR", tlc_dir); ("KEEP_TLC_ARTIFACTS", "1") ]
      in
      let script = Filename.concat repo_dir "scripts/tla-check.sh" in
      let code, stdout, stderr =
        run_shell ~cwd:repo_dir ~env (Printf.sprintf "%s" (quote script))
      in
      if code <> 0 then
        failf "tla-check failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout
          stderr;
      check bool "preserve message emitted" true
        (contains_substring stdout "KEEP_TLC_ARTIFACTS=1");
      check bool "states dir preserved" true
        (Sys.file_exists (Filename.concat repo_dir "specs/states"));
      check bool "trace data preserved" true
        (Sys.file_exists
           (Filename.concat repo_dir "specs/keeper-state-machine/TraceData.tla")))

let test_makefile_exposes_disk_hygiene_targets () =
  let makefile = read_file (Filename.concat (source_root ()) "Makefile") in
  check bool "doctor target exists" true
    (contains_substring makefile "doctor-disk-hygiene:");
  check bool "safe fix target exists" true
    (contains_substring makefile "fix-disk-hygiene:");
  check bool "hard fix target exists" true
    (contains_substring makefile "fix-disk-hygiene-hard:");
  check bool "clean target runs tlc cleanup" true
    (contains_substring makefile "bash scripts/cleanup-tlc-artifacts.sh")

let () =
  run "disk_hygiene_script"
    [
      ( "script",
        [
          test_case "disk hygiene fixes tlc cache and extra builds" `Quick
            test_disk_hygiene_fix_path;
          test_case "tla-check cleans artefacts by default" `Quick
            test_tla_check_cleans_generated_artifacts_by_default;
          test_case "tla-check keep flag preserves artefacts" `Quick
            test_tla_check_respects_keep_tlc_artifacts;
          test_case "makefile exposes disk hygiene targets" `Quick
            test_makefile_exposes_disk_hygiene_targets;
        ] );
    ]
