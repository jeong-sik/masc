open Keeper_chat_store_provenance_index

(* One in-process state per transcript path: the provenance index of the rows
   read so far, and where in which file that reading ended. The file is the
   durable log and the index is derived from it, so losing the state costs one
   read of the whole file and nothing else.

   Bounded O(1) LRU eviction keeps memory strictly bounded across 24h+ runs:
   - Per-Keeper row ceiling ([default_max_rows_per_keeper]) ensures a single
     31 MiB / 27,000+ row transcript never pins its 5 Hashtbls forever in RAM.
   - Fleet-wide O(1) doubly-linked LRU ([default_max_retained_indices],
     [default_max_total_rows]) evicts idle [folded] indices while preserving
     each path's [entry.mutex] identity so queued deliveries stay serialized. *)
let default_max_retained_indices = 64
let default_max_rows_per_keeper = 10_000
let default_max_total_rows = 64_000

type folded =
  { rows_end : Fs_compat.Private_jsonl_cursor.t
    (* file identity and the end of the last row in [index] *)
  ; row_count : int
    (* newlines before [rows_end]; the next row is line [row_count + 1] *)
  ; index : provenance_index
  }

type lru_node =
  { entry_ref : entry
  ; rows : int
  ; mutable prev : lru_node option
  ; mutable next : lru_node option
  }

and entry =
  { mutex : Cross_context_mutex.t
  ; mutable active_count : int
  ; mutable folded : folded option
  ; mutable lru : lru_node option
  }

let registry : (string, entry) Hashtbl.t = Hashtbl.create 16

(* Guards only table lookups, [active_count], [folded] publication/eviction,
   and the O(1) doubly-linked LRU; never yields or performs I/O. *)
let registry_mutex = Stdlib.Mutex.create ()
let lru_head : lru_node option ref = ref None
let lru_tail : lru_node option ref = ref None
let lru_count = ref 0
let lru_total_rows = ref 0
let max_retained_indices = ref default_max_retained_indices
let max_rows_per_keeper = ref default_max_rows_per_keeper
let max_total_rows = ref default_max_total_rows

(* Caller holds [registry_mutex]. *)
let lru_unlink_locked entry =
  match entry.lru with
  | None -> ()
  | Some node ->
    (match node.prev with
     | Some p -> p.next <- node.next
     | None -> lru_head := node.next);
    (match node.next with
     | Some n -> n.prev <- node.prev
     | None -> lru_tail := node.prev);
    node.prev <- None;
    node.next <- None;
    entry.lru <- None;
    lru_count := max 0 (!lru_count - 1);
    lru_total_rows := max 0 (!lru_total_rows - node.rows)
;;

let lru_push_head_locked entry rows =
  let rows = max 0 rows in
  let node = { entry_ref = entry; rows; prev = None; next = !lru_head } in
  (match !lru_head with
   | Some h -> h.prev <- Some node
   | None -> lru_tail := Some node);
  lru_head := Some node;
  entry.lru <- Some node;
  lru_count := !lru_count + 1;
  lru_total_rows := !lru_total_rows + rows
;;

let evict_excess_locked () =
  let rec loop () =
    if !lru_count > !max_retained_indices || !lru_total_rows > !max_total_rows
    then (
      match !lru_tail with
      | None -> ()
      | Some victim ->
        let e = victim.entry_ref in
        lru_unlink_locked e;
        if e.active_count = 0 then e.folded <- None;
        loop ())
  in
  loop ()
;;

let entry_of path =
  Stdlib.Mutex.protect registry_mutex (fun () ->
    match Hashtbl.find_opt registry path with
    | Some entry -> entry
    | None ->
      let entry =
        { mutex = Cross_context_mutex.create ()
        ; active_count = 0
        ; folded = None
        ; lru = None
        }
      in
      Hashtbl.add registry path entry;
      entry)
;;

let retained_index_count () =
  Stdlib.Mutex.protect registry_mutex (fun () ->
    Hashtbl.fold
      (fun _path entry acc -> if Option.is_some entry.folded then acc + 1 else acc)
      registry
      0)
;;

(* Under [entry.mutex] and the file lock, in the update's blocking worker.
   Brings the entry's index up to the rows the update read and answers with
   the index of every row in the file. *)
let index_of_file ~next_folded (file : folded Fs_compat.private_jsonl_rows_from_cursor) =
  let row_count, index =
    match file.Fs_compat.read with
    | Fs_compat.Rows_after_cursor folded -> folded.row_count, folded.index
    | Fs_compat.Rows_from_start ->
      (* Nothing was kept, or it was kept from another file. *)
      0, empty_provenance_index ()
  in
  next_folded := None;
  let open Result.Syntax in
  let* rows = scan_transcript_rows ~first_line:(row_count + 1) file.Fs_compat.rows in
  List.iter (add_scanned_provenance index) rows.scanned;
  next_folded
  := Some
       { rows_end = file.Fs_compat.rows_end
       ; row_count = row_count + rows.newlines
       ; index
       };
  Ok index
;;

let update_indexed_transcript path decide =
  let entry = entry_of path in
  (* A fiber already cancelled when it asks does nothing, as the Fs update
     alone would not start. The durable lock does not look. *)
  if Eio_guard.is_eio_fiber () then Eio.Fiber.check ();
  Cross_context_mutex.with_durable_lock entry.mutex (fun () ->
    let initial_folded =
      Stdlib.Mutex.protect registry_mutex (fun () ->
        entry.active_count <- entry.active_count + 1;
        lru_unlink_locked entry;
        entry.folded)
    in
    let next_folded = ref None in
    Fun.protect
      ~finally:(fun () ->
        Stdlib.Mutex.protect registry_mutex (fun () ->
          entry.active_count <- max 0 (entry.active_count - 1);
          (match !next_folded with
           | Some folded
             when folded.row_count <= !max_rows_per_keeper
                  && !max_retained_indices > 0
                  && !max_total_rows > 0 ->
             entry.folded <- Some folded;
             if entry.active_count = 0 then lru_push_head_locked entry folded.row_count
           | Some _ | None ->
             entry.folded <- None;
             lru_unlink_locked entry);
          evict_excess_locked ()))
      (fun () ->
         Fs_compat.update_private_jsonl_after_cursor_durable_locked_result
           path
           ~after:(Option.map (fun folded -> folded.rows_end, folded) initial_folded)
           (fun file -> decide (index_of_file ~next_folded file))))
;;

let purge_indexed_transcript path ~remove =
  let entry = entry_of path in
  Cross_context_mutex.with_durable_lock entry.mutex (fun () ->
    Stdlib.Mutex.protect registry_mutex (fun () ->
      entry.active_count <- entry.active_count + 1;
      lru_unlink_locked entry;
      entry.folded <- None);
    (* Keep the registry entry: a queued delivery must not take a different
       mutex after the purge. Forget the index whatever [remove] answers, since
       a failure may follow the unlink. *)
    Fun.protect
      ~finally:(fun () ->
        Stdlib.Mutex.protect registry_mutex (fun () ->
          entry.active_count <- max 0 (entry.active_count - 1);
          entry.folded <- None;
          lru_unlink_locked entry))
      (fun () -> remove path))
;;

let with_index_cache_limits ~max_entries ~max_rows_per_keeper:per_keeper ~max_total_rows:total f =
  let prev =
    Stdlib.Mutex.protect registry_mutex (fun () ->
      let prev = !max_retained_indices, !max_rows_per_keeper, !max_total_rows in
      max_retained_indices := max 0 max_entries;
      max_rows_per_keeper := max 0 per_keeper;
      max_total_rows := max 0 total;
      Hashtbl.iter
        (fun _path entry ->
           if entry.active_count = 0
           then
             match entry.folded with
             | Some folded when folded.row_count > !max_rows_per_keeper ->
               lru_unlink_locked entry;
               entry.folded <- None
             | Some _ | None -> ())
        registry;
      evict_excess_locked ();
      prev)
  in
  Fun.protect
    ~finally:(fun () ->
      let prev_entries, prev_per_keeper, prev_total = prev in
      Stdlib.Mutex.protect registry_mutex (fun () ->
        max_retained_indices := prev_entries;
        max_rows_per_keeper := prev_per_keeper;
        max_total_rows := prev_total;
        evict_excess_locked ()))
    f
;;
