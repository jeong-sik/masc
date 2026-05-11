(** RFC-0070 Phase 3a — Pure construction of a docker run plan.

    Stub signatures only. Implementation arrives in Phase 3b. Phase 3a
    establishes the *type contract* so callers cannot drift before the
    plan/executor split lands; no caller is wired yet.

    Reference: docs/rfc/RFC-0070-keeper-sandbox-pure-edge-separation.md §3.1

    Determinism contract: every constructor in this module is a pure
    function of its declared inputs. No wall-clock, no Random, no global
    state. Same inputs ⇒ identical {!t}. *)

(** {1 Errors} *)

(** Closed sum — no catch-all. Phase 3b will extend with concrete arms
    as the constructor logic surfaces edge cases. *)
type plan_error =
  | Invalid_meta of string
  | Invalid_command of string
  | Unsupported_profile of string

(** {1 Plan} *)

(** Abstract sandbox-execution plan. Treat the type as opaque outside
    {!Sandbox_executor} (Phase 3c). *)
type t

(** [of_request ~turn_id ~attempt ~meta_name ~cmd] derives a plan from
    its declared inputs alone. Pure: no I/O, no clock, no random.

    Phase 3a stub: returns {!Error} {!Unsupported_profile} for every
    call. Phase 3b replaces with the real derivation against
    {!Keeper_sandbox.t} (and the wired
    {!Keeper_types.keeper_meta}-derived inputs).

    The signature accepts [meta_name] as a [string] in Phase 3a to keep
    this module's interface free of cross-module dependencies. Phase 3b
    swaps to a typed meta input. *)
val of_request
  :  turn_id:int
  -> attempt:int
  -> meta_name:string
  -> cmd:string
  -> (t, plan_error) result
