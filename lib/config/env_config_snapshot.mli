(** Env_config_snapshot — runtime config snapshot for the
    [masc_config] dashboard tool: per-category entry list
    + per-entry source provenance.

    External surface (3 entries) — every dotted caller
    reaches one of these and nothing else:
    - {!valid_config_category_strings} consumed by
      [tool_schemas_misc] when generating the
      [masc_config] tool enum + by
      [test/test_types].
    - {!all_categories} consumed by
      [env_config_introspect] +
      [test/test_types].
    - {!to_json} consumed by [env_config] (the
      facade) + [env_config_introspect].

    Internal helpers stay private at this boundary
    (~71 internal lets — [entry] /
    [source_provenance] record types, [entry] /
    [default_provenance] / [is_sensitive_name]
    constructors, [category] tuple builder,
    [server_entries] / [path_entries] / every other
    per-domain entry list, [read_entry] /
    [read_with_provenance] / [redact_value] / every
    JSON sub-renderer). *)

val valid_config_category_strings : string list
(** Wire forms accepted by the [masc_config] tool's
    [category] enum.  Mirrored into the OCaml category
    table inside the .ml so adding a category
    automatically updates both the parser and the
    schema's user-visible catalogue (#8493). *)

val all_categories : unit -> (string * Yojson.Safe.t) list
(** Returns the per-category entry list as
    [\[(category_name, `List entries)\]] tuples.
    Computed on demand from the per-domain entry
    declarations inside the .ml. *)

val to_json :
  ?server_meta:Yojson.Safe.t ->
  ?generated_at:string ->
  ?cat:string ->
  unit ->
  Yojson.Safe.t
(** Renders the full config snapshot envelope.  When
    [?cat] is provided and matches a known category, the
    response is narrowed to that single section; an
    unknown name collapses to an empty
    [`Assoc \[\]] for the categories field rather than
    raising.  [?server_meta] / [?generated_at] are
    threaded into the envelope when present. *)
