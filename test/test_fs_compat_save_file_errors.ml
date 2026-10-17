(* A write error must reach the caller of save_file and the atomic writers.
   The channel keeps up to 64 KiB, so the end of a smaller file reaches the
   kernel at the final flush, and that flush used to run under
   [close_out_noerr]. A full disk then gave a truncated temp file that was
   fsynced and renamed over a good one.

   A full disk cannot be made on demand, and /dev/full does not exist on
   macOS. A descriptor opened read-only fails every write with EBADF on both
   systems, so the writer is handed one. *)

open Alcotest

let temp_file contents =
  let path = Filename.temp_file "masc-save-file-errors-" ".dat" in
  Out_channel.with_open_bin path (fun oc -> output_string oc contents);
  path
;;

let read path = In_channel.with_open_bin path In_channel.input_all

let fd_is_closed fd =
  match Unix.fstat fd with
  | _ -> false
  | exception Unix.Unix_error (Unix.EBADF, _, _) -> true
;;

let raises_sys_error name content =
  let path = temp_file "original" in
  Fun.protect
    ~finally:(fun () -> Sys.remove path)
    (fun () ->
      let fd = Unix.openfile path [ Unix.O_RDONLY ] 0 in
      (match Fs_compat.write_all_and_close fd content with
       | () -> failf "%s: the write to a descriptor that cannot be written succeeded" name
       | exception Sys_error _ -> ());
      check bool (name ^ ": the descriptor is closed") true (fd_is_closed fd);
      check string (name ^ ": the file is as it was") "original" (read path))
;;

(* Below the buffer size nothing reaches the kernel until the final flush. *)
let test_a_small_write_reports_its_flush () = raises_sys_error "small" "tail of a small file"

(* Past it, output_string flushes as it goes and fails earlier. *)
let test_a_large_write_reports_its_error () =
  raises_sys_error "large" (String.make (1024 * 1024) 'x')
;;

let test_a_good_write_lands_and_closes () =
  let path = Filename.temp_file "masc-save-file-errors-" ".dat" in
  Fun.protect
    ~finally:(fun () -> Sys.remove path)
    (fun () ->
      let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0 in
      Fs_compat.write_all_and_close fd "complete";
      check string "the content landed" "complete" (read path);
      check bool "the descriptor is closed" true (fd_is_closed fd))
;;

(* The public writers still report an open failure the same way. *)
let test_save_file_reports_an_unopenable_path () =
  let missing = Filename.concat (Filename.temp_dir "masc-save-file-errors-" "") "no/such/dir/f" in
  match Fs_compat.save_file missing "x" with
  | () -> fail "save_file wrote under a directory that does not exist"
  | exception Sys_error _ | exception Unix.Unix_error _ -> ()
;;

let () =
  run "Fs_compat save_file errors"
    [ ( "writer"
      , [ test_case "a small write reports its flush" `Quick test_a_small_write_reports_its_flush
        ; test_case "a large write reports its error" `Quick test_a_large_write_reports_its_error
        ; test_case "a good write lands and closes" `Quick test_a_good_write_lands_and_closes
        ; test_case "save_file reports an unopenable path" `Quick
            test_save_file_reports_an_unopenable_path
        ] )
    ]
;;
