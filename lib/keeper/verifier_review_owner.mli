(** Durable owner of one verifier review original.

    The immutable original of one verifier review attempt
    ({!Verifier_review_original.t}) is a decision's input, not a record; this
    module stores exactly one original per attempt and reads it back as the
    same value. Wakes restore that attempt. Only a known terminal transient
    refusal authorizes a linked successor whose input differs solely in its
    attempt identity; it never overwrites a previous attempt's record.

    Storage goes through {!Lane_addon_tool_request_owner}, which persists the
    complete canonical request before any dispatch and reads it back through
    the verified durable store. The owner record's [request_id] is the
    attempt key ["<verification_id>:attempt-<n>"], so one verification can
    hold many attempts and one attempt holds exactly one original.

    The owner record requires a [~summary]; a review original's summary is a
    short, canonical digest of the fixed subject and lookup grants, never a
    mutable pointer to current state. This module builds that summary from
    the original it is given, so the stored record names the same original the
    caller prepared. *)

type store = Lane_addon_store.t

type retain_error =
  | Original_invalid of string
      (** The original could not be serialised for storage. *)
  | Identity_mismatch of string
      (** The key does not name the original's own verification_id and attempt. *)
  | Retain_store_unavailable of string
  | Already_retained of string
      (** A different original already sits at this attempt key. *)

(* [load_error] deliberately names its store failure differently from
   [retain_error]'s [Retain_store_unavailable]: the two error types are not a
   recursion group, and sharing a constructor name would make the type-checker
   merge them, hiding [Already_retained] from [retain]'s mapping. *)
type load_error =
  | Load_store_unavailable of string
  | Not_found
  | Corrupt_original of string
      (** The stored bytes exist but do not decode to a review original. *)

type verification_scope = All_verifications | Verification of string
(** [Verification id] isolates only records whose summary, body identity,
    original key and verified digest independently agree. Routing metadata is
    not an executable Original; selected records still decode strictly.
    An unverifiable identity rejects the observation, never proves absence.
    [All_verifications] retains strict full-inventory validation. *)

val attempt_request_id : verification_id:string -> attempt:int -> (string, string) result
(** The owner-record key for one attempt: ["<verification_id>:attempt-<n>"].
    Attempts are non-negative integers; a negative attempt is an error. *)

val retain
  :  store:store
  -> verification_id:string
  -> attempt:int
  -> installation_id:string
  -> package_id:string
  -> Verifier_review_original.t
  -> (unit, retain_error) result
(** Store exactly one original under its attempt key. This is idempotent for
    the same original: storing the same original at the same key is a no-op.
    Storing a different original at an already-used key is
    {!Already_retained}, never an overwrite, so a retry under a fresh attempt
    cannot clobber a prior attempt's evidence. The owner record's summary is
    derived from the original's digest and is required, never defaulted. *)

val load
  :  store:store
  -> verification_id:string
  -> attempt:int
  -> (Verifier_review_original.t, load_error) result
(** Read the original stored at this attempt key back as the same value.
    [Not_found] means no original was retained here; a malformed, changed or
    unreadable record, or one whose body does not round-trip to the original,
    is an error, never a silent default. The caller owns workspace authority. *)

val load_for_destination :
  store:store -> verification_id:string -> attempt:int ->
  installation_id:string -> package_id:string ->
  (Verifier_review_original.t, load_error) result
(** Strict load plus the original installation, package, tool and summary
    binding. A different destination is refused before reviewer dispatch. *)

val next_attempt :
  store:store -> verification_id:string -> installation_id:string -> package_id:string ->
  (int, load_error) result
(** Select the exact retained frontier from the strictly validated durable
    inventory for this verification. Independently bound foreign identities
    are excluded before semantic Original decoding; target failures remain
    errors and never authorize a fresh attempt.
    New identities require a definite typed terminal retry and a durably linked
    successor preserving the complete frozen input. A wake alone never allocates.
    The host holds its workspace process lease and serializes this verification
    through allocation, retain and dispatch. Missing inventory starts at zero;
    unreadable or malformed records never authorize a partial allocation. *)

type retained
val original : retained -> Verifier_review_original.t
val progress : retained -> Lane_addon_request_progress.t
val load_retained : store:store -> verification_id:string -> attempt:int ->
  installation_id:string -> package_id:string -> (retained, load_error) result
val advance : store:store -> retained -> Lane_addon_request_progress.event ->
  (retained, load_error) result
val advance_events : store:store -> retained -> Lane_addon_request_progress.event list ->
  (retained, load_error) result
(** Fold existing events and publish their complete next history once. In
    particular judgment and its actual observer facts become visible together. *)
(** Publication must be confirmed from the exact durable owner record before
    permitting an effect. An unknown save never authorizes redispatch. *)
module For_testing : sig
  val advance_events :
    publish:(store:Lane_addon_store.t -> expected:Lane_addon_tool_request_owner.retained ->
      events:Lane_addon_request_progress.event list ->
      (Lane_addon_tool_request_owner.publication, Lane_addon_tool_request_owner.update_error) result) ->
    store:store -> retained -> Lane_addon_request_progress.event list -> (retained, load_error) result
end

val result_to_json : Task.Anti_rationalization.review_result -> Yojson.Safe.t
val result_of_json : Yojson.Safe.t -> (Task.Anti_rationalization.review_result, string) result

val retained_commits : store:store -> selection:verification_scope ->
  installation_id:string -> package_id:string ->
  (retained list, load_error) result
(** Strict selected original commit inventory including acknowledged terminal facts, so
    a queued stale Task snapshot cannot start another registry lifecycle. *)

val pending_commits :
  terminal_pending:(retained -> (bool, string) result) ->
  store:store -> selection:verification_scope -> installation_id:string -> package_id:string ->
  (retained list, load_error) result
(** Strict recovery discovery. Retained judgments/intents are returned, together
    with terminal facts whose canonical host publication is not acknowledged.
    The host's pure predicate authenticates the terminal receipt before omitting
    it. This does not allocate a successor or authorize another provider. *)

val judgment_to_json : original:Verifier_review_original.t -> notes:string ->
  Task.Anti_rationalization.review_result -> (Yojson.Safe.t, string) result
val judgment_of_json : original:Verifier_review_original.t -> Yojson.Safe.t ->
  (Task.Anti_rationalization.review_result * string, string) result
(** One durable host judgment binds the original digest, exact structured
    result and fully rendered domain notes in the same publication. *)

val validate_admission : Yojson.Safe.t -> (unit, string) result
(** Verify the retained no-dispatch observations and non-verdict result before
    re-admitting the same original. A known execution or unknown result cannot
    be reinterpreted as pre-admission. *)

val retry_result : Yojson.Safe.t -> (unit, string) result
(** Verify a definite terminal non-verdict and its typed retryable runtime
    observations. This shared reviewer disposition alone performs no retry;
    the subject owner must retain and confirm its exact successor first. *)

val terminal_result : Yojson.Safe.t -> (unit, string) result
(** Validate a definite settled non-verdict independently of automatic retry
    candidacy. Explicit subject requests may use this fact, never an unknown
    dispatch, to authorize their own durable linked retry. *)
