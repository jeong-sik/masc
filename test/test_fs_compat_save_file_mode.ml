(** [save_file] creates with the same mode whichever branch runs.

    The Eio path passed `0o644` and the Unix fallback used
    [Stdlib.open_out], which creates with 0o666 masked by the process umask.
    Which branch runs is whether an Eio fs happens to be installed — nothing
    about the file — so the same call produced a different mode depending on
    the caller's context (#29358). *)

let expected_mode = 0o644

let mode_of path = (Unix.stat path).Unix.st_perm

let temp_path suffix =
  Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc-save-file-mode-%d-%s" (Unix.getpid ()) suffix)

(* The umask has to leave the two apart. Under 0o077 both 0o666 (what
   Stdlib.open_out asks for) and 0o644 (what Eio asks for) land on 0o600, so
   that umask hides exactly the difference being tested. 0o022 keeps them
   apart: 0o666 -> 0o644 and 0o644 -> 0o644 agree, while the group-write bit
   is what separates them under a looser one. 0o002 is the mask that shows
   it: 0o666 -> 0o664, 0o644 -> 0o644. *)
let with_umask mask f =
  let previous = Unix.umask mask in
  Fun.protect ~finally:(fun () -> ignore (Unix.umask previous)) f

(* The property is that the two branches agree, not that either produces a
   particular number: both go through the umask, so the absolute mode
   depends on the process that ran. Asserting 0o644 here would pass only
   under a permissive umask and say nothing about the branches matching. *)
let test_both_branches_create_the_same_mode () =
  with_umask 0o002 (fun () ->
    let fallback_path = temp_path "fallback" in
    let eio_path = temp_path "eio" in
    Fun.protect
      ~finally:(fun () ->
        Fs_compat.clear_fs ();
        List.iter
          (fun p -> try Sys.remove p with Sys_error _ -> ())
          [ fallback_path; eio_path ])
      (fun () ->
         Fs_compat.clear_fs ();
         Fs_compat.save_file fallback_path "written without an Eio fs";
         let fallback_mode = mode_of fallback_path in
         Eio_main.run (fun env ->
           Fs_compat.set_fs (Eio.Stdenv.fs env);
           Fs_compat.save_file eio_path "written through Eio");
         let eio_mode = mode_of eio_path in
         Alcotest.(check int)
           (Printf.sprintf
              "fallback 0o%o and eio 0o%o must agree"
              fallback_mode
              eio_mode)
           eio_mode
           fallback_mode;
         (* And the declared mode is what they agree on before the umask
            takes its bits: 0o644 masked by 0o077 is 0o600. *)
         Alcotest.(check int)
           "the shared mode is the declared one, masked"
           (expected_mode land lnot 0o002)
           fallback_mode))
;;

let () =
  Alcotest.run "fs_compat_save_file_mode"
    [ ( "save_file"
      , [ Alcotest.test_case "both branches create the same mode" `Quick
            test_both_branches_create_the_same_mode
        ] )
    ]
