(** Exact API/model identifiers preserve producer bytes and compare ASCII
    case without prefix or separator inference. *)

module type LABELS = sig
  val empty : string
  val padded : string
  val label : string
end

(* The bytes [equal] compares.  The .mli makes [t] private, so outside
   this file a key is made only by [equality_key]. *)
module Equality_key = struct
  type t = string

  let compare = String.compare
  let equal = String.equal
end

(* One rule, two distinct identifier types.  The abstract [t] each caller sees comes
   from the .mli, not from here. *)
module Make (L : LABELS) = struct
  type t = string

  let of_string raw =
    let trimmed = String.trim raw in
    if String.equal trimmed "" then Error L.empty
    else if not (String.equal raw trimmed) then Error L.padded
    else Ok raw
  ;;

  let of_string_exn raw =
    match of_string raw with
    | Ok value -> value
    | Error message -> invalid_arg (L.label ^ ": " ^ message)
  ;;

  (* The bytes [equal] compares, so a table keyed by it finds exactly the
     values [equal] would. *)
  let equality_key t : Equality_key.t = String.lowercase_ascii t

  let equal a b = Equality_key.equal (equality_key a) (equality_key b)

  let to_string t = t
end

module Api_name =
  Make (struct
      let empty = "api_name must not be empty"

      let padded = "api_name must not have leading or trailing whitespace"

      let label = "Model_identifiers.Api_name"
    end)

module Model_id =
  Make (struct
      let empty = "model_id must not be empty"
      let padded = "model_id must not have leading or trailing whitespace"
      let label = "Model_identifiers.Model_id"
    end)
