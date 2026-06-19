(** Keeper_memory_os_grounding — RFC-0259 P2: observe-only grounding reconciler.

    Re-checks a fact's external_ref (P1) against GitHub and emits a PROVISIONAL,
    log-only verdict. Performs NO writes (never mutates a fact, advances
    [last_verified_at], or retracts) — its output is an [observation] the
    maintenance fiber logs so an operator can measure the cheap predicate's
    disagreement rate before P3 trusts it to retract. Introduces no numeric score:
    a closed-enum state and a closed 3-valued verdict only. Any uncertainty is
    [Indeterminate], never a false verdict. *)

open Keeper_memory_os_types

(** Re-checked external state (closed sum). *)
type fetched_state =
  | Open
  | Closed
  | Merged
  | Not_found

val fetched_state_to_string : fetched_state -> string

(** Abstention-biased provisional verdict. [Contradicted_candidate] is a logged
    hypothesis for P3, not grounds to retract. *)
type provisional_verdict =
  | Confirmed
  | Contradicted_candidate
  | Indeterminate

val provisional_verdict_to_string : provisional_verdict -> string

(** Injected external-state check (fake-able in tests). [Ok state] = determined;
    [Error _] = could not determine (mapped to [Indeterminate]). *)
type verify_external = external_ref -> (fetched_state, string) result

(** Pure, measurement-only classification: [Open] -> [Confirmed], terminal
    ([Closed]/[Merged]) -> [Contradicted_candidate], [Not_found] -> [Indeterminate].
    NOT a retraction rule; reads no claim text (P3 may refine). *)
val classify_state : fetched_state -> provisional_verdict

(** One re-checked fact's record, logged for P3 evidence. *)
type observation =
  { keeper_id : string
  ; ref_kind : external_ref_kind
  ; ref_id : string
  ; normalized_claim : string
  ; first_seen : float
  ; last_verified_at : float option
  ; age_seconds : float
  ; fetched : (fetched_state, string) result
  ; verdict : provisional_verdict
  }

(** Re-grounding horizon: a volatile claim is eligible once its truth anchor is
    older than this (a TIME, not a score). Defaults to the P1 volatile TTL. *)
val default_grounding_horizon_seconds : float

(** Default GitHub coordinates (the fiber may override via env). *)
val default_owner : string

val default_repo : string

(** Pure given [verify_external]: scan [facts], re-check each volatile claim past
    [grounding_horizon], return one observation per checked fact. Writes nothing. *)
val grounding_pass
  :  verify_external:verify_external
  -> now:float
  -> grounding_horizon:float
  -> keeper_id:string
  -> fact list
  -> observation list

(** Single-line log record (keeper, ref, normalized claim, age, fetched state or
    error, verdict). *)
val observation_log_line : observation -> string

(** Parse a GitHub GraphQL response body into a state; any unrecognized shape is
    [Error] -> [Indeterminate]. Exposed for unit tests. *)
val parse_state_response
  :  kind:external_ref_kind
  -> string
  -> (fetched_state, string) result

(** [verify_external] backed by a real GitHub GraphQL call. [timeout_sec] must be
    > 0 so a hung connection cannot stall the reconciler fiber. Returns [Error]
    (-> [Indeterminate]) on every failure path; never a false verdict. *)
val github_verify
  :  token:string
  -> clock:[> float Eio.Time.clock_ty ] Eio.Resource.t
  -> timeout_sec:float
  -> owner:string
  -> repo:string
  -> verify_external

(** Degenerate [verify_external] for when no token is provisioned: every ref is
    [Indeterminate]. *)
val no_token_verify : verify_external
