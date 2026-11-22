(** Read-only fleet health for the current Memory OS snapshot. *)

type keeper_health =
  { keeper_id : string
  ; revision : int
  ; updated_at : float option
  ; facts : int
  ; observed_facts : int
  ; derived_facts : int
  ; support_invalidations : int
  ; snapshot_bytes : int
  ; added : int
  ; removed : int
  ; snapshot_present : bool
  ; first_seen : float list option
  ; facts_by_hour : Keeper_memory_journal_outcome.facts_at_hour list
      (** Oldest first, as the journal fold keeps them. A cached row
          outlives the hour it was read in, so the answer cuts these with
          {!Keeper_memory_journal_outcome.within} at its own time. *)
  ; librarian_failures : int
  ; vision_ingest_errors : int
  ; vision_ingest_error_reasons : (string * int) list
  ; read_error : string option
  ; source_revision : int
  ; source_facts : int
  ; source_invalidations : int
  ; source_snapshot_bytes : int
  ; source_snapshot_present : bool
  ; source_read_error : string option
  }

type source_health =
  { revision : int
  ; facts : int
  ; invalidations : int
  ; snapshot_bytes : int
  ; snapshot_present : bool
  ; read_error : string option
  }

let librarian_failures_metric =
  Keeper_metrics.(to_string MemoryOsLibrarianFailures)
;;

(* Rendered knowledge size, excluding snapshot bookkeeping. These bytes are
   available through demand recall, not injected on every turn. Actual prompt
   index bytes belong to the turn record and last-prompt capture. *)
let rendered_bytes facts =
  String.length (Keeper_memory_os_render.render_facts facts)
;;

let rendered_source_bytes ~facts ~invalidations =
  List.fold_left
    (fun total fact ->
       total + String.length (Keeper_memory_source_current.render_fact fact))
    0
    facts
  + List.fold_left
      (fun total invalidation ->
         total
         + String.length
             (Keeper_memory_source_current.render_invalidation invalidation))
      0
      invalidations
;;

(* The label the counter increments in [Keeper_librarian_runtime] carry. *)
let librarian_failures_for_keeper keeper_id =
  Otel_metric_store.metric_value_or_zero
    librarian_failures_metric
    ~labels:[ "keeper", keeper_id; "site", "memory_os_librarian" ]
    ()
  |> int_of_float
;;

(* A keeper with a config but no current snapshot is the starvation case this
   endpoint exists to expose; enumerating snapshot files alone gives it no
   row at all. Health rows therefore come from the union of configured
   keepers and existing snapshots. Discovery goes through
   [Keeper_types_profile.discover_keepers_toml] rather than toml basenames
   because a toml may set its canonical [name]: metrics and snapshots are
   keyed by that name, and a basename row would both miss the real keeper
   and show a ghost. Invalid tomls keep their basename row so a keeper with
   a broken config stays visible. *)
let configured_keeper_ids ~keepers_dir =
  Keeper_types_profile.discover_keepers_toml keepers_dir
  |> List.map Keeper_types_profile.keeper_toml_discovery_name
;;

let health_keeper_ids ~keepers_dir =
  configured_keeper_ids ~keepers_dir
  @ Keeper_memory_os_current.list_keeper_ids_for_keepers_dir ~keepers_dir
  @ Keeper_memory_source_current.list_keeper_ids_for_keepers_dir ~keepers_dir
  |> List.sort_uniq String.compare
;;

let vision_ingest_error_metric =
  Keeper_metrics.(to_string VisionIngestErrors)
;;

(* #32126: per-keeper image-ingest failures, by the closed reason set the
   ingest module owns. Only nonzero reasons ride along, so the row says why,
   not just how many. *)
let vision_errors_for_keeper keeper_id =
  List.filter_map
    (fun reason ->
       let count =
         Otel_metric_store.metric_value_or_zero
           vision_ingest_error_metric
           ~labels:[ "keeper", keeper_id; "reason", reason ]
           ()
         |> int_of_float
       in
       if count > 0 then Some (reason, count) else None)
    Keeper_vision_ingest.error_reasons
;;

let vision_ingest_error_count_for_keeper keeper_id =
  List.fold_left (fun total (_, count) -> total + count) 0
    (vision_errors_for_keeper keeper_id)
;;

