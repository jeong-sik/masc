open Alcotest

let contains s sub =
  let rec aux i =
    if i > String.length s - String.length sub then false
    else if String.sub s i (String.length sub) = sub then true
    else aux (i + 1)
  in
  aux 0

let check_contains msg needle haystack =
  check bool msg true (contains haystack needle)

let temp_dir () = Filename.temp_file "test_" "" ^ "_dir"

let rec mkdir_p path =
  if path = "" || Sys.file_exists path then ()
  else (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755)

let cleanup_dir path =
  let rec rm path =
    if Sys.is_directory path then (
      Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
  in
  if Sys.file_exists path then rm path

let run_ok ~cwd cmd =
  let status = Sys.command (Printf.sprintf "cd %s && %s" (Filename.quote cwd) cmd) in
  if status <> 0 then failwith (Printf.sprintf "Command failed: %s" cmd)

let test_auto_provision_rejects_plain_dir_clone_conflict () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  mkdir_p base_path;
  run_ok ~cwd:base_path "git init -q -b main";
  let source_repo = Filename.concat base_path "workspace/yousleepwhen/masc-mcp" in
  mkdir_p (Filename.dirname source_repo);
  run_ok ~cwd:base_path
    (Printf.sprintf "git init -q -b main %s" (Filename.quote source_repo));
  let repos_dir = Filename.concat base_path ".masc/playground/test-agent/repos" in
  mkdir_p repos_dir;
  let conflict_path = Filename.concat repos_dir "masc-mcp" in
  mkdir_p conflict_path;
  let config = Masc_mcp.Coord.default_config base_path in
  ignore (Masc_mcp.Coord.init config ~agent_name:(Some "test-agent"));
  match
    Masc_mcp.Coord.auto_provision_sandbox_clone ~config
      ~agent_name:"test-agent" ~repos_dir ~repo_name:"masc-mcp"
  with
  | Ok _ -> fail "expected sandbox_clone_conflict error"
  | Error (Types.System (Types.System_error.IoError msg)) ->
      check_contains "message mentions sandbox_clone_conflict"
        "sandbox_clone_conflict" msg;
      check_contains "message mentions not a git clone" "not a git clone" msg
  | Error err ->
      fail (Printf.sprintf "expected IoError, got: %s" (Types.masc_error_to_string err))

let () =
  run "Sandbox clone conflict"
    [
      ( "auto_provision",
        [
          test_case "plain directory at sandbox clone path is rejected" `Quick
            test_auto_provision_rejects_plain_dir_clone_conflict;
        ] );
    ]
