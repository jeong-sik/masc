(** Keeper_memory_os_reconcile — RFC-0259 §3.3 grounding reconciler (P2 core).

    A keeper accumulates facts about volatile external state ("PR #X is OPEN",
    "issue #Y blocked"). P1 ({!Keeper_memory_os_types.external_ref_of_claim}) gives
    such a fact a finite TTL; this module re-checks it against the source of truth
    so a still-true ref is kept fresh and a now-terminal ref is flagged.

    The IO (a [gh] call) is injected as {!verify_fn}, so the classification core is
    pure and fake-testable. P2 only classifies (dry-run, default-OFF fiber); P3
    turns the verdicts into the actual [last_verified_at] advance / retraction
    under the facts lock. The boundary is RFC-0259's: deciding *which* claim is
    externally-referenced is deterministic; the external state is the only IO. *)

open Keeper_memory_os_types

(** The current external state of a referenced PR/issue/task as seen by the
    injected verifier. Closed sum so every state is handled at compile time. *)
type external_state =
  | Still_open (** the ref is live (open PR/issue) — the claim's subject is active *)
  | Terminal
      (** the ref is merged/closed — a claim treating it as in-progress is stale *)
  | Unverifiable
      (** could not determine: network/transient, 404, or a kind not grounded yet
          (Task/Jira). Reconciliation never acts on this — uncertainty is not
          contradiction. *)

(** Injected external verifier. The live implementation shells out to [gh]; tests
    pass a deterministic fake. *)
type verify_fn = external_ref -> external_state

(** Per-fact reconciliation verdict. P2 classifies only; P3 maps these to the
    real advance/retract. *)
type verdict =
  | Fresh (** no [external_ref], or last verified within the horizon — leave alone *)
  | Stale_open (** past horizon, ref still open — P3 advances [last_verified_at] *)
  | Stale_terminal
      (** past horizon, ref terminal — P3 retracts (the live-store false-fact class) *)
  | Stale_unknown
      (** past horizon, ref unverifiable — skip; never delete on uncertainty *)

val verdict_to_string : verdict -> string

(** RFC-0259 §3.3: the default re-grounding horizon. Shorter than
    {!Keeper_memory_os_types.volatile_external_ttl_seconds} so a referenced fact is
    re-checked before it would otherwise hard-expire. *)
val default_grounding_horizon_seconds : float

(** Classify one fact. [Fresh] unless it carries an [external_ref] and has not been
    verified within [horizon]; then the injected [verify] decides. Pure. *)
val classify : now:float -> horizon:float -> verify:verify_fn -> fact -> verdict

type dry_run_report =
  { scanned : int
  ; stale_open : int
  ; stale_terminal : int
  ; stale_unknown : int
  }

(** Classify a keeper's facts. Returns aggregate counts plus the per-fact verdicts
    for the stale ones (in input order; [Fresh] facts are omitted to keep the
    dry-run log focused). *)
val dry_run
  :  now:float
  -> horizon:float
  -> verify:verify_fn
  -> fact list
  -> dry_run_report * (fact * verdict) list