let source_health ~keepers_dir keeper_id =
  match
    Keeper_memory_source_current.read_for_keepers_dir ~keepers_dir ~keeper_id
  with
  | Ok None ->
    { revision = 0
    ; facts = 0
    ; invalidations = 0
    ; snapshot_bytes = 0
    ; snapshot_present = false
    ; read_error = None
    }
  | Ok (Some snapshot) ->
    { revision = snapshot.revision
    ; facts = List.length snapshot.facts
    ; invalidations = List.length snapshot.invalidations
    ; snapshot_bytes =
        rendered_source_bytes
          ~facts:snapshot.facts
          ~invalidations:snapshot.invalidations
    ; snapshot_present = true
    ; read_error = None
    }
  | Error message ->
    { revision = 0
    ; facts = 0
    ; invalidations = 0
    ; snapshot_bytes = 0
    ; snapshot_present = false
    ; read_error = Some message
    }
;;
let keeper_health ~config:(_ : Workspace.config) ~keepers_dir keeper_id =
  let source_health = source_health ~keepers_dir keeper_id in
  let journal = Keeper_memory_journal_outcome.read ~keepers_dir ~keeper_id in
  let journal_error =
    Option.map
      (fun error -> "memory journal: " ^ Dated_jsonl.read_error_to_string error)
      journal.read_error
  in
  match
    Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id
  with
  | Ok None ->
    { keeper_id
    ; updated_at = None
    ; revision = 0
    ; facts = 0
    ; observed_facts = 0
    ; derived_facts = 0
    ; support_invalidations = 0
    ; snapshot_bytes = 0
    ; added = 0
    ; removed = 0
    ; snapshot_present = false
    ; first_seen = None
    ; facts_by_hour = journal.facts_by_hour
    ; librarian_failures = librarian_failures_for_keeper keeper_id
    ; vision_ingest_errors =
        vision_ingest_error_count_for_keeper keeper_id
    ; vision_ingest_error_reasons = vision_errors_for_keeper keeper_id
    ; read_error = journal_error
    ; source_revision = source_health.revision
    ; source_facts = source_health.facts
    ; source_invalidations = source_health.invalidations
    ; source_snapshot_bytes = source_health.snapshot_bytes
    ; source_snapshot_present = source_health.snapshot_present
    ; source_read_error = source_health.read_error
    }
  | Ok (Some snapshot) ->
    let observed_facts, derived_facts =
      List.fold_left
        (fun (observed, derived) fact ->
           match fact.Keeper_memory_os_types.basis with
           | Keeper_memory_os_types.Observed _ -> observed + 1, derived
           | Keeper_memory_os_types.Derived _ -> observed, derived + 1)
        (0, 0)
        snapshot.facts
    in
    { keeper_id
    ; updated_at = Some snapshot.updated_at
    ; revision = snapshot.revision
    ; facts = List.length snapshot.facts
    ; observed_facts
    ; derived_facts
    ; support_invalidations = List.length snapshot.change.invalidated
    ; snapshot_bytes = rendered_bytes snapshot.facts
    ; added = List.length snapshot.change.added
    ; removed = List.length snapshot.change.removed
    ; snapshot_present = true
    ; first_seen =
        Some
          (List.map
             (fun (f : Keeper_memory_os_types.fact) -> f.first_seen)
             snapshot.facts)
    ; facts_by_hour = journal.facts_by_hour
    ; librarian_failures = librarian_failures_for_keeper keeper_id
    ; vision_ingest_errors =
        vision_ingest_error_count_for_keeper keeper_id
    ; vision_ingest_error_reasons = vision_errors_for_keeper keeper_id
    ; read_error = journal_error
    ; source_revision = source_health.revision
    ; source_facts = source_health.facts
    ; source_invalidations = source_health.invalidations
    ; source_snapshot_bytes = source_health.snapshot_bytes
    ; source_snapshot_present = source_health.snapshot_present
    ; source_read_error = source_health.read_error
    }
  | Error message ->
    { keeper_id
    ; updated_at = None
    ; revision = 0
    ; facts = 0
    ; observed_facts = 0
    ; derived_facts = 0
    ; support_invalidations = 0
    ; snapshot_bytes = 0
    ; added = 0
    ; removed = 0
    ; snapshot_present = false
    ; first_seen = None
    ; facts_by_hour = journal.facts_by_hour
    ; librarian_failures = librarian_failures_for_keeper keeper_id
    ; vision_ingest_errors =
        vision_ingest_error_count_for_keeper keeper_id
    ; vision_ingest_error_reasons = vision_errors_for_keeper keeper_id
    ; read_error =
        Some (match journal_error with None -> message | Some journal -> message ^ "; " ^ journal)
    ; source_revision = source_health.revision
    ; source_facts = source_health.facts
    ; source_invalidations = source_health.invalidations
    ; source_snapshot_bytes = source_health.snapshot_bytes
    ; source_snapshot_present = source_health.snapshot_present
    ; source_read_error = source_health.read_error
    }
