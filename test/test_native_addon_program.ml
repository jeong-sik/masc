(* The host programs native Add-ons run through: their names and the lookup
   the server and [masc browser-lane-setup] share. Every case runs with PATH
   set to a scratch directory. *)
open Alcotest

module P = Masc.Native_addon_program

let with_directory f =
  let dir = Filename.temp_file "native-addon-program" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let rec remove path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun entry -> remove (Filename.concat path entry)) (Sys.readdir path);
      (try Unix.rmdir path with Unix.Unix_error _ -> ())
    | _ -> (try Sys.remove path with Sys_error _ -> ())
    | exception Unix.Unix_error _ -> ()
  in
  Fun.protect ~finally:(fun () -> remove dir) (fun () -> f (Unix.realpath dir))

(* The stdlib has no unsetenv, so a PATH that was unset comes back as the
   empty string; no later case in this executable reads it. *)
let with_path value f =
  let previous = Sys.getenv_opt "PATH" in
  Unix.putenv "PATH" value;
  Fun.protect ~finally:(fun () -> Unix.putenv "PATH" (Option.value previous ~default:"")) f

let executable path =
  Out_channel.with_open_bin path (fun out -> output_string out "#!/bin/sh\nexit 0\n");
  Unix.chmod path 0o755

let test_every_program_has_its_own_name () =
  let names = List.map P.name P.all in
  check int "one name per program" (List.length P.all)
    (List.length (List.sort_uniq String.compare names))

let test_locate_reads_path () =
  with_directory (fun dir ->
    with_path dir (fun () ->
      List.iter
        (fun program ->
           (match P.locate program with
            | Ok path -> failf "found %s with only an empty directory on PATH" path
            | Error message ->
              check bool "the refusal names the program" true
                (String_util.contains_substring message (P.name program)));
           let path = Filename.concat dir (P.name program) in
           executable path;
           check (result string string) "found on PATH" (Ok (Unix.realpath path)) (P.locate program))
        P.all))

let test_command_ready_reads_the_package_for_a_relative_path () =
  with_directory (fun dir ->
    with_path dir (fun () ->
      check bool "an absent command" false (P.command_ready ~package_directory:dir "worker");
      executable (Filename.concat dir "worker");
      check bool "a bare command is looked up on PATH" true
        (P.command_ready ~package_directory:"/nonexistent" "worker");
      let package = Filename.concat dir "package" in
      Unix.mkdir package 0o700;
      Unix.mkdir (Filename.concat package "bin") 0o700;
      executable (Filename.concat package "bin/run");
      check bool "a relative path is read from the package" true
        (P.command_ready ~package_directory:package "bin/run");
      check bool "and from no other directory" false
        (P.command_ready ~package_directory:dir "bin/run")))

let () =
  run "native_addon_program"
    [ ( "programs"
      , [ test_case "every program has its own name" `Quick test_every_program_has_its_own_name
        ; test_case "locate reads PATH" `Quick test_locate_reads_path
        ; test_case "a relative command is read from the package" `Quick
            test_command_ready_reads_the_package_for_a_relative_path
        ] )
    ]
