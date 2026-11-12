(** Read-only fleet health for the current Memory OS snapshot. *)

(* RFC librarian-lifecycle §4.9. What the keeper's durable Librarian drain
   measured when its last pass ended, plus the last thing its journal says.
   The counters this used to carry were totals since the server booted, which
   answered "has anything ever gone wrong" and never "is this keeper behind
   now". *)
type librarian_health =
  { state : Keeper_librarian_queue_refresh.pass_end option
      (** [None] until this process has observed the keeper's durable drain.
          This does not describe a later working-Context organization pass. *)
  ; admission_wait : Keeper_librarian_pending.admission option
      (** What the latest explicit-admission pass left unfinished, independent
          of the durable measurement. [None] is no observed wait or failure,
          not a completed durable pass. *)
  ; measured_at : float option
  ; unread_atom_turns : int option
  ; unread_official_turns : int option
      (** [None] when the durable drain could not take the count; [state] says what
          the pass ran into. *)
  ; continuity_unread_atoms : int option
      (** How far the continuity snapshot trails the Librarian's read
          position: the position's [end_atom] less the snapshot's. A
          different lag from [unread_atom_turns], which counts the durable
          drain -- the two rounds fall behind separately, so one number does
          not stand for both (RFC librarian-lifecycle §4.9). [None] when
          either side is absent or unreadable, when they name different
          traces, or when the snapshot is ahead: none of those is a caught-up
          keeper, and a zero would say it was. *)
  ; last_success_at : float option
      (** [recorded_at] of the newest journal line the Librarian committed.
          An explicit write or retraction commits its own line and is not a
          Librarian success, so it neither sets nor clears this. *)
  ; last_failure_kind : string option
      (** The kind of the newest Librarian failure journaled after
          [last_success_at], or after the journal's start when the Librarian
          never committed. A failure older than the last success is not
          shown: the pass after it committed. *)
  ; stalled :
      ( Keeper_carried_front.librarian_gap option
        , Keeper_next_request_forecast.librarian_gap_unmeasured )
        result
      (** RFC librarian-lifecycle §4.10, rule 3: the atoms the Keeper's
          requests skip because the Librarian stands behind the start the
          provider last accepted. An alarm, not a Gate: nothing waits on it.
          [Ok None] while the Librarian point is at or past the accepted
          start, or when there is no accepted start yet. [Error] when a file
          the gap is read from did not read: neither "no gap" nor a gap. *)
  }

type context_cycle =
  { saved : Keeper_continuity_observation.frontier option
  ; saved_read_error : string option
  ; read_position : int option
        (** Where the Librarian has read to ({!Keeper_librarian_progress}),
            next to where its snapshot cuts ([saved]). The two move apart
            when the durable round commits and the continuity round does not,
            and a reader cannot tell that from [saved] alone: the snapshot
            still fits the history, so requests keep starting at its cut and
            carry every atom the failed rounds left behind (#37793). The
            distance is the subtraction; neither number is stored as one. *)
  ; read_position_read_error : string option
        (** ["progress_unreadable"] when the position file could not be read.
            [read_position] is then [None] for a reason, not for absence. *)
  ; rewriting_through : int option
        (** [catch_up_end_atom] of a snapshot the Librarian is rewriting from
            atom 0: where a request starts until the rewrite reaches it. Absent
            on a snapshot that is not being rewritten. *)
  ; unread_snapshot : (Keeper_librarian_unread.t list, unit) result
  ; unread_memory : (Keeper_librarian_unread.t list, unit) result
  ; prepared : Keeper_continuity_observation.t option
  ; synthesis : Keeper_continuity_observation.synthesis option
  }

let context_cycle ~config ~keeper_name =
  let saved, saved_read_error, rewriting_through, unread_snapshot =
    match Keeper_librarian_continuity.read ~config ~keeper_name with
    | Ok None -> None, None, None, Ok []
    | Ok (Some snapshot) ->
      ( Some { Keeper_continuity_observation.trace_id = snapshot.trace_id;
          end_atom = snapshot.end_atom; boundary_line = snapshot.end_boundary_line }
      , None
      , snapshot.catch_up_end_atom, Ok snapshot.unread_messages )
    | Error _ -> None, Some "snapshot_unreadable", None, Error ()
  in
  (* The position lives under the runtime keepers dir, next to the snapshot
     read above, not under the config keepers dir this handler's other
     stores use. Read from the config dir this was [Ok None] for every
     keeper and the screen said nothing had been read (#37870 fixed the
     same read in [continuity_unread_atoms]). *)
  let read_position, read_position_read_error =
    match
      Keeper_librarian_progress.read
        ~keepers_dir:(Workspace.keepers_runtime_dir config)
        ~keeper_id:keeper_name
    with
    | Ok None -> None, None
    | Ok (Some progress) -> Some progress.position.end_atom, None
    | Error _ -> None, Some "progress_unreadable"
  in
  let unread_memory = Keeper_memory_os_current.read_unread_messages
      ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path)
      ~keeper_id:keeper_name |> Result.map_error (fun _ -> ()) in
  { saved; saved_read_error; read_position; read_position_read_error; rewriting_through;
    unread_snapshot; unread_memory;
    prepared = Keeper_continuity_observation.latest ~config ~keeper_name;
    synthesis = Keeper_continuity_observation.latest_synthesis ~config ~keeper_name }
;;

let context_cycle_to_json cycle =
  let frontier (value : Keeper_continuity_observation.frontier) =
    `Assoc ["trace_id", `String value.trace_id; "end_atom", `Int value.end_atom;
      "boundary_line", `Int value.boundary_line] in
  let nullable encode = function None -> `Null | Some value -> encode value in
  let prepared (value : Keeper_continuity_observation.t) =
    (* [frontier] is the boundary a summary covers; the absorbed position has
       no boundary line, so its shape is the trace and the atom alone. *)
    let kind, input_frontier = match value.input with
      | Keeper_continuity_observation.Summarized value -> "summarized", frontier value
      | Absorbed { trace_id; end_atom } ->
        "absorbed", `Assoc ["trace_id", `String trace_id; "end_atom", `Int end_atom]
      | Without_snapshot -> "without_snapshot", `Null
      | Not_applied -> "not_applied", `Null in
    `Assoc ["prepared_at", `Float value.prepared_at; "runtime_id", `String value.runtime_id;
      "request_bytes", `Int value.request_bytes;
      "input", `Assoc ["kind", `String kind; "frontier", input_frontier]] in
  let unread = function
    | Ok messages -> `Assoc ["kind", `String "available";
        "messages", Keeper_librarian_unread.list_to_json messages]
    | Error () -> `Assoc ["kind", `String "unavailable"] in
  `Assoc ["unread", `Assoc ["snapshot", unread cycle.unread_snapshot;
      "memory", unread cycle.unread_memory];
    "saved", nullable frontier cycle.saved;
    "saved_read_error", nullable (fun value -> `String value) cycle.saved_read_error;
    "read_position", nullable (fun value -> `Int value) cycle.read_position;
    "read_position_read_error",
      nullable (fun value -> `String value) cycle.read_position_read_error;
    "rewriting_through", nullable (fun value -> `Int value) cycle.rewriting_through;
    "prepared", nullable prepared cycle.prepared;
    "synthesis", nullable Keeper_continuity_observation.synthesis_to_json cycle.synthesis]
