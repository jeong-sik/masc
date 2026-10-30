(* See [authz_scope.mli] for the contract. *)

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
  val only : Set.t -> t
  val inter : t -> t -> t
  val mem : elt -> t -> bool
  val uncovered : t -> Set.t -> Set.t
  val equal : t -> t -> bool
end

module Make (E : ELEMENT) = struct
  type elt = E.t

  module Set = E.Set

  type t =
    | Empty
    | All
    | Only of Set.t

  let empty = Empty
  let all = All
  let only set = if Set.is_empty set then Empty else Only set

  let inter a b =
    match a, b with
    | Empty, (Empty | All | Only _) | (All | Only _), Empty -> Empty
    | All, scope | scope, All -> scope
    | Only left, Only right -> only (Set.inter left right)
  ;;

  let mem element = function
    | Empty -> false
    | All -> true
    | Only set -> Set.mem element set
  ;;

  let uncovered scope set =
    match scope with
    | Empty -> set
    | All -> Set.empty
    | Only allowed -> Set.diff set allowed
  ;;

  let equal a b =
    match a, b with
    | Empty, Empty | All, All -> true
    | Only left, Only right -> Set.equal left right
    | Empty, (All | Only _) | All, (Empty | Only _) | Only _, (Empty | All) -> false
  ;;
end
