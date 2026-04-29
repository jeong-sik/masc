(** Institution_eio — Level-5 collective memory.

    Persists episodes / knowledge / patterns / cultural
    values into a single [institution.json] file and an
    append-only [institution_episodes.jsonl] tail.

    Two surfaces meet here:
    - The {b structured} institution snapshot
      ({!institution_of_json} / {!format_for_injection})
      consumed by [mcp_server_eio_resource.ml] when serving
      the institutional-memory resource;
    - The {b lightweight} JSONL tail
      ({!episodes_jsonl_path} / {!record_episode_jsonl} /
      {!load_recent_episodes_jsonl} / {!cap_episodes_jsonl})
      used by [memory_oas_bridge.ml],
      [server_dashboard_http.ml], and the keeper heartbeat
      path that needs to record an episode without an Eio
      switch in scope.

    The {!institution} record is kept abstract at this
    boundary because external callers
    ([mcp_server_eio_resource.ml],
    [tool_inline_dispatch_coord.ml]) only round-trip it
    through {!institution_of_json} → {!format_for_injection}
    without touching its fields.  The {!episode} record stays
    concrete because [.id] / [.summary] / [.participants] are
    pattern-accessed by every JSONL consumer. *)

(** {1 Episode} *)

type episode = {
  id : string;
  timestamp : float;
  participants : string list;
  event_type : string;
  summary : string;
  outcome : [ `Success | `Failure | `Partial ];
  learnings : string list;
  context : (string * string) list;
}
(** A single recorded episode.  [context] is a free-form
    key/value bag (e.g. [("trigger", "heartbeat")]).
    [outcome] is a polymorphic variant — the JSONL parser
    fail-closes on unknown values via {!outcome_of_string}
    so corrupted entries drop with a warn instead of being
    silently coerced to [`Partial]. *)

val outcome_to_string :
  [ `Success | `Failure | `Partial ] -> string
(** Wire encoder for [outcome] values.  Returns the
    lower-cased canonical label
    ([success] / [failure] / [partial]). *)

val outcome_of_string : string -> [ `Success | `Failure | `Partial ]
(** Parses an outcome wire string (the lower-cased
    [success] / [failure] / [partial]).  {b Raises}
    [Yojson.Safe.Util.Type_error] on unknown input — caller
    paths ([episode_of_json], [load_recent_episodes_jsonl],
    [load_institution]) already absorb the exception so a
    garbage / future-variant payload drops the entry instead
    of being mis-classified.  Matches the fail-closed sweep
    in #11256 (rejection of "Unknown → Permissive Default"). *)

val mentor_to_string :
  [ `Random | `Best_fit | `Round_robin ] -> string
(** Wire encoder for [mentor_assignment] strategy values.
    Returns the lower-cased canonical label
    ([random] / [best_fit] / [round_robin]). *)

val mentor_of_string :
  string -> [ `Random | `Best_fit | `Round_robin ]
(** Parses a mentor-assignment wire string
    ([random] / [best_fit] / [round_robin]).  {b Raises}
    [Yojson.Safe.Util.Type_error] on unknown input — same
    fail-closed contract as {!outcome_of_string} (#11675).
    Pinned for behaviour-tests under
    {!test/test_institution_of_string_fail_closed}. *)

val episode_to_json : episode -> Yojson.Safe.t
(** Wire encoder.  Field names mirror the record exactly;
    [outcome] becomes a string via the [outcome_to_string]
    table. *)

(** {1 Institution snapshot (abstract)} *)

type institution
(** Held abstract because callers do not pattern-match on its
    fields — the only consumers
    ([mcp_server_eio_resource.ml],
    [tool_inline_dispatch_coord.ml]) round-trip through
    {!institution_of_json} → {!format_for_injection}.  The
    .ml retains the concrete record (with [identity],
    [memory], [culture], [succession], [current_agents],
    [alumni] sub-records) for internal use. *)

val institution_of_json : Yojson.Safe.t -> institution
(** Decodes an institution snapshot from its on-disk
    representation.  May raise [Yojson.Safe.Util.Type_error]
    on a malformed payload — caller is expected to wrap
    accordingly (see [load_and_format_for_welcome] for the
    canonical absorbing pattern). *)

val format_for_injection :
  ?include_patterns:bool ->
  ?max_patterns:int ->
  institution ->
  string
(** Renders an institution as a Markdown-ish prompt block
    suitable for prepending to a fresh keeper's system
    prompt.  Sections: mission, generation/founded date,
    top-3 cultural values, recent episodes, optional
    pattern playbook (toggle via [include_patterns]; capped
    at [max_patterns], default 5). *)

(** {1 JSONL episode log} *)

val episodes_jsonl_path : unit -> string
(** [{!Common.masc_dir_from_base_path} ~base_path / "institution_episodes.jsonl"].
    Append-only path — readers can mmap or stream-parse
    safely without coordinating with writers. *)

val record_episode_jsonl :
  event_type:string ->
  summary:string ->
  participants:string list ->
  outcome:[ `Success | `Failure | `Partial ] ->
  learnings:string list ->
  episode
(** Eio-free episode appender.  Mints an [id]
    of the form [ep-<wall-secs>-<6 random digits>], stamps
    [timestamp] with the wall clock, sets [context = []],
    and appends the JSON to {!episodes_jsonl_path}.  Append
    failures are logged but {b not} re-raised — the keeper
    heartbeat path that calls this never aborts on a JSONL
    write failure ([Eio.Cancel.Cancelled] is re-raised
    intact). *)

val load_recent_episodes_jsonl : limit:int -> episode list
(** Reads the JSONL tail and returns the last [limit] valid
    entries.  Parse failures drop the offending line with a
    warn — corrupted entries do not poison the tail.  Order
    is on-disk order (oldest first within the returned
    slice). *)

val cap_episodes_jsonl : ?max_lines:int -> unit -> int
(** Atomically rewrites {!episodes_jsonl_path} to keep the
    most recent [max_lines] entries (default 500).  Returns
    the number of lines dropped (0 when no rewrite was
    needed).  Triggered by the flush path in
    [memory_oas_bridge.ml] to bound the JSONL footprint. *)

(** {1 Welcome / spawn injection} *)

val load_and_format_for_welcome :
  fs:'fs -> Coord_utils.config -> string
(** Loads the structured [institution.json] and returns a
    welcome-banner Markdown block (different surface than
    {!format_for_injection} — narrower, used by the
    operator dashboard and the inline dispatch path).
    Returns the empty string when the file is missing or
    any load / parse error occurs.  The [~fs] argument is
    accepted polymorphically and ignored by the .ml — the
    label is kept for signature parity with the prospective
    Eio-fs variant.  Existing callers pass either an
    [Eio.Path.t] (when an Eio context is available) or
    [()] (when not). *)
