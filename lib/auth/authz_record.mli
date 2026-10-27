(* HIGH-RISK-UNREVIEWED: this is the line format of the authorization log, and
   its writer-side check says which author may write which record. A record
   that gets past it is a grant, revocation, or principal that the whole
   system will treat as true. *)

(** One record of [authz.jsonl] (design 6.3 and 8.1).

    A record is one JSON line that carries the hash of the line before it, so
    the log is a chain: changing, dropping, or reordering a line breaks every
    hash after it. A record can only be made through {!make} or {!of_line}, and
    both refuse a kind that its author may not write (design 6.3). A value of
    type {!t} is therefore a record with a valid hash and an admitted author.

    The body is the business of the layer that owns the kind. This module does
    not read it. *)

open Authz_records

(** SHA-256 of a record, as 64 lowercase hex characters. *)
module Hash : sig
  type t

  (** The [previous_hash] of the first record. *)
  val genesis : t

  val of_hex : string -> t option
  val to_hex : t -> string
  val equal : t -> t -> bool
end

(** What a record is about. Each kind says which authors may write it, see
    {!admits}. A layer that needs a new kind adds a constructor here, and the
    compiler stops at {!admits} until it has decided who may write it. *)
module Kind : sig
  type t =
    | Runtime_grant
    | Delegate_policy
    | Principal
    | Internal_service_credential
    | Permission_revocation
    | Trigger_evidence
    | Lease_terminal_evidence
    | Preauthorized_expiry
    | Migration_diagnostic
    | Local_recovery

  val all : t list
  val to_string : t -> string
  val of_string : string -> t option
end

(** Whether [author] may write a record of this kind (design 6.3). The first
    five kinds need an authenticated principal. Each system author writes only
    its own evidence, and the local operator writes only recovery records. *)
val admits : Kind.t -> Author.t -> bool

(** Where the next record goes: its position and the hash it must carry. *)
type head

val genesis : head
val next_seq : head -> int
val head_hash : head -> Hash.t

type t = private
  { seq : int  (** From 1. *)
  ; previous_hash : Hash.t
  ; at_ms : int  (** Wall clock in milliseconds. For audit, never for ordering. *)
  ; author : Author.t
  ; kind : Kind.t
  ; body : Yojson.Safe.t
  ; hash : Hash.t
  }

(** The head after [t] is appended. *)
val head_after : t -> head

type make_error = Author_not_admitted of { kind : Kind.t; author : Author.t }

val make
  :  head:head
  -> at_ms:int
  -> author:Author.t
  -> kind:Kind.t
  -> body:Yojson.Safe.t
  -> (t, make_error) result

type decode_error =
  | Not_json
  | Unexpected_shape  (** Not exactly the fields of a record, in order. *)
  | Unknown_kind of string
  | Invalid_author
  | Invalid_hash
  | Seq_mismatch of { expected : int; actual : int }
  | Previous_hash_mismatch
  | Author_not_admitted_to_write of { kind : Kind.t; author : Author.t }
  | Hash_mismatch
  | Non_canonical  (** Parses to a valid record but is not the line {!to_line} writes. *)

val decode_error_to_string : decode_error -> string

(** The record as one line, without the trailing newline. *)
val to_line : t -> string

(** Reads a line that is expected at [head]. The line must be the exact bytes
    {!to_line} would write for the record it names. *)
val of_line : head:head -> string -> (t, decode_error) result
