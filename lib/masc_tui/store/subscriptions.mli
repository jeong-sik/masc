(** Pure declarative SSE subscription planner matching {!Sse_hub.Stream_spec}.

    Guarantees at most 2 persistent streams ({!Stream_observer} +
    {!Stream_fleet}) plus at most 1 view-scoped stream across every workspace,
    sub-tab, dive, and overlay — zero idle polling. *)

type stream_id =
  | Stream_observer
  | Stream_fleet
  | Stream_model_metrics
  | Stream_tool_metrics_series
  | Stream_logs of { since_seq : int option }

val max_persistent_streams : int
(** [2]. *)

val max_view_scoped_streams : int
(** [1]. *)

val max_streams : int
(** [3] ([max_persistent_streams + max_view_scoped_streams]). *)

val is_persistent : stream_id -> bool
val equal_stream_id : stream_id -> stream_id -> bool
val equal_stream_kind : stream_id -> stream_id -> bool
(** Logical stream identity ignoring incremental [Stream_logs.since_seq] drift
    so arriving log lines do not trigger reconnect storms. *)

val equal_plan : stream_id list -> stream_id list -> bool
(** Compare plans by logical stream identity ({!equal_stream_kind}). *)

val plan : Model.t -> stream_id list
(** Compute the exact bounded set of active GET SSE streams for [model].
    Returns [[]] while waiting for authentication, server startup, or active
    workspace-mismatch re-handshake; otherwise returns
    [[Stream_observer; Stream_fleet]] plus at most 1 view-scoped stream. *)
