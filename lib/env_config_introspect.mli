(** Env_config_introspect — root-level config introspection
    wrapper.

    The canonical category definitions, masking rules, and source
    attribution live in [Env_config_snapshot] inside the
    [masc_config] sub-library. This wrapper adds root-runtime
    metadata that is only available from the main server library
    ([Version.version], [Server_startup_state.elapsed_since_start],
    [Sys.ocaml_version], the live PID, and [MASC_BUILD_GIT_COMMIT]).

    Internal helper [server_meta] is hidden — callers consume only
    the two JSON entry points. *)

val to_json : unit -> Yojson.Safe.t
(** Render the full snapshot as a JSON object with the
    [server] / [generated_at] / [categories] top-level keys.
    [generated_at] is the ISO-8601 timestamp at call time;
    [server] embeds version / git_commit / ocaml_version /
    uptime_seconds / pid; [categories] is the full
    {!Env_config_snapshot.all_categories} table. *)

val to_json_filtered :
  ?cat:string ->
  unit ->
  Yojson.Safe.t
(** Like {!to_json} but restricts the [categories] table to the
    single entry whose key equals [cat] (case-sensitive). When
    [cat] is omitted or names a missing category, the [categories]
    object is empty for the latter case and unchanged from
    {!to_json} for the former. Used by [tool_misc_admin] for the
    operator [/admin/config?cat=...] endpoint. *)
