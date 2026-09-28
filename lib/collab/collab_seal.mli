(** AES-256-GCM sealing for collab frames (RFC-0471 §2.3).

    Sealed layout: [[12B IV][ciphertext+tag]]. The room key travels in the
    link fragment only ({!Collab_link}); the relay sees opaque bytes. Every
    {!seal} call mints a fresh random IV, so sealing the same plaintext twice
    yields different bytes. *)

val iv_bytes : int
(** [12]. GCM nonce size in bytes. *)

val key_bytes : int
(** [32]. AES-256 key size in bytes. *)

type key
(** An AES-256 sealing key. Build with {!key_of_secret}. *)

type key_error = Invalid_key_length of int

val key_of_secret : string -> (key, key_error) result
(** [key_of_secret secret] builds a key from a 32-byte room key. Any other
    length is [Invalid_key_length]. *)

val seal : key -> string -> string
(** [seal key plaintext] returns [iv ^ ciphertext ^ tag] with a fresh random
    IV. *)

type open_error =
  | Sealed_too_short
  | Authentication_failed

val open_sealed : key -> string -> (string, open_error) result
(** [open_sealed key sealed] verifies and decrypts. Input at most [iv_bytes]
    long is [Sealed_too_short]; a tag mismatch (tampering or wrong key) is
    [Authentication_failed]. *)
