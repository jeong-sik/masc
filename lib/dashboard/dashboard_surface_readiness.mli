(** Dashboard_surface_readiness — operator-surface readiness
    JSON dump.

    Single-entry boundary.  External callers (the dashboard
    HTTP route, [tool_operator], and the readiness regression
    test) reach exactly {!json}; everything else stays
    private.

    Internal helpers stay private at this boundary
    ([verification_refs] / [surface_entry] types,
    [ref_json], [route_ref_prefix] /
    [route_ref_prefix_string], [live_spotcheck_kind],
    [refs_json], [entry_json], [all_entries],
    [find_entry]). *)

val json : ?surface_id:string -> unit -> Yojson.Safe.t
(** Renders the operator surface-readiness snapshot.

    With [?surface_id] omitted, returns the full catalogue
    of surfaces with their fixture / live-spotcheck
    verification refs.  When [?surface_id] is provided and
    matches a known surface, the response is narrowed to
    that single entry; an unknown id collapses to an empty
    [surfaces] list rather than raising.

    The envelope shape is:
    [{ "generated_at": ISO-8601 timestamp,
       "proof_bar": "fixture+live_spotcheck",
       "surfaces": [...] }]. *)
