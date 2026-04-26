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

    - [task_id]: when [Some id] (non-empty), return only requests whose
      [task_id] equals [id]. When absent or empty, return all tasks.
    - [limit]: clamped into [\[1, 500\]]; defaults to 100. Sort is
      reverse-chronological by [created_at] so the newest request wins
      when the cap trims. *)
val requests_json : ?task_id:string -> ?limit:int -> unit -> Yojson.Safe.t

(** Build a one-shot summary snapshot: status bucket counts plus the most
    recent rejections (carriers of verdict_reason / PR / issue refs).

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
val summary_json : ?recent:int -> unit -> Yojson.Safe.t
