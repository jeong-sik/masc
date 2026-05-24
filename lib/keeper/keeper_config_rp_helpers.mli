val int_of_env_default : string -> default:int -> min_v:int -> max_v:int -> int
val float_of_env_default : string -> default:float -> min_v:float -> max_v:float -> float

val _rp_int :
  key:string ->
  default:(unit -> int) ->
  min_v:int ->
  max_v:int ->
  description:string ->
  unit ->
  'a

val _rp_float :
  key:string ->
  default:(unit -> float) ->
  min_v:float ->
  max_v:float ->
  description:string ->
  unit ->
  'a

val _rp_bool :
  key:string ->
  default:(unit -> bool) ->
  description:string ->
  unit ->
  'a
