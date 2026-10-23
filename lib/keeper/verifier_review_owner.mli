(** Durable owner of one verifier review original.

    The immutable original of one verifier review attempt
    ({!Verifier_review_original.t}) is a decision's input, not a record; this
    module stores exactly one original per attempt and reads it back as the
    same value. A retry is a new attempt, so it stores under a new request
    identity and never overwrites a previous attempt's record.

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
  | Store_unavailable of string
  | Already_retained of string
      (** A different original already sits at this attempt key. *)

type load_error =
  | Store_unavailable of string
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
