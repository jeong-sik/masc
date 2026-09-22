(* Where an official client runs from: the one lookup the runtime spawns with,
   the vendor installer checks with and the setup wizard shows (masc #37747).
   Each case builds a HOME with the shape the vendor installer leaves --
   ~/.local/bin/claude as a link into a versioned directory -- and sets PATH
   for the process, so what is checked is the file system, not a mock. *)
open Alcotest
module Install = Runtime_official_cli_install

let executable path =
  Out_channel.with_open_text path (fun oc -> output_string oc "#!/bin/sh\necho fixture\n");
  Unix.chmod path 0o700
;;

let with_home f =
  let home = Filename.temp_dir "official-client-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree home) (fun () ->
    Masc_test_deps.with_process_env "HOME" (Some home) (fun () ->
      Masc_test_deps.with_process_env "CODEX_INSTALL_DIR" None (fun () -> f home)))
;;

let with_path directories f =
  Masc_test_deps.with_process_env "PATH" (Some (String.concat ":" directories)) f
;;

(* The installer's layout: the link in ~/.local/bin, the file under versions. *)
let installed_claude home =
  let versions = Filename.concat home ".local/share/claude/versions/2.0.0" in
  Fs_compat.mkdir_p versions;
  Fs_compat.mkdir_p (Filename.concat home ".local/bin");
  let target = Filename.concat versions "claude" in
  executable target;
  let link = Filename.concat home ".local/bin/claude" in
  Unix.symlink target link;
  link, target
;;

let test_the_vendor_directory_when_path_has_no_client () =
  with_home @@ fun home ->
  let link, target = installed_claude home in
  let empty = Filename.concat home "empty" in
  Fs_compat.mkdir_p empty;
  with_path [ empty ] @@ fun () ->
  check (option string) "found where the installer wrote it" (Some link)
    (Install.locate Install.Claude ~command:"claude");
  check bool "as the link, not its target" true
    (Install.locate Install.Claude ~command:"claude" <> Some target);
  check string "and that is what the runtime spawns" link
    (Install.spawn_path Install.Claude ~command:"claude")
;;

let test_path_first_as_the_shell_finds_it () =
  with_home @@ fun home ->
  let _link, _target = installed_claude home in
  let elsewhere = Filename.concat home "elsewhere" in
  Fs_compat.mkdir_p elsewhere;
  let on_path = Filename.concat elsewhere "claude" in
  executable on_path;
  with_path [ elsewhere ] @@ fun () ->
  check (option string) "PATH wins over the vendor directory" (Some on_path)
    (Install.locate Install.Claude ~command:"claude")
;;

let test_a_custom_name_is_not_looked_for_in_the_vendor_directory () =
  with_home @@ fun home ->
  Fs_compat.mkdir_p (Filename.concat home ".local/bin");
  executable (Filename.concat home ".local/bin/my-claude");
  with_path [] @@ fun () ->
  check (option string) "a custom command is the operator's, found on PATH or not at all" None
    (Install.locate Install.Claude ~command:"my-claude");
  check string "the spawn is asked for what was configured" "my-claude"
    (Install.spawn_path Install.Claude ~command:"my-claude")
;;

let test_a_path_is_answered_as_given () =
  with_home @@ fun home ->
  let link, _target = installed_claude home in
  let not_executable = Filename.concat home "claude.txt" in
  Out_channel.with_open_text not_executable (fun oc -> output_string oc "text");
  with_path [] @@ fun () ->
  check (option string) "an executable path, as given" (Some link)
    (Install.locate Install.Claude ~command:link);
  check (option string) "a file nobody can run is not a client" None
    (Install.locate Install.Claude ~command:not_executable);
  check (option string) "a directory is not a client" None
    (Install.locate Install.Claude ~command:(Filename.concat home ".local/bin"));
  check (option string) "a path that is not there" None
    (Install.locate Install.Claude ~command:(Filename.concat home "missing/claude"))
;;

(* A shell reads "." against the directory it is in; masc spawns from a
   keeper's own directory, where the same entry names somewhere else. *)
let test_a_relative_path_entry_is_not_searched () =
  with_home @@ fun home ->
  let here = Filename.concat home "here" in
  Fs_compat.mkdir_p here;
  executable (Filename.concat here "claude");
  let cwd = Sys.getcwd () in
  Sys.chdir here;
  Fun.protect ~finally:(fun () -> Sys.chdir cwd) @@ fun () ->
  with_path [ "."; "bin" ] @@ fun () ->
  check (option string) "a relative entry is no place to spawn from" None
    (Install.locate Install.Claude ~command:"claude");
  with_path [ here ] @@ fun () ->
  check (option string) "the same directory, named absolutely"
    (Some (Filename.concat here "claude"))
    (Install.locate Install.Claude ~command:"claude")
;;

let test_a_file_nobody_can_run_is_not_found () =
  with_home @@ fun home ->
  Fs_compat.mkdir_p (Filename.concat home ".local/bin");
  let claude = Filename.concat home ".local/bin/claude" in
  Out_channel.with_open_text claude (fun oc -> output_string oc "#!/bin/sh\n");
  Unix.chmod claude 0o600;
  with_path [] @@ fun () ->
  check (option string) "present but not executable" None
    (Install.locate Install.Claude ~command:"claude")
;;

let test_codex_install_dir_replaces_the_vendor_directory () =
  with_home @@ fun home ->
  Fs_compat.mkdir_p (Filename.concat home ".local/bin");
  executable (Filename.concat home ".local/bin/codex");
  let custom = Filename.concat home "codex-home" in
  Fs_compat.mkdir_p custom;
  with_path [] @@ fun () ->
  check (option string) "without CODEX_INSTALL_DIR, ~/.local/bin"
    (Some (Filename.concat home ".local/bin/codex"))
    (Install.locate Install.Codex ~command:"codex");
  Masc_test_deps.with_process_env "CODEX_INSTALL_DIR" (Some custom) @@ fun () ->
  check (option string) "with it, only that directory" None
    (Install.locate Install.Codex ~command:"codex");
  executable (Filename.concat custom "codex");
  check (option string) "where the Codex installer was told to write"
    (Some (Filename.concat custom "codex"))
    (Install.locate Install.Codex ~command:"codex");
  check (option string) "and Claude Code does not read it"
    None
    (Install.locate Install.Claude ~command:"claude")
;;

let () =
  run
    "runtime_official_cli_install"
    [ ( "locate"
      , [ test_case "the vendor directory when PATH has no client" `Quick
            test_the_vendor_directory_when_path_has_no_client
        ; test_case "PATH first, as the shell finds it" `Quick
            test_path_first_as_the_shell_finds_it
        ; test_case "a custom name is not looked for in the vendor directory" `Quick
            test_a_custom_name_is_not_looked_for_in_the_vendor_directory
        ; test_case "a path is answered as given" `Quick test_a_path_is_answered_as_given
        ; test_case "a relative PATH entry is not searched" `Quick
            test_a_relative_path_entry_is_not_searched
        ; test_case "a file nobody can run is not found" `Quick
            test_a_file_nobody_can_run_is_not_found
        ; test_case "CODEX_INSTALL_DIR replaces the vendor directory" `Quick
            test_codex_install_dir_replaces_the_vendor_directory
        ] )
    ]
;;
