(* HIGH-RISK-UNREVIEWED: this is the identity key of a person (design 5.2.1).
   Two values that this module calls different are two people, and one value
   is bound to one principal at most. *)

(** Who a person is at the provider they sign in with (design 5.2 and 5.2.1).

    The design writes the key as [(iss, sub)]; this type is that key. A branch
    names its provider, so no issuer string is compared to pick one. The Google
    and the GitHub identity of one person are two identities, and linking them
    is refused (design 5.1-5).

    - [Google] carries the [sub] claim of the ID token: at most 255 characters,
      case-sensitive (OpenID Connect Core 1.0, section 5.1). This module accepts
      the visible ASCII characters, [!] to [~].
    - [Github] carries the numeric user [id] of [GET /user]. The [login] can
      change, so it is not a key. The id is positive and at most 2^53 - 1, the
      largest integer that every reader of the log reads exactly
      ({!Authz_body.int}).

    {b Body.} [{"provider":"google","sub":...}] or
    [{"provider":"github","user_id":...}], with the members in this order. The
    labels are on disk. *)

type t = private
  | Google of { sub : string }
  | Github of { user_id : int }

type error =
  | Google_sub_empty
  | Google_sub_too_long  (** More than 255 bytes. *)
  | Google_sub_invalid_byte of { index : int }
      (** [index] is the offset of the first byte outside [!] to [~]. *)
  | Github_user_id_not_positive
  | Github_user_id_too_large  (** Above 2^53 - 1. *)

val error_to_string : error -> string
val google : sub:string -> (t, error) result
val github : user_id:int -> (t, error) result
val equal : t -> t -> bool
val compare : t -> t -> int

(** A label for logs and refusals: [google:<sub>] or [github:<id>]. It is not
    parsed back. *)
val to_string : t -> string

(** The body member of a record that names an identity. The error cannot come
    from a value of {!t}. It is returned because {!Authz_body.t} can only be
    made through functions that check. *)
val to_body : t -> (Authz_body.t, Authz_body.error) result

(** Why a body member is not an identity. *)
type body_error =
  | Not_an_object
  | Unknown_provider of string
  | Wrong_members
      (** Not exactly the members of the provider, in order, with their
          types. *)
  | Invalid of error

val body_error_to_string : body_error -> string

(** Reads the member. The first check that fails is the result: it is an
    object, its first member names a provider, its members are those of that
    provider, and the value is one this module accepts. *)
val of_body : Authz_body.t -> (t, body_error) result

module Map : Map.S with type key = t
