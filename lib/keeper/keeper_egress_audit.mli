(** Boot-time audit for keeper egress policy file placement (Leak 11).

    Inspects the file system without writes; classifies each keeper's
    [egress.json] location.  Boot hooks, tests, and ops tooling
    consume the structured results to decide on logging, alerting,
    or repair. *)

type audit_status =
  | Ok_present
  | Missing_at_expected of { expected_path : string }
  | Stale_orphan of { expected_path : string; orphan_path : string }

type result = {
  agent_name : string;
  keeper_name : string;
  sandbox_profile : Keeper_types.sandbox_profile;
  status : audit_status;
}

val audit_one :
  config:Coord.config -> meta:Keeper_types.keeper_meta -> result
(** Audit a single keeper's egress policy file location. *)

val audit_all :
  config:Coord.config ->
  metas:Keeper_types.keeper_meta list ->
  result list
(** Audit every keeper meta supplied; pure mapping over [audit_one]. *)

val host_direct_egress_path :
  config:Coord.config -> meta:Keeper_types.keeper_meta -> string
(** Pre-Leak-11 host-direct location: [playground/<name>/egress.json].
    Exposed so boot hooks and tests can construct the same path the
    audit uses for [Stale_orphan] detection. *)

val format_log_line : result -> string
(** Grep-friendly one-line summary tagged
    [[egress_audit:ok|missing|stale_orphan]]. *)

val partition : result list -> result list * result list * result list
(** Split into [(ok, missing, stale_orphan)] in input order. *)
