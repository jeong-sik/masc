(** Keeper Memory Health dashboard HTTP JSON helper.

    Produces a read-only snapshot of per-keeper fact-store sizes, GC-dry-run
    statistics, and the fleet-wide librarian cadence counter for the
    /api/v1/dashboard/keeper-memory-health endpoint.

    Data sources:
    - [Config_dir_resolver.keepers_dir_for_base_path] for request-scoped paths.
    - [Keeper_memory_os_io.list_fact_store_keeper_ids_for_keepers_dir] for the
      keeper list.
    - [Keeper_memory_os_io.read_facts_all_for_keepers_dir] and file stat for
      facts count/bytes.
    - [Keeper_memory_os_io.events_path_for_keepers_dir] + file stat for events
      bytes.
    - [Keeper_memory_os_types.partition_expired] over that same immutable fact
      snapshot for explicitly expired rows.
    - [Keeper_librarian_runtime.cadence_counter_entries] for the cadence table
      size (one fleet-wide value). *)

type keeper_health =
  { keeper_id : string
  ; facts : int
  ; facts_bytes : int
  ; events : int
  ; events_bytes : int
  ; events_bytes_to_facts_bytes_ratio : float
  ; ttl_expired_on_disk : int
  ; duplicate_claim_identity_rows : int
  }

type alert_code =
  | Ttl_expired_on_disk
  | Duplicate_claim_identity_rows

type alert_severity = Warn

type alert_target =
  | Ttl_expired_on_disk_target
  | Duplicate_claim_identity_rows_target

type keeper_alert =
  { code : alert_code
  ; severity : alert_severity
  ; target : alert_target
  ; label : string
  ; message : string
  ; value : float
  ; threshold : float
  }

let ttl_expired_on_disk_threshold = 0.0
let duplicate_claim_identity_rows_threshold = 0.0

let alert_code_to_string = function
  | Ttl_expired_on_disk -> "ttl_expired_on_disk"
  | Duplicate_claim_identity_rows -> "duplicate_claim_identity_rows"
;;

let alert_severity_to_string = function
  | Warn -> "warn"
;;

let alert_target_to_string = function
  | Ttl_expired_on_disk_target -> "ttl_expired_on_disk"
  | Duplicate_claim_identity_rows_target -> "duplicate_claim_identity_rows"
;;

(* Alert labels are endpoint-owned wire copy for this backend-defined diagnostic
   taxonomy. The dashboard renders the label as data from this endpoint instead
   of maintaining a second code -> label classifier. *)
let alert_label = function
  | Ttl_expired_on_disk -> "TTL"
  | Duplicate_claim_identity_rows -> "동일 claim identity 행"
;;

let alert ~code ~target ~message ~value ~threshold =
  { code; severity = Warn; target; label = alert_label code; message; value; threshold }
;;

let keeper_alerts h =
  []
  |> (fun alerts ->
    if h.ttl_expired_on_disk > 0
    then
      alert
        ~code:Ttl_expired_on_disk
        ~target:Ttl_expired_on_disk_target
        ~message:"TTL-expired Memory OS fact rows remain on disk; GC dry-run would prune them."
        ~value:(float_of_int h.ttl_expired_on_disk)
        ~threshold:ttl_expired_on_disk_threshold
      :: alerts
    else alerts)
  |> (fun alerts ->
    if h.duplicate_claim_identity_rows > 0
    then
      alert
        ~code:Duplicate_claim_identity_rows
        ~target:Duplicate_claim_identity_rows_target
        ~message:
          "Memory OS fact rows with an already-present claim identity remain on disk; \
           operator review is required."
        ~value:(float_of_int h.duplicate_claim_identity_rows)
        ~threshold:duplicate_claim_identity_rows_threshold
      :: alerts
    else alerts)
  |> List.rev
;;

let keeper_alert_to_json alert =
  `Assoc
    [ "code", `String (alert_code_to_string alert.code)
    ; "severity", `String (alert_severity_to_string alert.severity)
    ; "target", `String (alert_target_to_string alert.target)
    ; "label", `String alert.label
    ; "message", `String alert.message
    ; "value", `Float alert.value
    ; "threshold", `Float alert.threshold
    ]
;;

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
         let rec count_lines count =
           match input_line ic with
           | _ -> count_lines (count + 1)
           | exception End_of_file -> count
         in
         count_lines 0))
;;

let file_size_bytes path =
  (* NDT-OK: file size is a diagnostic metric. *)
  if not (Sys.file_exists path) then 0 else (Unix.stat path).Unix.st_size
;;

module Claim_identity_map = Map.Make (String)

let duplicate_claim_identity_rows facts =
  let counts =
    List.fold_left
      (fun counts fact ->
       let key = Keeper_memory_os_types.claim_identity fact in
       let count =
         match Claim_identity_map.find_opt key counts with
         | Some count -> count
         | None -> 0
       in
       Claim_identity_map.add key (count + 1) counts)
      Claim_identity_map.empty
      facts
  in
  Claim_identity_map.fold
    (fun _ count total -> total + max 0 (count - 1))
    counts
    0
;;