;;

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
  ; context_cycle : context_cycle
  ; librarian : librarian_health
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

(* The durable drain publishes in this process, so its measurement is read from memory: the
   health request counts nothing itself and moves no position. *)
(* Read from the two files rather than from the round that writes them: the
   continuity round publishes nothing this process can read, and a health
   request that waited for one would show nothing for a keeper whose round
   has not run since boot. *)
(* [runtime_keepers_dir] is the root the read position lives under, one
   folder per keeper. The journal and the snapshots this handler otherwise
   reads are flat files under the config keepers dir, which the caller passes
   as [keepers_dir]. *)
let continuity_unread_atoms ~runtime_keepers_dir ~keeper_id saved =
  match (saved : Keeper_continuity_observation.frontier option) with
  | None -> None
  | Some frontier ->
    (match Keeper_librarian_progress.read ~keepers_dir:runtime_keepers_dir ~keeper_id with
     | Ok (Some { Keeper_librarian_progress.position = { trace_id; end_atom; _ }; _ })
       when String.equal trace_id frontier.Keeper_continuity_observation.trace_id
            && end_atom >= frontier.Keeper_continuity_observation.end_atom ->
       Some (end_atom - frontier.Keeper_continuity_observation.end_atom)
     | Ok (Some _) | Ok None | Error _ -> None)