;;

(* An alert keeps its severity beside its JSON, so the totals count it from
   the value it was made with instead of reading it back. *)
let alert ~code ~severity ~target ~label ~message =
  ( severity
  , `Assoc
      [ "code", `String code
      ; "severity", `String (Keeper_memory_health_totals.alert_severity_to_wire severity)
      ; "target", `String target
      ; "label", `String label
      ; "message", `String message
      ] )

type cached_keeper_health = {
  mutex : Mutex.t;
  mutable generation : int;
  mutable value : keeper_health option;
}

let health_cache : (string * string, cached_keeper_health) Hashtbl.t = Hashtbl.create 16
let health_cache_mutex = Mutex.create ()

(* Every root a writer may name, resolved, to the root the row is cached
   under. Both are resolved when a read registers them, so emptying a row
   from a write signal needs no filesystem lookup. *)
let row_roots : (string, string) Hashtbl.t = Hashtbl.create 4
let health_reader = ref keeper_health

let health_directory_identity path =
  let abs_path =
    if Filename.is_relative path
    then Filename.concat (Unix.getcwd ()) path
    else path
  in
  Fs_compat.realpath_lenient abs_path

let cache_entry ~keepers_dir keeper_id =
  let key = health_directory_identity keepers_dir, keeper_id in
  Stdlib.Mutex.protect health_cache_mutex (fun () ->
    match Hashtbl.find_opt health_cache key with
    | Some entry -> entry
    | None ->
        let entry = { mutex = Mutex.create (); generation = 0; value = None } in
        Hashtbl.add health_cache key entry;
        entry)

let cached_keeper_health ~config ~keepers_dir keeper_id =
  let entry = cache_entry ~keepers_dir keeper_id in
  let rec read () =
    let cached, generation = Stdlib.Mutex.protect entry.mutex (fun () ->
      entry.value, entry.generation)
    in
    match cached with
    | Some health when health.read_error = None -> health
    | Some _ | None ->
        let health = !health_reader ~config ~keepers_dir keeper_id in
        let current = Stdlib.Mutex.protect entry.mutex (fun () ->
          if entry.generation = generation then begin
            entry.value <- (if health.read_error = None then Some health else None);
            true
          end else
            false)
        in
        if current then health else read ()
  in
  read ()

(* A writer reports the root it wrote under. The Librarian keeps its progress
   and turn records under the runtime root while the row is cached under the
   config root, so the reported root is mapped to the row's own root before
   the row is emptied, or a write under the runtime root leaves the row
   answering what it had. *)
let invalidate_after_write ~keepers_dir ~keeper_id =
  (* An invalidation is a report about a row some read put there. Creating
     the row here instead would leave an entry nobody has read, kept alive
     only by its own invalidation. *)
  let entry =
    Stdlib.Mutex.protect health_cache_mutex (fun () ->
      Option.bind (Hashtbl.find_opt row_roots keepers_dir) (fun row_root ->
        Hashtbl.find_opt health_cache (row_root, keeper_id)))
  in
  match entry with
  | None -> ()
  | Some entry ->
    Stdlib.Mutex.protect entry.mutex (fun () ->
      entry.generation <- entry.generation + 1;
      entry.value <- None)
;;

(* A store hook names the directory as its writer spelled it, so the hook
   resolves it before the lookup. The write signals name it resolved already
   and reach [invalidate_after_write] directly. *)
let invalidate_after_store_write ~keepers_dir ~keeper_id =
  invalidate_after_write ~keepers_dir:(health_directory_identity keepers_dir) ~keeper_id
;;

let install () =
  let retained = ref [] in
  let register restore = retained := restore :: !retained in
  register (Keeper_memory_os_current.install_commit_observer invalidate_after_store_write);
  register (Keeper_memory_source_current.install_commit_observer invalidate_after_store_write)
;;

