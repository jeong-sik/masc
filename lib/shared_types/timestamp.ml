type t = float

let now () = Unix.gettimeofday ()

let of_float f = f

let to_float t = t

let compare = Float.compare

let equal = Float.equal

let to_json t = `Float t

let of_json = function
  | `Float f -> Ok f
  | `Int i -> Ok (float_of_int i)
  | _ -> Error "Timestamp.of_json: expected float or int"
