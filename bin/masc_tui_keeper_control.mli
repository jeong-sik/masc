(** Keeper lifecycle control for the TUI Keepers surface.

    The TUI reads a keeper from two places that answer different questions.
    Durable metadata on disk says whether an operator paused it; the live
    roster at [GET /api/v1/gate/keepers] says whether a keepalive fiber is
    running it. Neither alone decides which lifecycle action applies, so this
    module joins them into one typed reading and derives the offered actions
    from it.

    Nothing here performs I/O. {!plan} names the HTTP steps an action takes
    and the caller executes them, so the sequence stays testable without a
    server. *)

(** What the live roster says about one keeper.

    [Unobserved] and [Absent] are kept apart because they license different
    actions: a roster that failed to load says nothing about whether a fiber
    is alive, while a roster that loaded and omits the keeper says the fiber
    is not there. Collapsing them offers boot to a keeper that is already
    running, which is how a live lane gets a second fiber. *)
type liveness =
  | Unobserved
  | Absent
  | Present of Masc.Tui_decode.keeper_runtime

(** The live roster reading as a whole.

    [Roster_partial] carries a roster missing rows it should have had.
    [GET /api/v1/gate/keepers] reports both how many rows it returned and how
    many exist, and those disagree in two ways: the route clamps its own limit,
    and it drops a keeper whose metadata it could not read. A keeper missing
    from such a roster may be past the limit or unreadable, so its absence is
    not evidence that no fiber is running it. Reading it as [Absent] showed ten
    running keepers as offline, and offered to boot every one of them, on a
    live fleet whose store the server could not parse. *)
type roster =
  | Roster_unobserved
  | Roster_partial of
      { observed : Masc.Tui_decode.keeper_runtime list
      ; total : int
      }
  | Roster_complete of Masc.Tui_decode.keeper_runtime list

val roster_of_reading :
  rows:Masc.Tui_decode.keeper_runtime list ->
  truncated:bool ->
  total:int ->
  roster
(** Build the roster from what the route answered. Complete only when the route
    said it was not clamped {i and} returned as many rows as it said exist. *)

(** Why the roster reading is missing.

    [Unauthorized] is separate because it is the operator's to fix and names
    what to do; every lifecycle action on this surface needs the same token, so
    a surface that only said "the read failed" would leave the whole Keepers
    view inert with no way to tell why. *)
type roster_failure =
  | Roster_unauthorized
  | Roster_unreachable of string
  | Roster_malformed of string

val roster_failure_message : credential_sent:bool -> roster_failure -> string
(** One terminal line naming the failure and, where there is one, the action
    that clears it.

    [credential_sent] is whether the request carried a bearer at all. A refusal
    with one is a rejected credential and a refusal without one is a missing
    credential; only the second is fixed by providing a token, and one line
    used to give that advice for both. *)

val roster_failure_of_status : status:int -> body:string -> roster_failure
(** Classify a non-2xx roster read. Decided on the status code, so a server
    error whose prose mentions tokens is not reported as a missing token. *)

val liveness_of_roster : roster -> string -> liveness
(** What the roster says about one keeper by name. An incomplete roster can
    only confirm presence, never absence. *)

(** One keeper as the Keepers surface reads it: durable pause from metadata,
    live runtime from the roster. *)
type reading = {
  name : string;
  paused : bool;
  liveness : liveness;
}

val display_status :
  reading -> Masc.Keeper_status_runtime.control_plane_status option
(** The published control-plane status for a reading, composed the way the
    operator snapshot composes it: operator pause overrides the surface
    status. [None] when the roster was not observed, because durable metadata
    cannot answer what a keeper's live status is. *)

val status_label : reading -> string
(** Terminal label for {!display_status}, or ["unread"] when the roster was
    not observed: the roster has not been read for this keeper, which is a
    fact about the reading, not a status the keeper is in. *)

(** A lifecycle action the operator can take on one keeper.

    The pairs are deliberate. [Pause] and [Resume] move a live lane in and out
    of sleep and keep the fiber; [Shutdown] and [Boot] end and start the
    fiber. [Wakeup] asks a live lane to attempt its next turn now. *)
type action =
  | Pause
  | Resume
  | Boot
  | Shutdown
  | Wakeup

val action_key : action -> string
(** The single key that submits the action on the Keepers surface. *)

val action_label : action -> string

val action_gerund : action -> string
(** Present-tense label for an action already in flight ("pausing"). *)

val requires_confirmation : action -> bool
(** True for the actions that end a fiber. The second press is what submits
    those, matching the Approvals surface's arm-then-submit gate; the
    reversible actions submit on the first press. *)

val available : reading -> action list
(** The actions that apply to a reading, in the order the footer lists them.

    An unobserved roster offers none: acting on a keeper whose live state is
    unknown is how a running lane gets a second fiber. *)

val primary : reading -> action option
(** The action bound to the toggle key — the one an operator means by "stop"
    or "play" for this reading. [None] when the reading admits none. *)

(** One HTTP step of an action. *)
type step =
  | Lifecycle of string
      (** [POST /api/v1/keepers/<name>/<action>] with an empty JSON body. *)
  | Directive of string
      (** [POST /api/v1/keepers/<name>/directive] with this action name. *)

val plan : action -> step list
(** The steps an action takes, in order. A step that fails ends the plan,
    except where {!recovers_from_conflict} names a continuation. *)

val recovers_from_conflict : action -> step list option
(** For [Boot], the steps to run when the plan answers 409: a keeper the
    operator paused refuses a plain boot, and the durable pause has to be
    committed away through the directive endpoint before the fiber starts.
    This is the sequence [bin/keeper_canary_run.ml] established live against a
    running server.

    [None] for every other action — a 409 there is a rejection to report, not
    a step to route around. *)

(** {1 Response classification} *)

(** What one step's HTTP answer means to the plan. *)
type outcome =
  | Accepted of { already_live : bool }
      (** 2xx. [already_live] is the server saying a boot found the fiber
          already running and woke it instead of starting a second one. *)
  | Paused_owner_conflict of string
      (** 409 — the durable owner state refuses this step. For [Boot] this is
          the answer {!recovers_from_conflict} exists for. *)
  | Rejected of { status : int; detail : string }

val classify_response : status:int -> body:string -> outcome
(** Read one step's answer. The 409 that routes a boot into its recovery is
    decided by the status code, so a rejection whose prose happens to mention
    pausing is still a rejection. A body that is not the [{ok, error}] shape
    degrades to its own text rather than to silence: the operator needs to see
    what the server said even when it said it in an unexpected shape. *)

(** {1 Confirmation gate} *)

type pending = {
  pending_keeper : string;
  pending_action : action;
}

type gate =
  | Gate_submit
  | Gate_arm of pending
  | Gate_blocked_inflight

val gate_transition :
  inflight:bool -> pending:pending option -> keeper:string -> action -> gate
(** Where a keypress lands. An action already in flight blocks a second one.
    An action that {!requires_confirmation} arms on the first press and
    submits when the same keeper and action are pressed again; anything else
    submits at once. *)

(** {1 Wire bodies} *)

val directive_body : operator_operation_id:string -> string -> string
(** JSON body for a directive step. [resume] carries the operation id so a
    retry names the same operation; the other directives ignore it. *)

val lifecycle_body : string
(** JSON body for a lifecycle step. *)

val mint_operation_id : keeper:string -> serial:int -> string
(** The resume operation id for one attempt. Stable across the steps of that
    attempt, so the resume inside a boot recovery names one operation rather
    than a new one per step. *)
