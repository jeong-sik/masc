(* Tier/tier-group prefix validation removed.  Cascade names are now
   simple provider:model strings (e.g. "runpod:glm-coding-with-spark").
   This module is preserved temporarily as a string alias so downstream
   types do not need to change in a single sweep, but all validation
   has been deleted per tier/tier-group purge. *)

type t = string

let of_string raw : (t, [ `Invalid_prefix | `Empty ]) result =
  let trimmed = String.trim raw in
  if String.equal trimmed "" then Error `Empty
  else Ok trimmed

let of_string_exn raw =
  match of_string raw with
  | Ok t -> t
  | Error `Empty -> failwith "Cascade_name.of_string_exn: empty string"
  | Error `Invalid_prefix ->
      failwith
        (Printf.sprintf "Cascade_name.of_string_exn: invalid prefix: %S" raw)

let of_string_or ~fallback raw =
  match of_string raw with
  | Ok t -> t
  | Error _ -> fallback

let to_string (v : t) = v
let pp fmt (v : t) = Format.pp_print_string fmt (v :> string)
