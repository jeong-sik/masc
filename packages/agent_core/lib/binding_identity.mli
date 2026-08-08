(** Opaque identity of one resolved OAS provider binding.

    The identity is constructed from the actual resolved provider config and
    OAS-owned catalog facts.  Embedding runtimes may compare/hash it, but cannot
    reconstruct it from display strings or inspect credential material.

    @since 0.211.7 *)

type transport =
  | Http
  | Injected

type t

(** Resolve the transport identity for one concrete call. An explicitly
    injected transport is [Injected]; otherwise it is [Http]. *)
val transport_for_call : injected:bool -> transport

(** Construct an immutable identity from a resolved config. *)
val of_provider_config
  :  transport:transport
  -> Llm_provider.Provider_config.t
  -> (t, string) result

val equal : t -> t -> bool
val hash : t -> int

(** Whether this binding has a resolved opaque credential identity.  Failure
    attribution uses this fact to fail closed before assigning credential-pool
    ownership. *)
val has_credential_identity : t -> bool

(** Durable redacted observation of a resolved binding.

    This snapshot is derived only from the authoritative {!t}; it never
    re-resolves a {!Llm_provider.Provider_config.t}.  Raw credentials, full
    credential digests, URI userinfo, and URI query values are never retained.

    Snapshot equality means equality of the serialized redacted observation.
    In particular, the short credential fingerprint is diagnostic-only: this
    type must not be used for credential ownership, dispatch, or reconstruction
    of {!t}. *)
module Redacted_snapshot : sig
  type t

  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit

  (** Closed canonical durable codec. Unknown, duplicate, or missing fields and
      non-canonical typed values are rejected. *)
  val to_yojson : t -> Yojson.Safe.t

  val of_yojson : Yojson.Safe.t -> (t, string) result
end

(** Take the single durable redacted observation of an authoritative binding. *)
val redacted_snapshot : t -> Redacted_snapshot.t

(** Redacted display/telemetry projection. This is exactly
    [Redacted_snapshot.to_yojson (redacted_snapshot identity)] and remains a
    convenience API, not a binding equality representation. *)
val to_redacted_yojson : t -> Yojson.Safe.t
