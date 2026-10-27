(** Opaque identifiers of the authorization domain.

    Each kind of identifier is its own abstract type, so a user id cannot be
    passed where a runtime id is expected. [of_string] is the only way to
    build one. It accepts a non-empty string of at most {!max_length} bytes
    made of ASCII letters, digits, and the characters [.], [_], [:], [-],
    except the path segments [.] and [..]. The alphabet and the length keep an
    id safe to put in a log line, a JSON key, or one path component. Knowing an
    id grants nothing. *)

(** The longest file name component the file systems the project runs on
    accept (NAME_MAX, 255 bytes). *)
val max_length : int

type error =
  | Empty
  | Too_long
  | Invalid_byte of { index : int }
      (** [index] is the offset of the first byte outside the alphabet. *)
  | Path_segment  (** The id is [.] or [..]. *)

module type S = sig
  type t

  val of_string : string -> (t, error) result
  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int

  module Set : Set.S with type elt = t
end

(** Every application makes a new abstract type: [module A = Make ()] and
    [module B = Make ()] cannot be mixed up. *)
module Make () : S
