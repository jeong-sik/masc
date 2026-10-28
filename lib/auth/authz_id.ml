(* See [authz_id.mli] for the contract. *)

type error =
  | Empty
  | Too_long
  | Invalid_byte of { index : int }
  | Path_segment

module type S = sig
  type t

  val of_string : string -> (t, error) result
  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int

  module Set : Set.S with type elt = t
end

let max_length = 255

let in_alphabet = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | ':' | '-' -> true
  | _ -> false
;;

let first_invalid_byte s =
  let rec scan index =
    if index >= String.length s
    then None
    else if in_alphabet s.[index]
    then scan (index + 1)
    else Some index
  in
  scan 0
;;

(* The alphabet has no '/', so [.] and [..] are the only ids that can step out
   of a directory. Whoever adds '/' to the alphabet has to rule out more. *)
let is_path_segment s = String.equal s "." || String.equal s ".."

module Make () = struct
  type t = string

  let of_string s =
    if String.equal s ""
    then Error Empty
    else if String.length s > max_length
    then Error Too_long
    else (
      match first_invalid_byte s with
      | Some index -> Error (Invalid_byte { index })
      | None -> if is_path_segment s then Error Path_segment else Ok s)
  ;;

  let to_string s = s
  let equal = String.equal
  let compare = String.compare

  module Set = Set.Make (String)
end