let keeper_health_unlocked ~keepers_dir ~now keeper_id =
  let facts =
    (* [read_facts_all] raises on malformed JSONL — treated as a read failure
       for this keeper; the caller catches and skips it. *)
    Keeper_memory_os_io.read_facts_all_for_keepers_dir ~keepers_dir ~keeper_id
  in
  let facts_count = List.length facts in
  let facts_bytes =
    file_size_bytes
      (Keeper_memory_os_io.facts_path_for_keepers_dir ~keepers_dir ~keeper_id)
  in
  let events_p =
    Keeper_memory_os_io.events_path_for_keepers_dir ~keepers_dir ~keeper_id
  in
  let events_bytes = file_size_bytes events_p in
  let _, expired =
    Keeper_memory_os_types.partition_expired ~now facts
  in
  { keeper_id
  ; facts = facts_count
  ; facts_bytes
  ; events = count_lines_in_file events_p
  ; events_bytes
  ; events_bytes_to_facts_bytes_ratio =
      float_of_int events_bytes /. float_of_int (max 1 facts_bytes)
  ; ttl_expired_on_disk = List.length expired
  ; duplicate_claim_identity_rows = duplicate_claim_identity_rows facts
  }
;;

let keeper_health ~keepers_dir ~now keeper_id =
  Keeper_memory_os_io.with_episode_bundle_lock_for_keepers_dir
    ~keepers_dir
    ~keeper_id
    (fun () ->
       File_lock_eio.with_lock
         (Keeper_memory_os_io.facts_path_for_keepers_dir ~keepers_dir ~keeper_id)
         (fun () ->
            keeper_health_unlocked ~keepers_dir ~now keeper_id))
;;

let keeper_health_entry_to_json (h, alerts) : Yojson.Safe.t =
  `Assoc
    [ "keeper_id", `String h.keeper_id
    ; "facts", `Int h.facts
    ; "facts_bytes", `Int h.facts_bytes
    ; "events", `Int h.events
    ; "events_bytes", `Int h.events_bytes
    ; ( "events_bytes_to_facts_bytes_ratio"
      , `Float h.events_bytes_to_facts_bytes_ratio )
    ; "ttl_expired_on_disk", `Int h.ttl_expired_on_disk
    ; "duplicate_claim_identity_rows", `Int h.duplicate_claim_identity_rows
    ; "alerts", `List (List.map keeper_alert_to_json alerts)
    ]
;;

let keeper_memory_health_http_json ~base_path : Yojson.Safe.t =
  (* One wall-clock instant is shared by the snapshot timestamp and dry-run GC
     scans; no retention or control logic depends on the exact value. *)
  (* NDT-OK: diagnostic snapshot timestamp only. *)
  let now = Unix.gettimeofday () in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let cadence_counter_entries = Keeper_librarian_runtime.cadence_counter_entries () in
  let health_results =
    Keeper_memory_os_io.list_fact_store_keeper_ids_for_keepers_dir ~keepers_dir
    |> List.map (fun keeper_id ->
      match keeper_health ~keepers_dir ~now keeper_id with
      | h -> Ok h
      | exception (Eio.Cancel.Cancelled _ as e) -> raise e
      | exception exn ->
        let error = Printexc.to_string exn in
        Log.Dashboard.warn
          "[keeper_memory_health] keeper read failed %s: %s"
          keeper_id
          error;
        Error (keeper_id, error))
  in
  let entries, read_errors =
    List.fold_left
      (fun (entries, errors) -> function
         | Ok entry -> entry :: entries, errors
         | Error error -> entries, error :: errors)
      ([], [])
      health_results
  in
  let entries =
    List.rev entries
    |> List.map (fun h -> h, keeper_alerts h)
    (* Largest stores first so the worst offenders surface at the top. *)
    |> List.sort (fun (a, _) (b, _) -> compare b.facts_bytes a.facts_bytes)
  in
  let read_errors = List.rev read_errors in
  let sum f = List.fold_left (fun acc (h, _) -> acc + f h) 0 entries in
  let all_alerts = List.concat_map snd entries in
  let alert_count_by_code code =
    List.fold_left
      (fun acc alert -> if alert.code = code then acc + 1 else acc)
      0
      all_alerts
  in
  `Assoc
    [ "generated_at", `Float now
    ; "cadence_counter_entries", `Int cadence_counter_entries
    ; "read_error_count", `Int (List.length read_errors)
    ; ( "read_errors"
      , `List
          (List.map
             (fun (keeper_id, error) ->
                `Assoc [ "keeper_id", `String keeper_id; "error", `String error ])
             read_errors) )
    ; "keepers", `List (List.map keeper_health_entry_to_json entries)
    ; ( "totals"
      , `Assoc
          [ "facts", `Int (sum (fun h -> h.facts))
          ; "facts_bytes", `Int (sum (fun h -> h.facts_bytes))
          ; "events_bytes", `Int (sum (fun h -> h.events_bytes))
          ; "ttl_expired_on_disk", `Int (sum (fun h -> h.ttl_expired_on_disk))
          ; ( "duplicate_claim_identity_rows"
            , `Int (sum (fun h -> h.duplicate_claim_identity_rows)) )
          ] )
    ; ( "alert_summary"
      , `Assoc
          [ "total_alerts", `Int (List.length all_alerts)
          ; ( "warn_alerts"
            , `Int
                (List.length
                   (List.filter (fun alert -> alert.severity = Warn) all_alerts)) )
          ; ( "keepers_with_alerts"
            , `Int
                (List.fold_left
                   (fun acc (_, alerts) -> if alerts = [] then acc else acc + 1)
                   0
                   entries) )
          ; "ttl_expired_keepers", `Int (alert_count_by_code Ttl_expired_on_disk)
          ; ( "duplicate_claim_identity_rows_keepers"
            , `Int (alert_count_by_code Duplicate_claim_identity_rows) )
          ; ( "thresholds"
            , `Assoc
                [ "ttl_expired_on_disk", `Float ttl_expired_on_disk_threshold
                ; ( "duplicate_claim_identity_rows"
                  , `Float duplicate_claim_identity_rows_threshold )
                ] )
          ] )
    ]
;;
