(** Server_dashboard_http_namespace_truth_support —
    namespace-truth snapshot composition + focus / queue
    extraction for the dashboard HTTP facade.

    External surface (3 entries) — every dotted caller
    reaches one of these and nothing else:
    - {!compose_namespace_truth_snapshot} consumed by
      {!Server_dashboard_http_namespace_truth} (also
      reached via the
      [module Namespace_truth_support = ...] alias inside
      that module).
    - {!compose_namespace_truth_initializing} consumed by
      {!Server_dashboard_http_namespace_truth} for the cold-start
      fast path so even the minimal warming response keeps canonical
      surface/source/retention metadata.
    - {!dashboard_namespace_truth_focus_json} consumed by
      {!Server_dashboard_http} as a one-line
      pass-through (no runtime-include re-export — the
      facade uses an explicit [let .. = ...] binding).

    Internal helpers stay private at this boundary
    (everything else in the implementation.  Notably:
    pending-confirm summary cache state +
    [pending_confirm_summary_*] helpers,
    [json_*_field] envelope readers,
    [attention_event_json], [derive_readiness_and_attention],
    [execution_summary_json],
    [execution_top_queue]). *)

val dashboard_namespace_truth_focus_json :
  initialized:bool ->
  runtime_count:int ->
  top_queue:Yojson.Safe.t ->
  Yojson.Safe.t
(** Renders the namespace-truth focus / suggested-action
    block from the top execution-queue entry.  When
    [top_queue] is present, it derives [suggested_tab],
    [suggested_surface], [suggested_params] from the
    queue head action.  Otherwise it reports the
    namespace initialization/runtime state. *)

val compose_namespace_truth_snapshot :
  config:Workspace.config ->
  initialized:bool ->
  shell_json:Yojson.Safe.t ->
  execution_json:Yojson.Safe.t ->
  command_summary_json:Yojson.Safe.t ->
  Yojson.Safe.t
(** Composes the full namespace-truth snapshot from the
    shell / execution / command-summary inputs.  Folds in
    {!dashboard_namespace_truth_focus_json} for the focus
    block and the cached pending-confirm summary
    (TTL'd 10 s, stale-served up to 30 s).  Used by
    {!Server_dashboard_http_namespace_truth} as the
    SSOT producer for the [namespace_truth] HTTP route. *)

val compose_namespace_truth_initializing :
  config:Workspace.config -> message:string -> Yojson.Safe.t
(** Composes the namespace-truth cold-start response with the same
    top-level [dashboard_surface], [dashboard_aliases], [source],
    [retention], and [generated_at_iso] metadata used by the warm
    read-model. *)