;;

let librarian_health ~config keeper_id ~continuity_saved
    ~journal:{ Keeper_memory_journal_outcome.last_success_at; last_failure; facts_by_hour = _;
               read_error = _ } =
  let measurement = Keeper_librarian_queue_refresh.last_measurement ~config ~keeper_name:keeper_id in
  let last_failure_kind =
    Option.map Keeper_memory_os_journal_codec.librarian_failure_kind_to_string last_failure
  in
  { state = Option.map (fun (m : Keeper_librarian_queue_refresh.measurement) -> m.last_pass) measurement
  ; admission_wait = Keeper_librarian_queue_refresh.last_admission_wait ~config ~keeper_name:keeper_id
  ; measured_at =
      Option.map (fun (m : Keeper_librarian_queue_refresh.measurement) -> m.measured_at) measurement
  ; unread_atom_turns =
      Option.bind measurement (fun (m : Keeper_librarian_queue_refresh.measurement) ->
        Option.map (fun (u : Keeper_librarian_durable_consumer.unread) -> u.atoms) m.unread)
  ; unread_official_turns =
      Option.bind measurement (fun (m : Keeper_librarian_queue_refresh.measurement) ->
        Option.map (fun (u : Keeper_librarian_durable_consumer.unread) -> u.official) m.unread)
  ; continuity_unread_atoms =
      continuity_unread_atoms
        ~runtime_keepers_dir:(Workspace.keepers_runtime_dir config)
        ~keeper_id:keeper_id
        continuity_saved
  ; last_success_at
  ; last_failure_kind
  (* The gap, from small files alone, so a server that just started shows it
     before any drain has run here ({!Keeper_next_request_forecast.librarian_gap},
     the one rule {!Keeper_carried_front.librarian_gap}). The accepted start is
     the newest response-observed turn record, whichever lane recorded it: an
     official client's byte window cut counts the same way. A size refusal
     records no accepted start, so a turn that ended on one never raises this
     alarm.

     A read that fails goes into the payload as its own state, not onto the
     keeper's log. This is computed again on every health read, because the
     payload is a projection of the files and holds nothing between reads; a
     file that stays broken is one standing fact, and a log line per read would
     repeat it once per poll. The operator reads this screen, so the cause is
     carried where they look. *)
  ; stalled = Keeper_next_request_forecast.librarian_gap ~config ~keeper_name:keeper_id
  }
;;

let librarian_state_to_string = function
  | Keeper_librarian_queue_refresh.Off -> "off"
  | Lane_unconfigured -> "lane_unconfigured"
  | Drained -> "drained"
  | Yielded_to_waiting_unit -> "yielded_to_waiting_unit"
  | Pending _ -> "pending"
  | Not_committed -> "not_committed"
  | Stopped _ -> "stopped"
  | Raised _ -> "raised"
;;

