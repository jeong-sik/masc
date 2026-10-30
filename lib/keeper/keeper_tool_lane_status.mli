(** [keeper_lane_status] (RFC-0427 D-1): the execution lane's own account of
    itself. A projection of {!Keeper_sandbox_remote.report}, which is what
    this process learned from its own probes and dispatches to the keeper's
    endpoint. Reads endpoint declarations, dispatches nothing, stores nothing
    on disk;
    empty after a server restart, and says so. *)

val json_of_report : Keeper_sandbox_remote.lane_report -> Yojson.Safe.t
(** [lane], [endpoint], [probe] ({["state"]} not_asked | answered | failed),
    [last_dispatch] (null, or {["outcome"]} payload_finished | lane_failed
    with the failure class and the detail the keeper saw), and
    [operator_action]: guidance from the latest probe or dispatch observation.
    An answered probe also reports a kernel boot comparison scoped to this
    process and endpoint declaration, with workspace continuity unknown.
    A matching reported
    release needs no action; an unequal reported release and an unreported
    release have distinct guidance. An unreported release means provenance
    cannot be compared, not that a mismatch was established. A local timeout
    does not establish whether the payload started or what effects occurred;
    a remote timeout is the shim's report of its own payload timeout. *)

val handle :
  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> args:Yojson.Safe.t
  -> Yojson.Safe.t
(** The tool. A docker keeper hears that it has no remote lane; a microvm or
    remote_ssh keeper whose endpoint cannot be named from its declarations
    hears that as [unreachable] with the operator
    action; otherwise {!json_of_report} of the endpoint's report, with the
    keeper's [profile] added. *)
