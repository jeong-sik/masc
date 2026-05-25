let canonical_prefixes = [ "tier-group."; "tier."; "route." ]

let is_canonical_prefix s =
  List.exists (fun prefix -> String.starts_with ~prefix s) canonical_prefixes

type t = string

let of_string raw : (t, [ `Invalid_prefix | `Empty ]) result =
  let trimmed = String.trim raw in
  if String.equal trimmed "" then Error `Empty
  else if is_canonical_prefix trimmed then Ok trimmed
  else Error `Invalid_prefix

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
