(** Dashboard HTTP monitoring — tool-call health, board, and Gate
    JSON builders for the dashboard server.

    Extracted from [server_dashboard_http.ml]. All builders are pure
    reads of on-disk stores ([Audit_log], board state, Gate log)
    plus wall-clock time; no side effects apart from reading. *)

(** Point-in-time slot occupancy / queue depth snapshot. *)
(** Per-executor outcome counts (success / failure / cancelled)
    aggregated from the audit log. *)