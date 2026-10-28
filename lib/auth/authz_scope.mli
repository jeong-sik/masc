(** Allow-list scopes over one kind of element (design 4.4).

    [Empty] allows nothing. [All] puts no limit of its own, so it only passes
    on whatever the other filters in an intersection allow. [Only set]
    allows exactly [set]. The constructors are private: [only] turns an empty
    set into [Empty], so a scope that allows nothing has one form. *)

module type ELEMENT = sig
  type t

  module Set : Set.S with type elt = t
end

module type S = sig
  type elt

  module Set : Set.S with type elt = elt

  type t = private
    | Empty
    | All
    | Only of Set.t

  val empty : t
  val all : t

  (** [only set] is [Empty] when [set] is empty. *)
  val only : Set.t -> t

  (** Elements both scopes allow. *)
  val inter : t -> t -> t

  val mem : elt -> t -> bool

  (** The members of [set] that the scope does not allow. *)
  val uncovered : t -> Set.t -> Set.t

  val equal : t -> t -> bool
end

module Make (E : ELEMENT) : S with type elt = E.t and module Set = E.Set