let alerts (h : keeper_health) =
  let read_error_alert =
    match h.read_error with
    | None -> []
    | Some message ->
      [ alert
          ~code:"snapshot_read_error"
          ~severity:Keeper_memory_health_totals.Alert_warn
          ~target:"snapshot_read_error"
          ~label:"읽기"
          ~message
      ]
  in
  let source_read_error_alert =
    match h.source_read_error with
    | None -> []
    | Some message ->
      [ alert
          ~code:"source_snapshot_read_error"
          ~severity:Keeper_memory_health_totals.Alert_warn
          ~target:"source_snapshot_read_error"
          ~label:"소스 읽기"
          ~message
      ]
  in
  let failure_alert =
    if h.librarian_failures <= 0
    then []
    else if h.snapshot_present
    then
      [ alert
          ~code:"librarian_failures"
          ~severity:Keeper_memory_health_totals.Alert_warn
          ~target:"librarian_failures"
          ~label:"Librarian"
          ~message:
            "Librarian runs have failed since server start. The current-memory snapshot is available."
      ]
    else
      [ alert
          ~code:"librarian_starvation"
          ~severity:Keeper_memory_health_totals.Alert_error
          ~target:"librarian_starvation"
          ~label:"Librarian"
          ~message:
            (if h.source_snapshot_present
             then
               "Librarian runs failed and no ordinary current-memory snapshot exists. A source-bound snapshot remains available, but it does not demonstrate or repair Librarian selection."
             else
               "Librarian runs failed and no ordinary or source-bound current-memory snapshot exists; recall has no stored snapshot at this observation.")
      ]
  in
  let vision_ingest_alert =
    if h.vision_ingest_errors <= 0
    then []
    else
      [ alert
          ~code:"vision_ingest_errors"
          ~severity:Keeper_memory_health_totals.Alert_warn
          ~target:"vision_ingest_errors"
          ~label:"Vision"
          ~message:
            (Printf.sprintf
               "Image ingestion failed %d times; those images reached the                 keeper as text placeholders. Reasons: %s."
               h.vision_ingest_errors
               (String.concat ", "
                  (List.map
                     (fun (reason, count) ->
                        Printf.sprintf "%s x%d" reason count)
                     h.vision_ingest_error_reasons)))
      ]
  in
  read_error_alert @ source_read_error_alert @ failure_alert @ vision_ingest_alert
;;


let keeper_health_entry_to_json ~now ~writer (h : keeper_health) =
  let age_bins_json =
    match h.first_seen with
    | None -> `Null
    | Some timestamps ->
      Keeper_memory_age_bins.to_json
        (Keeper_memory_age_bins.of_first_seen ~now timestamps)
  in
  `Assoc
    [ "keeper_id", `String h.keeper_id
    ; "revision", `Int h.revision
    ; "updated_at", (match h.updated_at with None -> `Null | Some ts -> `Float ts)
    ; "facts", `Int h.facts
    ; "observed_facts", `Int h.observed_facts
    ; "derived_facts", `Int h.derived_facts
    ; "support_invalidations", `Int h.support_invalidations
    ; "snapshot_bytes", `Int h.snapshot_bytes
    ; "added", `Int h.added
    ; "removed", `Int h.removed
    ; "snapshot_present", `Bool h.snapshot_present
    ; "age_bins", age_bins_json
    ; ( "facts_by_hour"
      , Keeper_memory_journal_outcome.(facts_by_hour_to_json (within ~now h.facts_by_hour)) )
      (* Read when the answer is written, not kept in the cached row. The
         store counts after it releases its locks: the journal line that
         empties the cached row comes before the count, and the commit
         notification that empties a written fleet answer comes after it. *)
    ; ( "changes_since_start"
      , Keeper_memory_commit_change.(by_pass_to_json (since_start ~keeper_id:h.keeper_id)) )
      (* The Keeper's Memory writer (RFC librarian-call-only-proposes
         §12.3), read from what the writer holds when the answer is written.
         Nothing a row is emptied by says the writer moved, so it is not
         kept in the cached row. *)
    ; "writer", writer h.keeper_id
    ; "librarian_failures", `Int h.librarian_failures
    ; "vision_ingest_errors", `Int h.vision_ingest_errors
    ; ( "vision_ingest_error_reasons"
      , `List
          (List.map
             (fun (reason, count) ->
                `Assoc [ ("reason", `String reason); ("count", `Int count) ])
             h.vision_ingest_error_reasons) )
    ; ( "read_error"
      , match h.read_error with
        | Some message -> `String message
        | None -> `Null )
    ; "source_revision", `Int h.source_revision
    ; "source_facts", `Int h.source_facts
    ; "source_invalidations", `Int h.source_invalidations
    ; "source_snapshot_bytes", `Int h.source_snapshot_bytes
    ; "source_snapshot_present", `Bool h.source_snapshot_present
    ; ( "source_read_error"
      , match h.source_read_error with
        | Some message -> `String message
        | None -> `Null )
    ; "alerts", `List (List.map snd (alerts h))
    ]
;;

let schema = "keeper.memory_os.current_health.v19"

let fleet_cache_key ~base_path = "keeper_memory_health:" ^ base_path

