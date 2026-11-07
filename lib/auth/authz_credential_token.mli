(* HIGH-RISK-UNREVIEWED: this module writes and reads the text of a PAT and of a
   Service credential. A caller that holds the text of a live one acts as its
   principal. *)

(** The text of a scoped PAT and of a Service credential (design 5.3, plan
    C4-1a).

    {b Text.} A token is a prefix, the id of the credential, a [.], and a secret
    of 64 lowercase hex characters: [mpat_<pat id>.<secret>] for a PAT and
    [msvc_<credential id>.<secret>] for a Service credential. The secret is the
    last 64 characters, so an id with a [.] in it reads back. The prefixes are
    on disk in every client that keeps a token, and changing one makes every
    token issued before it unreadable.

    {b Secret.} {!S.draw} takes 32 bytes from the OS CSPRNG. The log never
    holds a secret, only {!S.secret_digest} of it. The secret cannot be guessed
    from the digest, so the digest needs no key.

    {b Other bearers.} A legacy bearer of masc is lowercase hex, and an OAuth
    token starts with [mat_] or [mrt_]. Neither starts with a prefix of this
    module, so {!read} calls both {!No_prefix}. Telling them apart is for the
    reader of the request (plan C4-7).

    This module knows nothing of records or state. The issuing code checks a
    token against the digest its record holds. *)

(** SHA-256 of a secret, as 64 lowercase hex characters, which the record of a
    credential holds. *)
module type DIGEST = sig
  type t

  val of_hex : string -> t option
  val to_hex : t -> string

  (** Compares in a time that does not depend on where the digests differ. *)
  val equal : t -> t -> bool
end

module type S = sig
  type id

  (** The digests of this kind of credential. A digest of the other kind has
      another type, so a PAT secret cannot be checked against the record of a
      Service credential. *)
  module Digest : DIGEST

  type t

  (** [mpat_] or [msvc_]. *)
  val prefix : string

  (** The bytes hashed into a digest start with this label, followed by the
      secret, so a digest is not the SHA-256 of any other protocol's text:
      ["masc-authz-pat-secret-v1\n"] for a PAT and
      ["masc-authz-service-credential-secret-v1\n"] for a Service credential. *)
  val digest_label : string

  val id : t -> id

  (** The digest of the secret the token carries. *)
  val secret_digest : t -> Digest.t

  (** A token for [id] with a new secret. *)
  val draw : id -> t

  (** The text of the token. It holds the secret: it goes to the caller once,
      when the credential is issued, and never to a log. *)
  val to_string : t -> string
end

module Pat : S with type id = Authz_types.Pat_id.t
module Service_credential : S with type id = Authz_types.Service_credential_id.t

type reading =
  | Pat_token of Pat.t
  | Service_credential_token of Service_credential.t
  | Pat_malformed
      (** The text starts with [mpat_], and the rest is not an id, a [.], and
          64 lowercase hex characters. *)
  | Service_credential_malformed  (** The same, for [msvc_]. *)
  | No_prefix  (** The text starts with neither prefix. *)

(** Reads the text of a bearer. *)
val read : string -> reading
