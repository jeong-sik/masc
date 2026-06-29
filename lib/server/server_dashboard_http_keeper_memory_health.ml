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
    - [Otel_metric_store] provider-slot-busy counters for skipped librarian
      extraction attempts, grouped by keeper.
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
  ; provider_slot_busy : int
  }

type alert_code =
  | Ttl_expired_on_disk
  | Near_duplicate
  | Events_to_facts_ratio_high
  | Provider_slot_busy

type alert_severity = Warn

type alert_target =
  | Ttl_expired_on_disk_target
  | Near_duplicate_target
  | Events_to_facts_ratio_target
  | Provider_slot_busy_target

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
let near_duplicate_threshold = 0.0

(* Diagnostic threshold only: rows above this line are highlighted for
   compaction attention, but no control-flow or pruning decision depends on it.
   The backend owns the value and publishes it through [alert_summary.thresholds]
   so the dashboard does not duplicate the literal. *)
let events_to_facts_ratio_warn_threshold =
  Keeper_memory_os_policy.events_to_facts_ratio_attention_threshold
;;

let provider_slot_busy_threshold = 0.0

let provider_slot_busy_metric = Keeper_metrics.(to_string MemoryLaneProviderSlotBusy)
let provider_slot_busy_site = Keeper_librarian_runtime.memory_os_librarian_provider_slot_site

let alert_code_to_string = function
  | Ttl_expired_on_disk -> "ttl_expired_on_disk"
  | Near_duplicate -> "near_duplicate"
  | Events_to_facts_ratio_high -> "events_to_facts_ratio_high"
  | Provider_slot_busy -> "provider_slot_busy"
;;

let alert_severity_to_string = function
  | Warn -> "warn"
;;

let alert_target_to_string = function
  | Ttl_expired_on_disk_target -> "ttl_expired_on_disk"
  | Near_duplicate_target -> "near_duplicate"
  | Events_to_facts_ratio_target -> "events_to_facts_ratio"
  | Provider_slot_busy_target -> "provider_slot_busy"
;;

(* Alert labels are endpoint-owned wire copy for this backend-defined diagnostic
   taxonomy. The dashboard renders the label as data from this endpoint instead
   of maintaining a second code -> label classifier. *)
let alert_label = function
  | Ttl_expired_on_disk -> "TTL"
  | Near_duplicate -> "중복"
  | Events_to_facts_ratio_high -> "비율"
  | Provider_slot_busy -> "슬롯"
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
    if h.near_duplicate > 0
    then
      alert
        ~code:Near_duplicate
        ~target:Near_duplicate_target
        ~message:"Near-duplicate Memory OS fact rows remain on disk; GC dry-run would deduplicate them."
        ~value:(float_of_int h.near_duplicate)
        ~threshold:near_duplicate_threshold
      :: alerts
    else alerts)
  |> (fun alerts ->
    if h.events_to_facts_ratio > events_to_facts_ratio_warn_threshold
    then
      alert
        ~code:Events_to_facts_ratio_high
        ~target:Events_to_facts_ratio_target
        ~message:"Memory OS event bytes are high relative to fact bytes."
        ~value:h.events_to_facts_ratio
        ~threshold:events_to_facts_ratio_warn_threshold
      :: alerts
    else alerts)
  |> (fun alerts ->
    if h.provider_slot_busy > 0
    then
      alert
        ~code:Provider_slot_busy
        ~target:Provider_slot_busy_target
        ~message:
          "Memory OS librarian provider slot was busy; extraction was skipped and remains due."
        ~value:(float_of_int h.provider_slot_busy)
        ~threshold:provider_slot_busy_threshold
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

let provider_slot_busy_for_keeper keeper_id =
  (* MemoryLaneProviderSlotBusy is emitted through [inc_counter], so values are
     integral counts even though the metric store carries floats. Keep the JSON
     field as an int to match the rest of this count-oriented health snapshot. *)
  Otel_metric_store.metric_value_or_zero
    provider_slot_busy_metric
    ~labels:[ "keeper", keeper_id; "site", provider_slot_busy_site ]
    ()
  |> int_of_float
;;

let keeper_health ~keepers_dir ~now keeper_id =
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
  ; provider_slot_busy = provider_slot_busy_for_keeper keeper_id
  }
;;

let keeper_health_entry_to_json (h, alerts) : Yojson.Safe.t =
  `Assoc
    [ "keeper_id", `String h.keeper_id
    ; "facts", `Int h.facts
    ; "facts_bytes", `Int h.facts_bytes
    ; "events", `Int h.events
    ; "events_bytes", `Int h.events_bytes
    ; "events_to_facts_ratio", `Float h.events_to_facts_ratio
    ; "ttl_expired_on_disk", `Int h.ttl_expired_on_disk
    ; "near_duplicate", `Int h.near_duplicate
    ; "provider_slot_busy", `Int h.provider_slot_busy
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
    |> List.map (fun h -> h, keeper_alerts h)
    (* Largest stores first so the worst offenders surface at the top. *)
    |> List.sort (fun (a, _) (b, _) -> compare b.facts_bytes a.facts_bytes)
  in
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
    ; "keepers", `List (List.map keeper_health_entry_to_json entries)
    ; ( "totals"
      , `Assoc
          [ "facts", `Int (sum (fun h -> h.facts))
          ; "facts_bytes", `Int (sum (fun h -> h.facts_bytes))
          ; "events_bytes", `Int (sum (fun h -> h.events_bytes))
          ; "ttl_expired_on_disk", `Int (sum (fun h -> h.ttl_expired_on_disk))
          ; "near_duplicate", `Int (sum (fun h -> h.near_duplicate))
          ; "provider_slot_busy", `Int (sum (fun h -> h.provider_slot_busy))
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
          ; "near_duplicate_keepers", `Int (alert_count_by_code Near_duplicate)
          ; ( "high_event_ratio_keepers"
            , `Int (alert_count_by_code Events_to_facts_ratio_high) )
          ; "provider_slot_busy_keepers", `Int (alert_count_by_code Provider_slot_busy)
          ; ( "thresholds"
            , `Assoc
                [ "ttl_expired_on_disk", `Float ttl_expired_on_disk_threshold
                ; "near_duplicate", `Float near_duplicate_threshold
                ; "events_to_facts_ratio", `Float events_to_facts_ratio_warn_threshold
                ; "provider_slot_busy", `Float provider_slot_busy_threshold
                ] )
          ] )
    ]
;;
