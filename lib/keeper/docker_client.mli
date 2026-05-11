(** RFC-0070 Phase 3a — Docker daemon client (signature only).

    Stub signatures. Implementation arrives in Phase 3b (Real) and
    Phase 3c (Mock + property tests). Phase 3a establishes the
    sandbox_error closed sum and the module type so that future caller
    cutover (Phase 3d) has a compilation-checked contract to migrate
    against.

    Reference: docs/rfc/RFC-0070-keeper-sandbox-pure-edge-separation.md §3.2

    Non-determinism contract: every function in {!S} is at the
    process boundary (docker daemon, network, host clock). All such
    calls return [result] with the typed {!sandbox_error}. No
    catch-all silent failure. *)

(** {1 Errors} *)

(** Closed sum — every docker daemon call returns one of these on
    failure. The reader is forced to handle each by exhaustive match.

    Phase 3b may refine arms with concrete payload fields (image
    digest, container name, exit code). Phase 3a keeps the variant
    skeleton minimal. *)
type sandbox_error =
  | Daemon_unreachable
  | Image_pull_failed
  | Container_oom
  | Exec_timeout
  | Probe_format_drift
  | Cleanup_failed

(** {1 Client interface} *)

(** Sandbox executor client. [Real] (Phase 3b) spawns docker via
    [Eio.Process]; [Mock] (Phase 3c) feeds injected responses for
    property-seeded replay tests. *)
module type S = sig
  (** Sandbox plan accepted by [run]. Concrete type bound at
      implementation time to {!Keeper_sandbox_plan.t} or a mock
      stand-in. *)
  type plan

  (** Captured execution result (exit code + stdout + stderr).
      Concrete shape lands in Phase 3b. *)
  type exec_result

  (** Parsed [docker ps] line. Phase 3b parses
      [docker ps --format '\{\{json .\}\}'] via ppx_deriving_yojson. *)
  type ps_record

  (** Opaque container handle (derived from
      {!Keeper_sandbox_plan.t}'s container_name in Phase 3b). *)
  type container_name

  val run
    :  plan
    -> (exec_result, sandbox_error) result

  val exec
    :  container:container_name
    -> cmd:string
    -> (exec_result, sandbox_error) result

  val ps_query
    :  labels:(string * string) list
    -> (ps_record list, sandbox_error) result

  val rm : container_name -> (unit, sandbox_error) result
end
