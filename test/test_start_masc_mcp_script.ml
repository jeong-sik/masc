open Alcotest

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

let script_path () =
  Filename.concat (source_root ()) "start-masc-mcp.sh"

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
  write_file dst (read_file src);
  Unix.chmod dst 0o755

let make_fake_eio_exe repo_root =
  let exe_path = Filename.concat repo_root "_build/default/bin/main_eio.exe" in
  mkdir_p (Filename.dirname exe_path);
  write_file exe_path
    {|
#!/bin/sh
set -eu
capture="${FAKE_CAPTURE_FILE:?}"
{
  printf 'MASC_STORAGE_TYPE=%s\n' "${MASC_STORAGE_TYPE:-}"
  printf 'SUPABASE_DB_URL=%s\n' "${SUPABASE_DB_URL:-}"
  printf 'MASC_BASE_PATH=%s\n' "${MASC_BASE_PATH:-}"
  printf 'ARGS=%s\n' "$*"
} >"$capture"
exit 0
|};
  Unix.chmod exe_path 0o755

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
        (contains_substring captured ("MASC_BASE_PATH=" ^ dir)))

let () =
  run "start_masc_mcp_script"
    [
      ( "script",
        [
          test_case "explicit env overrides repo env files" `Quick
            test_explicit_env_overrides_repo_env_files;
        ] );
    ]
