(** A writer that makes its own directory makes it again after the directory
    was removed, by whatever call removed it (#53279).

    Each case writes one row, removes the directory with plain [unlink] and
    [rmdir] — the calls the dashboard's Keeper purge removes a directory
    with, which tell [Fs_compat] nothing — and writes another row. *)

open Alcotest

let made = ref 0

let fresh_root () =
  incr made;
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "fs_compat_writers_%d_%d" (Unix.getpid ()) !made)
  in
  Unix.mkdir root 0o755;
  root
;;

let remove_with_plain_calls dir =
  Array.iter (fun name -> Unix.unlink (Filename.concat dir name)) (Sys.readdir dir);
  Unix.rmdir dir
;;

let succeeded ~describe = function
  | Fs_compat.Private_file_succeeded value -> value
  | Fs_compat.Private_file_failed error -> failf "the write failed: %s" (describe error)
  | Fs_compat.Private_file_succeeded_with_cleanup_failure _
  | Fs_compat.Private_file_failed_with_cleanup_failure _ ->
    fail "the descriptor was not settled"
;;

(* Every public writer that makes its directory, as "write this one row". *)
let writers : (string * (string -> string -> unit)) list =
  [ ( "append_jsonl"
    , fun path row -> Fs_compat.append_jsonl path (Yojson.Safe.from_string row) )
  ; ("append_jsonl_rows", fun path row -> Fs_compat.append_jsonl_rows path (row ^ "\n"))
  ; ( "append_jsonl_batch"
    , fun path row -> Fs_compat.append_jsonl_batch path [ Yojson.Safe.from_string row ] )
  ; ( "update_private_file_durable_locked_result"
    , fun path row ->
        Fs_compat.update_private_file_durable_locked_result path (fun _existing ->
          Some (row ^ "\n"), ())
        |> succeeded ~describe:Fs_compat.durable_append_error_to_string )
  ; ( "rewrite_private_file_durable_locked_result"
    , fun path row ->
        match
          Fs_compat.rewrite_private_file_durable_locked_result path (fun _existing ->
            Some (row ^ "\n"), ())
        with
        | Ok () -> ()
        | Error message -> failf "the rewrite failed: %s" message )
  ; ( "append_private_jsonl_durable_locked_at_end_offset_result"
    , fun path row ->
        let (_ : int) =
          Fs_compat.append_private_jsonl_durable_locked_at_end_offset_result
            path
            ~expected_end_offset:0
            (row ^ "\n")
          |> succeeded ~describe:Fs_compat.private_jsonl_append_error_to_string
        in
        () )
  ]
;;

let first_row = {|{"row":1}|}
let second_row = {|{"row":2}|}

(* Both levels go, so the second write makes a chain of directories and not
   only the last one. *)
let written_again write =
  let root = fresh_root () in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree root)
    (fun () ->
      let kept = Filename.concat root "kept" in
      let month = Filename.concat kept "2026-11" in
      let path = Filename.concat month "rows.jsonl" in
      write path first_row;
      check string "the first row" (first_row ^ "\n") (Fs_compat.load_file path);
      remove_with_plain_calls month;
      Unix.rmdir kept;
      write path second_row;
      check
        string
        "the file made again holds the second row alone"
        (second_row ^ "\n")
        (Fs_compat.load_file path))
;;

let in_eio f () =
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    Fun.protect ~finally:Fs_compat.clear_fs f)
;;

(* The two transactions that made their directory before their blocking job
   now make it inside the job. A directory whose making fails — a regular
   file is on the way above it — is a [Sys_error] in a fiber and outside
   one. *)
let directory_that_cannot_be_made write () =
  let root = fresh_root () in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree root)
    (fun () ->
      let in_the_way = Filename.concat root "kept" in
      Fs_compat.save_file in_the_way "a regular file where the directory would be";
      let path = Filename.concat (Filename.concat in_the_way "2026-11") "rows.jsonl" in
      match write path first_row with
      | () -> fail "the write went through a regular file"
      | exception Sys_error _ -> ())
;;

(* A regular file at the directory's own place causes directory creation to
   fail with [ENOTDIR], which [make_transaction_directory_in_this_job]
   normalizes to [Sys_error] for both durable update and durable rewrite, in a
   fiber and outside one (#53324). *)
let regular_file_where_the_directory_would_be ~reported write () =
  let root = fresh_root () in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree root)
    (fun () ->
      let in_the_way = Filename.concat root "kept" in
      Fs_compat.save_file in_the_way "a regular file where the directory would be";
      let path = Filename.concat in_the_way "rows.jsonl" in
      (match write path first_row with
       | () -> fail "the write went through a regular file"
       | exception raised ->
         if not (reported raised)
         then failf "reported as %s" (Printexc.to_string raised));
      check
        string
        "the file in the way is as it was"
        "a regular file where the directory would be"
        (Fs_compat.load_file in_the_way))
;;

let transactions_that_report_sys_error =
  List.filter
    (fun (name, _) ->
      String.equal name "update_private_file_durable_locked_result"
      || String.equal name "rewrite_private_file_durable_locked_result")
    writers
;;

let () =
  Alcotest.run
    "fs_compat_writers_make_their_directory"
    [ ( "outside a fiber"
      , List.map
          (fun (name, write) ->
            test_case (name ^ " writes again") `Quick (fun () -> written_again write))
          writers )
    ; ( "in a fiber"
      , List.map
          (fun (name, write) ->
            test_case
              (name ^ " writes again")
              `Quick
              (in_eio (fun () -> written_again write)))
          writers )
    ; ( "a directory that cannot be made"
      , List.concat_map
          (fun (name, write) ->
            [ test_case (name ^ " outside a fiber") `Quick
                (directory_that_cannot_be_made write)
            ; test_case (name ^ " in a fiber") `Quick
                (in_eio (directory_that_cannot_be_made write))
            ])
          transactions_that_report_sys_error )
    ; ( "a regular file where the directory would be"
      , List.concat_map
          (fun (name, reported) ->
            let write = List.assoc name writers in
            [ test_case (name ^ " outside a fiber") `Quick
                (regular_file_where_the_directory_would_be ~reported write)
            ; test_case (name ^ " in a fiber") `Quick
                (in_eio (regular_file_where_the_directory_would_be ~reported write))
            ])
          [ ( "update_private_file_durable_locked_result"
            , function
              | Sys_error _ -> true
              | _ -> false )
          ; ( "rewrite_private_file_durable_locked_result"
            , function
              | Sys_error _ -> true
              | _ -> false )
          ] )
    ]
;;