let librarian_state_detail = function
  | Keeper_librarian_queue_refresh.Stopped error ->
    Some (Keeper_librarian_durable_consumer.error_to_string error)
  | Raised detail -> Some detail
  | Off | Lane_unconfigured | Drained | Yielded_to_waiting_unit | Pending _ | Not_committed -> None
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
let keeper_health ~config ~keepers_dir keeper_id =
  let source_health = source_health ~keepers_dir keeper_id in
  let context_cycle = context_cycle ~config ~keeper_name:keeper_id in
  let journal = Keeper_memory_journal_outcome.read ~keepers_dir ~keeper_id in
  let journal_error =
    Option.map
      (fun error -> "memory journal: " ^ Dated_jsonl.read_error_to_string error)
      journal.read_error
  in
  let librarian =
    librarian_health ~config keeper_id ~continuity_saved:context_cycle.saved ~journal
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
    ; context_cycle
    ; librarian
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
    ; context_cycle
    ; librarian
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
    ; context_cycle
    ; librarian
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
let health_base_paths : (string, string) Hashtbl.t = Hashtbl.create 4
let health_reader = ref keeper_health

let health_directory_identity path =
  try Unix.realpath path with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> path

let cache_entry ~keepers_dir keeper_id =
  Stdlib.Mutex.protect health_cache_mutex (fun () ->
    let key = health_directory_identity keepers_dir, keeper_id in
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

let invalidate_after_write ~keepers_dir ~keeper_id =
  let keepers_dir = health_directory_identity keepers_dir in
  let base_path = Stdlib.Mutex.protect health_cache_mutex (fun () ->
    Hashtbl.find_opt health_base_paths keepers_dir) in
  match base_path with
  | None -> ()
  | Some base_path ->
      (* A writer reports the root it wrote under. The Librarian keeps its
         progress under the runtime root while the fleet row is cached under
         the config root, so the reported root can name the same base path
         without being the key the row is cached under. Resolve to the row's
         own root before emptying it, or a position write leaves the row
         answering the position it had. *)
      let cached_dir =
        health_directory_identity
          (Config_dir_resolver.keepers_dir_for_base_path ~base_path)
      in
      (* An invalidation is a report about a row some read put there. Creating
         the row here instead would leave an entry nobody has read, kept alive
         only by its own invalidation. *)
      let entry =
        Stdlib.Mutex.protect health_cache_mutex (fun () ->
          Hashtbl.find_opt health_cache
            (health_directory_identity cached_dir, keeper_id))
      in
      (match entry with
       | None -> ()
       | Some entry ->
           Stdlib.Mutex.protect entry.mutex (fun () ->
             entry.generation <- entry.generation + 1;
             entry.value <- None))

let install () =
  let retained = ref [] in
  let register restore = retained := restore :: !retained in
  register (Keeper_memory_os_current.install_commit_observer invalidate_after_write);
  register (Keeper_memory_source_current.install_commit_observer invalidate_after_write);
  register (Keeper_librarian_progress.install_commit_observer invalidate_after_write);
  let refresh ~config ~keeper_name =
    invalidate_after_write
      ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path
        ~base_path:config.Workspace.base_path)
      ~keeper_id:keeper_name
  in
  register (Keeper_librarian_continuity.install_commit_observer refresh);
  register (Keeper_continuity_observation.install_change_observer refresh);
  register (Keeper_librarian_queue_refresh.install_change_observer refresh)
;;

