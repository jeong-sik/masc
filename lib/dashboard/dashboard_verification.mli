(** Dashboard projection for verification requests — the Mission detail table
    that surfaces Completion Contract + Required Evidence per
    {!Verification_protocol} request.

    Consumes {!Verification.list_requests}, which reads
    [<base_path>/.masc/verifications/*.json]. Pure read-only: no mutation, no
    network.

    Status mapping:
    - [Pending] | [Assigned _] -> ["pending"]
    - [Completed Pass]         -> ["approved"]
    - [Completed (Fail _)]     -> ["rejected"]
    - [Completed (Partial _)]  -> ["rejected"] (non-Pass verdicts block the gate)

    A [timed_out] status is reserved for future use when the timeout watcher
    persists a terminal state; the current state machine has no separate
    Timed_out variant, so this value is not emitted today.

    The envelope shape is:
    {[
      {
        "updated_at": "2026-04-17T...",
        "total": N,
        "requests": [ ... ]
      }
    ]}

    Per-request shape:
    {[
      {
        "request_id":         "vrf-1713280000-abc123",
        "task_id":            "task-foo",
        "task_title":         "Fix foo bottleneck" | "",
        "keeper":             "keeper-name" | null,
        "status":             "pending" | "approved" | "rejected" | "timed_out",
        "created_at":         "2026-04-17T...",
        "submitted_by":       "keeper-name",
        "approved_by":        "keeper-name" | null,
        "completion_contract": [ "criterion text", ... ],
        "required_evidence":   [ "evidence description or ref", ... ],
        "verdict":             "pass" | "fail" | "partial" | null,
        "verdict_reason":      "..."
      }
    ]}

    @since 0.9.10 *)

(** Build the JSON snapshot of verification requests.

    - [base_path]: read this runtime root. HTTP routes pass the active
      server config so a dashboard bound to a non-default base path does not
      show stale verification state.
    - [task_id]: when [Some id] (non-empty), return only requests whose
      [task_id] equals [id]. When absent or empty, return all tasks.
    - [limit]: clamped into [\[1, 500\]]; defaults to 100. Sort is
      reverse-chronological by [created_at] so the newest request wins
      when the cap trims. *)
val requests_json :
  base_path:string ->
  ?task_id:string ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t

(** Build a one-shot summary snapshot: status bucket counts plus the most
    recent rejections (carriers of verdict_reason / PR / issue refs).

    [base_path] has the same meaning as on {!requests_json}.

    The [recent] parameter is clamped into [\[0, 20\]] and defaults to 3.
    When [0], the ["recent_rejections"] array is empty but still present.

    Envelope:
    {[
      {
        "updated_at":        "2026-04-20T...",
        "total":             N,
        "by_status":         {"pending": _, "approved": _, "rejected": _,
                              "timed_out": _},
        "recent_rejections": [
          { "request_id":     "vrf-...",
            "task_id":        "task-...",
            "task_title":     "...",
            "keeper":         "keeper-name" | null,
            "verdict_reason": "...",
            "created_at":     "2026-04-20T..." },
          ...
        ]
      }
    ]} *)
val summary_json : base_path:string -> ?recent:int -> unit -> Yojson.Safe.t

(** Single-load companion to {!summary_json} + {!requests_json}.

    Handlers that emit both projections side-by-side
    ([/api/v1/dashboard/proof] is the live caller) previously called
    {!summary_json} and {!requests_json} back-to-back, each
    performing its own [Verification.list_requests] disk scan.
    [proof_compose] performs one scan and folds both projections
    from the shared list, halving the on-disk read cost per refresh.

    The two returned values use the same shapes documented on
    {!summary_json} and {!requests_json}. *)
val proof_compose :
  base_path:string ->
  ?recent:int ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t * Yojson.Safe.t
