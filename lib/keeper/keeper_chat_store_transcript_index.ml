open Keeper_chat_store_provenance_index

(* One in-process state per transcript path: the provenance index of the rows
   read so far, and where in which file that reading ended. The file is the
   durable log and the index is derived from it, so losing the state costs one
   read of the whole file and nothing else.

   Every append-once delivery needs the index of every row. Reading the whole
   transcript for each one costs a read and a JSON parse of every row: 1.38 s
   for a 31 MiB transcript of 27,161 rows in a standalone read, split and
   parse (2026-11-10, #50986). The update below reads only the rows after
   [rows_end]. *)
type folded =
  { rows_end : Fs_compat.Private_jsonl_cursor.t
    (* file identity and the end of the last row in [index] *)
  ; row_count : int
    (* newlines before [rows_end]; the next row is line [row_count + 1] *)
  ; index : provenance_index
  }

type entry =
  { mutex : Cross_context_mutex.t
  ; mutable folded : folded option
    (* [None]: unknown; the next update reads the file from its first row *)
  }

let registry : (string, entry) Hashtbl.t = Hashtbl.create 16

(* Guards only the table lookup, which never yields. The per-path mutex is
   held by a fiber across the whole update, whose file work runs in a system
   thread, so it is a [Cross_context_mutex]: a second fiber waits on its Eio
   gate and does not block its domain (#33322). *)
let registry_mutex = Stdlib.Mutex.create ()

let entry_of path =
  Stdlib.Mutex.protect registry_mutex (fun () ->
    match Hashtbl.find_opt registry path with
    | Some entry -> entry
    | None ->
      let entry = { mutex = Cross_context_mutex.create (); folded = None } in
      Hashtbl.add registry path entry;
      entry)
;;

(* Under [entry.mutex] and the file lock, in the update's blocking worker.
   Brings the entry's index up to the rows the update read and answers with
   the index of every row in the file. *)
let index_of_file entry (file : folded Fs_compat.private_jsonl_rows_from_cursor) =
  let row_count, index =
    match file.Fs_compat.read with
    | Fs_compat.Rows_after_cursor folded -> folded.row_count, folded.index
    | Fs_compat.Rows_from_start ->
      (* Nothing was kept, or it was kept from another file. *)
      0, empty_provenance_index ()
  in
  (* An index is kept only by an update that took every byte it read as whole
     rows. One that meets a row it cannot read, or that raises while the rows
     go in, leaves the next update a read of the whole file: a transcript that
     refuses deliveries is answered from the file each time, and so is its
     first delivery after a repair. *)
  entry.folded <- None;
  let open Result.Syntax in
  let* rows = scan_transcript_rows ~first_line:(row_count + 1) file.Fs_compat.rows in
  List.iter (add_scanned_provenance index) rows.scanned;
  let row_count = row_count + rows.newlines in
  let* tail =
    scan_transcript_rows ~first_line:(row_count + 1) file.Fs_compat.incomplete_tail
  in
  match tail.scanned with
  | [] ->
    entry.folded <- Some { rows_end = file.Fs_compat.rows_end; row_count; index };
    Ok index
  | _ :: _ ->
    (* The file ends inside a row that reads as one. The answer counts that
       row, but [index] then holds a row that ends past [rows_end], so it is
       not kept. *)
    List.iter (add_scanned_provenance index) tail.scanned;
    Ok index
;;

let update_indexed_transcript path decide =
  let entry = entry_of path in
  Cross_context_mutex.with_lock entry.mutex (fun () ->
    Fs_compat.update_private_jsonl_after_cursor_durable_locked_result
      path
      ~after:(Option.map (fun folded -> folded.rows_end, folded) entry.folded)
      (fun file -> decide (index_of_file entry file)))
;;

let purge_indexed_transcript path ~remove =
  let entry = entry_of path in
  Cross_context_mutex.with_lock entry.mutex (fun () ->
    (* Keep the registry entry: a queued delivery must not take a different
       mutex after the purge. Forget the index whatever [remove] answers, since
       a failure may follow the unlink. *)
    Fun.protect ~finally:(fun () -> entry.folded <- None) (fun () -> remove path))
;;