let librarian_attention_required (librarian : librarian_health) =
  let durable = Option.bind librarian.state (function
    | Keeper_librarian_queue_refresh.Pending pending -> Some pending
    | Off | Lane_unconfigured | Drained | Yielded_to_waiting_unit
    | Not_committed | Stopped _ | Raised _ -> None) in
  Keeper_librarian_pending.attention_required ~durable ~admission:librarian.admission_wait
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
  (* RFC §4.9: a keeper standing behind is the thing to see, and the state
     says whether it is standing because something failed or because the
     Librarian is off. Off is not an alert. *)
  let stopped_alert =
    match h.librarian.state with
    | None | Some (Keeper_librarian_queue_refresh.Off | Drained | Yielded_to_waiting_unit | Pending _) -> []
    | Some ((Lane_unconfigured | Not_committed | Stopped _ | Raised _) as state) ->
      let behind =
        match h.librarian.unread_atom_turns, h.librarian.unread_official_turns with
        | Some atoms, Some official ->
          Printf.sprintf " %d turns are unread." (atoms + official)
        | Some _, None | None, Some _ | None, None -> ""
      in
      [ alert
          ~code:"librarian_stopped"
          ~severity:Keeper_memory_health_totals.Alert_warn
          ~target:"librarian_stopped"
          ~label:"Librarian"
          ~message:
            (Printf.sprintf
               "The keeper's Librarian pass ended as %s and waits for the next wake.%s%s"
               (librarian_state_to_string state)
               behind
               (match librarian_state_detail state with
                | Some detail -> " " ^ detail
                | None -> ""))
      ]
  in
  let attention_alert =
    if librarian_attention_required h.librarian then
      [ alert ~code:"librarian_attention_required"
          ~severity:Keeper_memory_health_totals.Alert_warn
          ~target:"librarian_attention_required" ~label:"Librarian"
          ~message:"Librarian processing or observation needs attention. Inspect the reported cause and retained recovery evidence before any replay; a wake does not confirm completion."
      ]
    else []
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
            "Librarian runs have failed since server start. The current-memory snapshot is available; see the last measured pass for the latest drain result."
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
  read_error_alert @ source_read_error_alert @ stopped_alert @ attention_alert @ failure_alert
  @ vision_ingest_alert
;;


