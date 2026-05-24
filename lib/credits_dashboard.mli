(** Credits_dashboard — AI service usage monitoring dashboard.

    Implements two HTTP endpoints:

    - [/dashboard/credits] — visual HTML dashboard rendered by
      {!html}.
    - [/api/v1/credits] — JSON API rendered by {!json_api}.

    Source of truth: [<base_path>/data/state/credits.json] —
    populated externally (cron / refresh job) and re-read on
    every dashboard hit.  No mutex needed; reads are best-effort
    and fall back to a synthetic ["error"] payload on missing
    file.

    Internal: 1 helper stays private —
    \[read_credits_json] (calls {!Safe_ops.read_json_file_safe}
    and discards the error variant).  Consumed only inside
    {!json_api}; HTML rendering inlines its own JSON fetch via
    a client-side fetch call. *)

val base_path : unit -> string
(** [base_path ()] is [Env_config_core.base_path ()].  Read on
    every call — env mutation between calls takes effect. *)

val credits_json_path : unit -> string
(** [credits_json_path ()] is
    [<base_path>/data/state/credits.json].  Pinned at the
    contract seam: external refresh jobs write to this exact
    path, so drift would silently break the data source. *)

val json_api : unit -> string
(** [json_api ()] is the response body for
    [/api/v1/credits].  Returns the credits JSON serialized as a
    string when the file exists + parses, otherwise the literal
    [{"error": "credits.json not found"}].  Operator-visible
    error string — drift breaks dashboard tooltips. *)

val color_class : float -> string
(** [color_class pct] returns the CSS class for a percentage:

    - [pct >= 70.0] -> ["green"]
    - [pct >= 30.0] -> ["yellow"]
    - else            -> ["red"]

    Pinned thresholds — drift would shift the green/red
    boundary across the entire dashboard. *)

val balance_class : float -> string
(** [balance_class bal] returns the CSS class for a balance
    amount (USD):

    - [bal >= 50.0] -> ["green"]
    - [bal >= 20.0] -> ["yellow"]
    - else            -> ["red"]

    Same pinning rationale as {!color_class} but with absolute
    dollar thresholds. *)

val html : unit -> string
(** [html ()] returns the complete HTML page for
    [/dashboard/credits] — a static template with embedded
    JavaScript that fetches [/api/v1/credits] on load.
    Self-contained string (no template engine). *)
