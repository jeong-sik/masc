(** Caller-owned observation of redacted provider wire chunks.

    OAS owns the provider boundary and secret redaction. It does not own an
    observation queue, filesystem path, retention rule, worker, retry policy,
    or capacity decision. A caller that needs persistence supplies a
    nonblocking [try_observe] function and owns every downstream effect.

    @stability Evolving
    @since 0.212.0 *)

(** One exact provider chunk after {!Secret_redactor.redact_string}. OAS never
    invents a capture identity when the caller did not provide one. *)
type observation =
  { capture_id : string option
  ; provider : string
  ; model : string
  ; redacted_chunk : string
  }
[@@deriving yojson, show]

(** Caller-owned reason for declining an observation. The reason is diagnostic
    data only; OAS does not interpret or classify it. *)
type rejection = { reason : string } [@@deriving yojson, show]

(** A synchronous nonblocking offer into caller-owned observation state.

    Implementations must not perform blocking I/O or wait for downstream
    capacity. They should return [Error rejection] when they cannot accept the
    observation. OAS cannot make an arbitrary OCaml callback nonblocking; the
    function type makes the ownership boundary explicit and the returned result
    makes rejection observable. *)
type try_observe = observation -> (unit, rejection) result

(** OAS-owned sink presented to a transport. The transport supplies an exact
    provider/model identity and one raw chunk; the sink owns all redaction and
    caller interaction. It returns [unit] so a diagnostic observation failure
    cannot be reinterpreted as a provider failure by the transport. *)
type observe_chunk = provider:string -> model:string -> chunk:string -> unit

type failure_cause =
  | Observer_rejected of rejection
  | Observer_raised of
      { message : string
      ; backtrace : string
      }
[@@deriving yojson, show]

(** Typed evidence that the caller-owned observer did not accept an
    observation. Raw and redacted provider content are deliberately absent. *)
type failure =
  { capture_id : string option
  ; provider : string
  ; model : string
  ; cause : failure_cause
  }
[@@deriving yojson, show]

(** Redact [chunk], construct one typed observation, and offer it exactly once.

    Caller rejection and ordinary callback exceptions become [Error failure].
    Cancellation and fatal runtime exceptions retain their original propagation
    semantics. OAS performs no fallback, buffering, retry, or persistence.

    [redacted_chunk] is best-effort diagnostic sanitization, not proof that the
    value is non-sensitive. Callers must still apply sensitive-data retention
    and access controls to observations. *)
val observe
  :  try_observe
  -> capture_id:string option
  -> provider:string
  -> model:string
  -> chunk:string
  -> (unit, failure) result
