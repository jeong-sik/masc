(** Dashboard_http_autoresearch — autoresearch loop
    HTTP surface: list / detail / start / retry / delete
    + CSV export.

    External surface (8 entries) — every dotted caller
    reaches one of these and nothing else.  No
    cascade-include consumer.

    Internal helpers stay private at this boundary
    ([cycle_record_json], [delete_session_link],
    [ensure_managed_worktree], [escape_csv],
    [git_branch_exists], [json_bool_safe] /
    [json_number_safe] / [json_string_safe],
    [load_loop_state], [load_state_cached],
    [loop_summary_json], [persisted_summaries_cache],
    [persisted_to_loop_summary_json],
    [rehydrate_persisted_loop],
    [safe_active_entry_json] /
    [safe_persisted_entry_json], [updated_at_json]). *)

(** {1 Loop id validation} *)

val validate_loop_id : string -> (unit, string) result
(** Accepts ASCII alphanumerics + ['-'] / ['_'].  Returns
    [Error "invalid loop_id"] for an empty string or any
    other character class.  Pinned because each
    state-mutating handler ({!start_loop_json},
    {!retry_loop_json}, {!delete_loop_json}) gates its
    work on this check, and the routing layer reaches it
    directly from
    [server_routes_http_routes_dashboard]. *)

(** {1 Read paths} *)

val autoresearch_loops_json :
  base_path:string ->
  ?offset:int ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t
(** Returns the active + persisted loops envelope.
    [?offset] / [?limit] paginate; defaults are [0] /
    [100]. *)

val autoresearch_loops_csv : base_path:string -> string
(** Returns the active loops as a CSV document.  Used by
    the "export" button on the autoresearch dashboard. *)

val autoresearch_loop_detail_json :
  base_path:string ->
  loop_id:string ->
  history_limit:int ->
  (Yojson.Safe.t, string) result
(** Returns the detail envelope for [loop_id], capped to
    [history_limit] cycle records.  In-memory active
    loops short-circuit; otherwise falls back to the
    persisted store.  Errors as [Error msg] on missing or
    invalid input. *)

(** {1 Mutation handlers} *)

val start_loop_json :
  base_path:string ->
  args:Yojson.Safe.t ->
  (Yojson.Safe.t, string) result
(** Starts a new autoresearch loop.  [args] carries the
    JSON payload of the HTTP request — goal, branch, and
    optional knobs are pulled from this envelope. *)

val retry_loop_json :
  base_path:string ->
  loop_id:string ->
  (Yojson.Safe.t, string) result
(** Resumes a stopped or errored loop.  Validates
    [loop_id] via {!validate_loop_id} before reaching the
    autoresearch RW lane. *)

val delete_loop_json :
  base_path:string ->
  loop_id:string ->
  requester_agent:string option ->
  (Yojson.Safe.t, string) result
(** Deletes the loop and its session linkage.
    [requester_agent], when [Some _], is recorded on the
    audit trail.  Validates [loop_id] before doing any
    work. *)
