(** test_fs_compat.ml - Fs_compat safety + behavior tests

    Focus: ensure mkdir_p fallback does not invoke a shell and correctly creates
    nested directories with tricky path characters.
*)

open Alcotest

let rec rm_rf (path : string) : unit =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_tmp_dir (f : string -> unit) : unit =
  let tmp = Filename.temp_file "masc_fs_compat_" ".tmp" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () -> f tmp)
;;

let test_mkdir_p_creates_nested_dirs () =
  Fs_compat.clear_fs ();
  with_tmp_dir
  @@ fun base ->
  let path = Filename.concat base "a/b/c" in
  Fs_compat.mkdir_p path;
  check bool "created leaf dir" true (Sys.file_exists path && Sys.is_directory path)
;;

let test_mkdir_p_does_not_shell_inject () =
  Fs_compat.clear_fs ();
  with_tmp_dir
  @@ fun base ->
  let pwned = Filename.concat base "pwned" in
  let dangerous = Filename.concat base ("dir;touch " ^ pwned ^ "/x") in
  Fs_compat.mkdir_p dangerous;
  (* If mkdir_p used a shell (`mkdir -p <path>`), this would create pwned. *)
  check bool "no shell side-effect file created" false (Sys.file_exists pwned);
  check
    bool
    "dangerous path exists"
    true
    (Sys.file_exists dangerous && Sys.is_directory dangerous)
;;

let test_save_file_atomic_leaves_no_tmp_on_success () =
  Fs_compat.clear_fs ();
  with_tmp_dir
  @@ fun base ->
  let target = Filename.concat base "out.json" in
  (match Fs_compat.save_file_atomic target {|{"ok":true}|} with
   | Ok () -> ()
   | Error msg -> fail msg);
  check bool "target exists" true (Sys.file_exists target);
  check string "content matches" {|{"ok":true}|} (Fs_compat.load_file target);
  let leftover_tmps =
    Sys.readdir base
    |> Array.to_list
    |> List.filter (fun n -> String.length n >= 8 && String.sub n 0 8 = ".atomic_")
  in
  check (list string) "no leftover .atomic_ tmp files" [] leftover_tmps
;;

let test_save_file_atomic_overwrites_existing () =
  Fs_compat.clear_fs ();
  with_tmp_dir
  @@ fun base ->
  let target = Filename.concat base "out.json" in
  Fs_compat.save_file target "old";
  (match Fs_compat.save_file_atomic target "new" with
   | Ok () -> ()
   | Error msg -> fail msg);
  check string "overwrite succeeded" "new" (Fs_compat.load_file target)
;;

let () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  run
    "fs_compat"
    [ ( "mkdir_p"
      , [ test_case "creates nested dirs" `Quick test_mkdir_p_creates_nested_dirs
        ; test_case "no shell injection" `Quick test_mkdir_p_does_not_shell_inject
        ] )
    ; ( "save_file_atomic"
      , [ test_case
            "leaves no .atomic_ tmp on success"
            `Quick
            test_save_file_atomic_leaves_no_tmp_on_success
        ; test_case
            "overwrites existing target"
            `Quick
            test_save_file_atomic_overwrites_existing
        ] )
    ]
;;
