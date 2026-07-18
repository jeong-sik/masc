(** Process-owned Board-attention partition judgment plane.

    Producers synchronously persist candidates and send only coalescing wake
    hints. At most one actor runs for a durable Keeper identity at a time;
    actors are scheduled from durable work rather than kept alive without
    work. Therefore a provider wait or failure in one Keeper never occupies
    that Keeper's normal turn admission and never serializes sibling judgment
    lanes. Concurrent actor count is derived from durable Keeper identities
    rather than a configured cap.

    The partition ledger is the work authority. Process-local wake state may
    coalesce or disappear across restart without losing work because startup
    scans every candidate ledger. *)

module Candidate = Keeper_board_attention_candidate
module Partition = Keeper_board_attention_partition

type wake_result =
  | Signaled
  | Coalesced
  | Worker_not_registered
  | No_signal_required

type record_acceptance =
  { candidate : Candidate.candidate
  ; persistence : Candidate.persistence
  ; signal : wake_result
  }

val record_and_notify :
  base_path:string -> Candidate.candidate -> (record_acceptance, string) result
(** Commit the candidate before signaling the worker. Never invokes a model or
    touches a Keeper turn switch. *)

val drain_completed_on_owner_lane :
  base_path:string -> keeper_name:string -> (Candidate.drain_report, string) result
(** Apply completed durable partition results and resume current-schema
    crash-recovered [Judged] rows. This path never calls a provider. A
    partition is marked [Settled] only after all candidate deliveries are
    durably [Consumed]. *)

val health_json : base_path:string -> Yojson.Safe.t
(** Combine exact durable partition state with process worker registration.
    Durable work without a registered worker is degraded and requires
    operator action. *)

val placeholder_health_json :
  status:Health_status.t -> component_timed_out:bool -> Yojson.Safe.t
(** Typed non-live projection used while full health is warming, unavailable,
    failed, or timed out. Field ownership remains here so server placeholders
    cannot drift from {!health_json}. A caller must not pass [Health_status.Ok]. *)

val start :
  sw:Eio.Switch.t ->
  base_path:string ->
  unit ->
  unit
(** Register one worker instance, startup-scan durable candidate ledgers, and
    run the dispatcher until [sw] closes. Duplicate live registration for the
    same base path is rejected. *)

module For_testing : sig
  val start_with_judge :
    sw:Eio.Switch.t ->
    base_path:string ->
    worker_epoch:Partition.Worker_epoch.t ->
    judge:
      (Candidate.candidate list ->
       (Candidate.judgment Candidate.Candidate_map.t, Candidate.retryable_failure) result) ->
    unit ->
    unit

  val registered : base_path:string -> bool
  val active_keeper_count : base_path:string -> int
end
