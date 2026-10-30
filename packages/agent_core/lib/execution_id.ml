module type S = sig
  type t

  val fresh : unit -> (t, string) result
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
  val show : t -> string
end

module Make (Prefix : sig
    val value : string
  end) : S = struct
  type t = string

  let fresh () =
    Result.map (fun value -> Prefix.value ^ value) (Llm_provider.Random_id.create ())
  ;;

  let of_string value =
    if String.equal value ""
    then Error (Prefix.value ^ "identifier must not be empty")
    else if not (String.equal value (String.trim value))
    then Error (Prefix.value ^ "identifier must not have surrounding whitespace")
    else if not (String.starts_with ~prefix:Prefix.value value)
    then Error ("identifier must start with " ^ Prefix.value)
    else if String.length value = String.length Prefix.value
    then Error (Prefix.value ^ "identifier suffix must not be empty")
    else Ok value
  ;;

  let to_string value = value
  let equal = String.equal
  let compare = String.compare
  let pp = Format.pp_print_string
  let show value = value
end

module Correlation : S = struct
  type t = string

  let fresh = Llm_provider.Random_id.create

  let of_string value =
    if String.equal (String.trim value) ""
    then Error "execution correlation identifier must contain non-whitespace text"
    else if not (String.equal value (String.trim value))
    then Error "execution correlation identifier must not have surrounding whitespace"
    else Ok value
  ;;

  let to_string value = value
  let equal = String.equal
  let compare = String.compare
  let pp = Format.pp_print_string
  let show value = value
end
