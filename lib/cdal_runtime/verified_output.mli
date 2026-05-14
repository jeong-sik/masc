(** Phantom-typed verified output — compile-time enforcement of output verification.

    In a multi-agent society, agent outputs must be verified before
    being used as final results.  This module uses OCaml phantom types
    to make it impossible to use unverified outputs where verified
    ones are required.

    {b Key guarantee}: The function {!val-content} only accepts
    [verified output], so unverified outputs cannot be used as
    final results.  This is enforced at compile time — no runtime
    checks needed.

    Usage:
    {[
      (* Producer creates unverified output

    @stability Evolving
    @since 0.93.1 *)
      let raw = Verified_output.of_response ~producer:"alice" response in

      (* Verifier checks and marks as verified *)
      let result = Verified_output.verify raw
        ~verifier:"bob" ~confidence:0.95 ~evidence:"cross-checked" in
      match result with
      | Some verified ->
        (* Only verified outputs can extract content *)
        let response = Verified_output.content verified in
        ...
      | None -> (* verification failed *)
    ]}

    Inspired by the 17x Error Trap (Bag of Agents anti-pattern):
    in a 10-stage agent chain with 99% per-stage reliability,
    overall reliability drops to 90.4%.  Phantom types make
    unverified pipeline stages a compile error, not a runtime bug.

    @since 0.76.0 *)

(** {1 Phantom type tags} *)

(** Type-level tag: output has not been verified. *)
type unverified

(** Type-level tag: output has been verified by at least one verifier. *)
type verified

(** {1 Verification result} *)

type verification_result =
  | Verified of
      { verifier : string
      ; confidence : float
      ; evidence : string
      }
  | Disputed of
      { verifier : string
      ; reason : string
      }
  | Abstained of
      { verifier : string
      ; reason : string
      }

(** {1 Phantom-typed output} *)

(** An agent output tagged with its verification status.
    The type parameter ['status] is either {!unverified} or {!verified}.
    It exists only at the type level — no runtime overhead. *)
type 'status output

(** {1 Construction} *)

(** Create an unverified output from an API response. *)
val of_response : producer:string -> Types.api_response -> unverified output

(** {1 Verification} *)

(** Attempt to verify an output.  Returns [Some (verified output)]
    if at least one verification result is [Verified] with
    confidence >= [min_confidence] (default 0.5).
    Returns [None] if verification fails. *)
val verify
  :  unverified output
  -> verifier:string
  -> confidence:float
  -> evidence:string
  -> verified output option

(** Mark as verified with explicit verification results.
    Succeeds if any result is [Verified] above threshold. *)
val verify_with_results
  :  unverified output
  -> verification_result list
  -> ?min_confidence:float
  -> unit
  -> verified output option

(** Force-verify an output (bypass verification).
    Use only for testing or trusted sources.  The [reason] is
    recorded in the verification trail. *)
val trust : unverified output -> reason:string -> verified output

(** {1 Accessors (verified only)} *)

(** Extract the API response.  Only callable on verified outputs.
    {b This is the key safety guarantee}: unverified outputs
    cannot reach this function. *)
val content : verified output -> Types.api_response

(** Extract text content from a verified output. *)
val text : verified output -> string

(** {1 Accessors (any status)} *)

(** The agent that produced this output. *)
val producer : _ output -> string

(** Verification results attached to this output. *)
val verifications : _ output -> verification_result list

(** Whether the output has been verified (runtime check, for logging). *)
val is_verified : _ output -> bool

(** {1 Downgrade} *)

(** Access the raw response regardless of status.
    Intentionally returns [Yojson.Safe.t] instead of [Types.api_response]
    to discourage using unverified outputs directly. *)
val raw_json : _ output -> Yojson.Safe.t
