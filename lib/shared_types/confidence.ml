type t = float

let clamp x =
  if Float.is_nan x then 0.0
  else if x < 0.0 then 0.0
  else if x > 1.0 then 1.0
  else x

let make raw = clamp raw

let to_float t = t

let zero = 0.0

let one = 1.0

let combine a b = sqrt (a *. b)

let compare = Float.compare

let equal = Float.equal

let to_json t = `Float t

let of_json = function
  | `Float f -> Ok (make f)
  | `Int i -> Ok (make (float_of_int i))
  | _ -> Error "Confidence.of_json: expected float or int"
