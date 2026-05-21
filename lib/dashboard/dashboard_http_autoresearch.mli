(** Dashboard_http_autoresearch — read-only historical autoresearch loop
    HTTP surface: list / detail + CSV export.

    External surface (8 entries) — every dotted caller
    reaches one of these and nothing else.  No
    cascade-include consumer.

    Internal helpers stay private at this boundary
    ([cycle_record_json], [escape_csv],
    [json_bool_safe] /
    [json_number_safe] / [json_string_safe],
    [load_state_cached],
    [loop_summary_json], [persisted_summaries_cache],
    [persisted_to_loop_summary_json],
    [safe_active_entry_json] /
    [safe_persisted_entry_json], [updated_at_json]). *)

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
