(** RFC-0506: detect Skill names activated recently whose package is gone
    from every catalog source, and record a structured [skill_missing_on_disk]
    warning. Observation only — a ghost is never blocked or restored. *)

type ghost =
  { skill_name : string  (** [package_id] of the missing Skill *)
  ; source_id : string  (** source recorded by the activation identity *)
  ; last_activated_at : string
        (** latest in-window activation instant, exactly as the ledger
            recorded it *)
  ; expected_source_path : string
        (** where the [SKILL.md] would live: the recorded source's resolved
            path plus the package directory, or an [unresolved-source:...]
            marker when the snapshot cannot resolve that source. *)
  }

(** RFC-0506 §1: the activation window, in seconds (7 days). *)
val window_seconds : float

(** Structured event name recorded for one ghost. *)
val event_type : string

(** JSON payload of the runtime-observer event for one ghost. *)
val event_json : ghost -> ts_unix:float -> Yojson.Safe.t

(** Pure projection: names with an activation inside the window that no
    effective catalog entry provides. [activations] are (identity,
    activated_at) pairs exactly as the retained ledgers recorded them. An
    unparseable timestamp still counts as recent — detection errs toward
    recording. *)
val ghosts :
  now:float ->
  snapshot:Skill_catalog_snapshot.t ->
  activations:(Skill_reference.identity * string) list ->
  ghost list

(** Scan the workspace's retained activation ledgers against [snapshot] and
    record every ghost: one WARN log line, one [skill_missing_on_disk] audit
    row and one runtime-observer event each. Never raises; a detection
    failure is logged and leaves the publication that triggered it
    untouched. Returns the ghosts that were recorded. *)
val detect_and_record :
  base_path:string -> snapshot:Skill_catalog_snapshot.t -> ghost list
