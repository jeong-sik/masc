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
(** Select the exact retained frontier from the strictly validated durable inventory.
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
(** Publication must be confirmed from the exact durable owner record before
    permitting an effect. An unknown save never authorizes redispatch. *)
val result_to_json : Task.Anti_rationalization.review_result -> Yojson.Safe.t
val result_of_json : Yojson.Safe.t -> (Task.Anti_rationalization.review_result, string) result

val pending_commits : store:store -> installation_id:string -> package_id:string ->
  (retained list, load_error) result
(** Strict recovery discovery. Retained host judgments and domain commit intents are returned;
    this does not allocate a successor or authorize another provider. *)

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