(* What a row contributes to the fleet totals. *)
let totals_row (h : keeper_health) : Keeper_memory_health_totals.Row.t =
  { Keeper_memory_health_totals.Row.facts = h.facts
  ; observed_facts = h.observed_facts
  ; derived_facts = h.derived_facts
  ; support_invalidations = h.support_invalidations
  ; snapshot_bytes = h.snapshot_bytes
  ; added = h.added
  ; removed = h.removed
  ; source_facts = h.source_facts
  ; source_invalidations = h.source_invalidations
  ; source_snapshot_bytes = h.source_snapshot_bytes
  ; librarian_failures = h.librarian_failures
  ; vision_ingest_errors = h.vision_ingest_errors
  ; read_error = Option.is_some h.read_error
  ; source_read_error = Option.is_some h.source_read_error
  ; snapshot_present = h.snapshot_present
  ; alerts = List.map fst (alerts h)
  }
;;

(* Both answers cache a Keeper's row under the config root, while a writer
   reports the root it wrote under. Register every root that names the same base
   path, or a write under one root finds no entry under the other and the row
   keeps answering the state it had. Kept in one place so the fleet answer and
   the single-row answer cannot drift apart. *)
let register_row_roots ~config ~keepers_dir =
  let row_root = health_directory_identity keepers_dir in
  let runtime_root = health_directory_identity (Workspace.keepers_runtime_dir config) in
  Stdlib.Mutex.protect health_cache_mutex (fun () ->
    Hashtbl.replace row_roots row_root row_root;
    Hashtbl.replace row_roots runtime_root row_root)
;;

let keeper_memory_health_http_json ~base_path =
  let generated_at = Time_compat.now () in
  let config = Workspace.default_config base_path in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path
  in
  register_row_roots ~config ~keepers_dir;
  let entries =
    health_keeper_ids ~keepers_dir
    |> List.map (cached_keeper_health ~config ~keepers_dir)
    |> List.sort (fun (left : keeper_health) (right : keeper_health) ->
      compare
        (right.snapshot_bytes + right.source_snapshot_bytes)
        (left.snapshot_bytes + left.source_snapshot_bytes))
  in
  let totals = Keeper_memory_health_totals.of_rows (List.map totals_row entries) in
  let writer = Keeper_memory_writer_health.keeper_rows ~config in
  `Assoc
    [ "schema", `String schema
    ; "generated_at", `Float generated_at
    ; ( "keepers"
      , `List (List.map (keeper_health_entry_to_json ~now:generated_at ~writer) entries) )
    ; "totals", Keeper_memory_health_totals.totals_to_json totals
    ; "alert_summary", Keeper_memory_health_totals.alert_summary_to_json totals
    ]
;;

(* One Keeper's row, the way the fleet answer carries it under [keepers]. A
   Keeper the fleet answer has no row for, one that left included, answers
   [null]: the answer says so itself, under the same workspace receipt as a
   row, instead of leaving it to a status a proxy could also send. The name is
   matched against the Keepers the fleet would list, so it never names a file
   on its own. *)
let keeper_memory_health_row_http_json ~base_path ~keeper =
  let config = Workspace.default_config base_path in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let generated_at = Time_compat.now () in
  register_row_roots ~config ~keepers_dir;
  let row =
    if List.exists (String.equal keeper) (health_keeper_ids ~keepers_dir)
    then
      keeper_health_entry_to_json
        ~now:generated_at
        ~writer:(Keeper_memory_writer_health.keeper_rows ~config)
        (cached_keeper_health ~config ~keepers_dir keeper)
    else `Null
  in
  `Assoc [ "schema", `String schema; "generated_at", `Float generated_at; "keeper", row ]
;;

(* Preserve each store's own revision and evidence rather than synthesizing a
   fleet-wide revision or treating collected claims as independently verified. *)
let workspace_memory_context_http_json = Workspace_memory_context.http_json

module For_testing = struct
  let keeper_health = keeper_health

  let invalidate ~base_path ~keeper =
    invalidate_after_store_write
      ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path)
      ~keeper_id:keeper
  ;;

  let with_runtime ~keeper_health:reader f =
    let previous_reader = !health_reader in
    Stdlib.Mutex.protect health_cache_mutex (fun () ->
      Hashtbl.reset health_cache;
      Hashtbl.reset row_roots);
    health_reader := reader;
    let restore =
      Keeper_memory_os_current.install_commit_observer invalidate_after_store_write
    in
    Fun.protect
      ~finally:(fun () ->
        restore ();
        health_reader := previous_reader)
      f
end