let keeper_health_entry_to_json ~now (h : keeper_health) =
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
    ; "context_cycle", context_cycle_to_json h.context_cycle
    ; ( "librarian"
      , `Assoc
          [ ( "state"
            , match h.librarian.state with
              | Some state -> `String (librarian_state_to_string state)
              | None -> `Null )
          ; ( "detail"
            , match Option.bind h.librarian.state librarian_state_detail with
              | Some detail -> `String detail
              | None -> `Null )
          ; ( "pending"
            , match h.librarian.state with
              | Some (Keeper_librarian_queue_refresh.Pending pending) ->
                Keeper_librarian_pending.to_json pending
              | Some (Off | Lane_unconfigured | Drained | Yielded_to_waiting_unit
                     | Not_committed | Stopped _ | Raised _) | None -> `Null )
          ; ( "admission_wait"
            , match h.librarian.admission_wait with
              | Some admission ->
                Keeper_librarian_pending.to_json
                  (Keeper_librarian_pending.admission_pending admission)
              | None -> `Null )
          ; "operator_action_required", `Bool (librarian_attention_required h.librarian)
          ; ( "measured_at"
            , match h.librarian.measured_at with
              | Some ts -> `Float ts
              | None -> `Null )
          ; ( "unread_atom_turns"
            , match h.librarian.unread_atom_turns with
              | Some count -> `Int count
              | None -> `Null )
          ; ( "unread_official_turns"
            , match h.librarian.unread_official_turns with
              | Some count -> `Int count
              | None -> `Null )
          ; ( "continuity_unread_atoms"
            , match h.librarian.continuity_unread_atoms with
              | Some count -> `Int count
              | None -> `Null )
          ; ( "last_success_at"
            , match h.librarian.last_success_at with
              | Some ts -> `Float ts
              | None -> `Null )
          ; ( "last_failure_kind"
            , match h.librarian.last_failure_kind with
              | Some kind -> `String kind
              | None -> `Null )
          ; ( "stalled"
            , match h.librarian.stalled with
              | Ok (Some { Keeper_carried_front.gap_start_atom; gap_end_atom }) ->
                `Assoc
                  [ "kind", `String "gap"
                  ; "gap_start_atom", `Int gap_start_atom
                  ; "gap_end_atom", `Int gap_end_atom
                  ]
              | Ok None -> `Null
              | Error unmeasured ->
                `Assoc
                  [ "kind", `String "unmeasured"
                  ; ( "cause"
                    , `String
                        (Keeper_next_request_forecast.librarian_gap_unmeasured_cause
                           unmeasured) )
                  ; ( "detail"
                    , `String
                        (Keeper_next_request_forecast.librarian_gap_unmeasured_detail
                           unmeasured) )
                  ] )
          ] )
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

let schema = "keeper.memory_os.current_health.v15"

let fleet_cache_key ~base_path = "keeper_memory_health:" ^ base_path

(* What a row contributes to the fleet totals (RFC-0487 §2.5). *)
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
  ; unread_atom_turns = h.librarian.unread_atom_turns
  ; unread_official_turns = h.librarian.unread_official_turns
  ; continuity_unread_atoms = h.librarian.continuity_unread_atoms
  ; librarian_failures = h.librarian_failures
  ; vision_ingest_errors = h.vision_ingest_errors
  ; read_error = Option.is_some h.read_error
  ; source_read_error = Option.is_some h.source_read_error
  ; snapshot_present = h.snapshot_present
  ; librarian_stopped =
      (match h.librarian.state with
       | Some (Keeper_librarian_queue_refresh.Lane_unconfigured | Not_committed | Stopped _ | Raised _) ->
         true
       | Some (Off | Drained | Yielded_to_waiting_unit | Pending _) | None -> false)
  ; librarian_attention_required = librarian_attention_required h.librarian
  ; alerts = List.map fst (alerts h)
  }
;;

(* Both answers cache a Keeper's row under the config root, while a writer
   reports the root it wrote under: the Librarian keeps its progress and turn
   records under the runtime root. Register every root that names the same base
   path, or a write under one root finds no entry under the other and the row
   keeps answering the state it had. Kept in one place so the fleet answer and
   the single-row answer cannot drift apart. *)
let register_health_base_paths ~config ~keepers_dir ~base_path =
  Stdlib.Mutex.protect health_cache_mutex (fun () ->
    Hashtbl.replace health_base_paths (health_directory_identity keepers_dir) base_path;
    Hashtbl.replace health_base_paths
      (health_directory_identity (Workspace.keepers_runtime_dir config))
      base_path)
;;

let keeper_memory_health_http_json ~base_path =
  let generated_at = Time_compat.now () in
  let config = Workspace.default_config base_path in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path
  in
  register_health_base_paths ~config ~keepers_dir ~base_path;
  let entries =
    health_keeper_ids ~keepers_dir
    |> List.map (cached_keeper_health ~config ~keepers_dir)
    |> List.sort (fun (left : keeper_health) (right : keeper_health) ->
      compare
        (right.snapshot_bytes + right.source_snapshot_bytes)
        (left.snapshot_bytes + left.source_snapshot_bytes))
  in
  let totals = Keeper_memory_health_totals.of_rows (List.map totals_row entries) in
  `Assoc
    [ "schema", `String schema
    ; "generated_at", `Float generated_at
    ; "execution", Keeper_memory_execution_availability.(to_json (snapshot ~config ~mode:`Live))
    ; "keepers", `List (List.map (keeper_health_entry_to_json ~now:generated_at) entries)
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
  register_health_base_paths ~config ~keepers_dir ~base_path;
  let row =
    if List.exists (String.equal keeper) (health_keeper_ids ~keepers_dir)
    then keeper_health_entry_to_json ~now:generated_at (cached_keeper_health ~config ~keepers_dir keeper)
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
    invalidate_after_write
      ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path)
      ~keeper_id:keeper
  ;;

  let with_runtime ~keeper_health:reader f =
    let previous_reader = !health_reader in
    Stdlib.Mutex.protect health_cache_mutex (fun () ->
      Hashtbl.reset health_cache;
      Hashtbl.reset health_base_paths);
    health_reader := reader;
    let restore = Keeper_memory_os_current.install_commit_observer invalidate_after_write in
    Fun.protect
      ~finally:(fun () ->
        restore ();
        health_reader := previous_reader)
      f
end
