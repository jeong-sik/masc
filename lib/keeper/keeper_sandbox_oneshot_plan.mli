(** RFC-0070 Phase 3b-iii — Pure construction of a docker run plan.

    Real (no longer stub) implementation of {!of_request}. Phase 3a
    established the type contract with [Error] [Unsupported_profile]
    (a Phase-3a-only catch-all, now removed) for every call; Phase
    3b-iii returns a populated {!t}.

    Reference: docs/rfc/RFC-0070-keeper-sandbox-pure-edge-separation.md §3.1

    Determinism contract: same [(turn_id, attempt, meta_name, cmd)] ⇒
    identical {!t}. No wall-clock, no Random, no global state.

    Scope of Phase 3b-iii: the record exposes the four most-needed
    fields ([container_name], [image], [command], [timeout_budget_sec]).
    Mount, ulimit, and network_mode are deferred to Phase 3b-iv where
    they arrive as typed records together with the [Real]
    [Docker_client] implementation. *)

(** {1 Errors} *)

(** Closed sum — no catch-all. Phase 3b-iii narrows from Phase 3a's
    [Unsupported_profile] catch-all (now removed) to two concrete
    validation arms. Phase 3b-iv may add more as Mount / Network
    validation lands.

    The [string] payload on each arm is the *offending input value*,
    not a human-readable message. Display strings are caller-formatted
    from the variant + payload at the error site, so payload semantics
    stay stable and grep-able. *)
type plan_error =
  | Invalid_meta of string  (** payload = the offending [meta_name] (often [""]) *)
  | Invalid_command of string  (** payload = the offending [cmd] (often [""]) *)

(** {1 Plan} *)

(** Abstract sandbox-execution plan. Treat the type as opaque outside
    {!Sandbox_executor} (Phase 3c) — accessor functions below expose
    only what callers need. *)
type t

(** {1 Constructor} *)

(** [of_request ~turn_id ~attempt ~meta_name ~cmd] derives a plan from
    its declared inputs alone. Pure: no I/O, no clock, no random.

    Validation:
    - [meta_name] must be non-empty (returns [Invalid_meta meta_name]
      otherwise — the offending value is the payload).
    - [cmd] must be non-empty (returns [Invalid_command cmd] otherwise).

    Fields populated:
    - [container_name = Keeper_container_name.derive ~algo:SHA_256
      ~turn_id ~attempt ~suffix:meta_name]
    - [image = default_image] (Phase 3b-iv: caller-provided)
    - [command = cmd]
    - [timeout_budget_sec = default_timeout_budget_sec] (Phase 3b-iv:
      caller-provided)

    The signature accepts [meta_name] as a [string] in Phase 3a/3b-iii
    to keep this module's interface free of cross-module dependencies.
    Phase 3b-iv swaps to a typed meta input. *)
val of_request
  :  turn_id:int
  -> attempt:int
  -> meta_name:string
  -> cmd:string
  -> (t, plan_error) result

(** {1 Accessors} *)

val container_name : t -> Keeper_container_name.t

val image : t -> string

val command : t -> string

(** Timeout budget in seconds. Phase 3b-iv replaces with [Eio.Time.span]
    once Eio is wired into the plan layer. *)
val timeout_budget_sec : t -> float

(** {1 Equality / pretty-print for tests} *)

val equal : t -> t -> bool

val pp : Format.formatter -> t -> unit

(** {1 Phase 3b-iii defaults} *)

(** Default container image — RFC-0070 Phase 3b-iv will replace with
    a typed {!Image.digest} resolved from keeper config. Public for
    test visibility only. *)
val default_image : string

(** Default per-turn timeout — Phase 3b-iv parameterises. *)
val default_timeout_budget_sec : float
