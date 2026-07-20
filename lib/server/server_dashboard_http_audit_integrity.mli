(** Audit-integrity dashboard HTTP JSON helper.

    Runs [Shared_audit.Store.verify] over the per-keeper resilience audit
    logs and produces a read-only snapshot for the
    /api/v1/dashboard/audit-integrity endpoint. *)

val audit_integrity_http_json : base_path:string -> Yojson.Safe.t
