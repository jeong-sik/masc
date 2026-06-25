(** Keeper Memory Health dashboard HTTP JSON helper.

    Produces a read-only snapshot of per-keeper fact-store sizes, GC-dry-run
    statistics, and the fleet-wide librarian cadence counter for the
    /api/v1/dashboard/keeper-memory-health endpoint.

    Data sources:
    - [Config_dir_resolver.keepers_dir_for_base_path] for request-scoped paths.
    - [Keeper_memory_os_io.list_fact_store_keeper_ids] for the keeper list.
    - [Keeper_memory_os_io.read_facts_all] and file stat for facts count/bytes.
    - [Keeper_memory_os_io.events_path] + file stat for events bytes.
    - [Keeper_memory_os_gc.run_gc ~dry_run:true] for TTL-expired and
      near-duplicate counts without mutating the store.
    - [Keeper_librarian_runtime.cadence_counter_entries] for the cadence table
      size (one fleet-wide value). *)

type keeper_health =
  { keeper_id : string
  ; facts : int
  ; facts_bytes : int
  ; events : int
  ; events_bytes : int
  ; events_to_facts_ratio : float
  ; ttl_expired_on_disk : int
  ; near_duplicate : int
  }

let count_lines_in_file path =
  (* NDT-OK: file line count is a read-only diagnostic metric, not a control
     value. Streams the file so a large append-only events log is not loaded
     into memory just to be counted. *)
  if not (Sys.file_exists path)
  then 0
  else (
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         let count = ref 0 in
         (try
            while true do
              let _ = input_line ic in
              incr count
            done
          with
          | End_of_file -> ());
         !count))
;;

let file_size_bytes path =
  (* NDT-OK: file size is a diagnostic metric. *)
  if not (Sys.file_exists path) then 0 else (Unix.stat path).Unix.st_size
;;

let keeper_health ~keepers_dir ~now keeper_id =
  let facts_count =
    (* [read_facts_all] raises on malformed JSONL — treated as a read failure
       for this keeper; the caller catches and skips it. *)
    let fs =
      Keeper_memory_os_io.read_facts_all_for_keepers_dir ~keepers_dir ~keeper_id
    in
    List.length fs
  in
  let facts_bytes =
    file_size_bytes
      (Keeper_memory_os_io.facts_path_for_keepers_dir ~keepers_dir ~keeper_id)
  in
  let events_p =
    Keeper_memory_os_io.events_path_for_keepers_dir ~keepers_dir ~keeper_id
  in
  let events_bytes = file_size_bytes events_p in
  (* dry_run keeps the scan read-only: it reports what TTL-expiry + dedup WOULD
     prune without rewriting the store. *)
  let gc_report =
    Keeper_memory_os_gc.run_gc_for_keepers_dir
      ~keepers_dir
      ~dry_run:true
      ~keeper_id
      ~now
      ()
  in
  { keeper_id
  ; facts = facts_count
  ; facts_bytes
  ; events = count_lines_in_file events_p
  ; events_bytes
  ; events_to_facts_ratio =
      float_of_int events_bytes /. float_of_int (max 1 facts_bytes)
  ; ttl_expired_on_disk = gc_report.ttl_expired
  ; near_duplicate = gc_report.dedup_removed
  }
;;

let keeper_health_to_json h : Yojson.Safe.t =
  `Assoc
    [ "keeper_id", `String h.keeper_id
    ; "facts", `Int h.facts
    ; "facts_bytes", `Int h.facts_bytes
    ; "events", `Int h.events
    ; "events_bytes", `Int h.events_bytes
    ; "events_to_facts_ratio", `Float h.events_to_facts_ratio
    ; "ttl_expired_on_disk", `Int h.ttl_expired_on_disk
    ; "near_duplicate", `Int h.near_duplicate
    ]
;;

let keeper_memory_health_http_json ~base_path : Yojson.Safe.t =
  (* One wall-clock instant is shared by the snapshot timestamp and dry-run GC
     scans; no retention or control logic depends on the exact value. *)
  (* NDT-OK: diagnostic snapshot timestamp only. *)
  let now = Unix.gettimeofday () in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let cadence_counter_entries = Keeper_librarian_runtime.cadence_counter_entries () in
  let entries =
    Keeper_memory_os_io.list_fact_store_keeper_ids_for_keepers_dir ~keepers_dir
    |> List.filter_map (fun keeper_id ->
      match keeper_health ~keepers_dir ~now keeper_id with
      | h -> Some h
      | exception (Eio.Cancel.Cancelled _ as e) -> raise e
      | exception exn ->
        Log.Dashboard.warn
          "[keeper_memory_health] skipping keeper %s: %s"
          keeper_id
          (Printexc.to_string exn);
        None)
    (* Largest stores first so the worst offenders surface at the top. *)
    |> List.sort (fun a b -> compare b.facts_bytes a.facts_bytes)
  in
  let sum f = List.fold_left (fun acc h -> acc + f h) 0 entries in
  `Assoc
    [ "generated_at", `Float now
    ; "cadence_counter_entries", `Int cadence_counter_entries
    ; "keepers", `List (List.map keeper_health_to_json entries)
    ; ( "totals"
      , `Assoc
          [ "facts", `Int (sum (fun h -> h.facts))
          ; "facts_bytes", `Int (sum (fun h -> h.facts_bytes))
          ; "events_bytes", `Int (sum (fun h -> h.events_bytes))
          ; "ttl_expired_on_disk", `Int (sum (fun h -> h.ttl_expired_on_disk))
          ; "near_duplicate", `Int (sum (fun h -> h.near_duplicate))
          ] )
    ]
;;
