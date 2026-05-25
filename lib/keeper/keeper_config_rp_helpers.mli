val clamp_int : 'a -> min_v:'a -> max_v:'a -> 'a
val int_of_env_default :
  string -> default:int -> min_v:int -> max_v:int -> int
val float_of_env_default :
  string -> default:float -> min_v:float -> max_v:float -> float
val _rp_validate_int :
  min:int -> max:int -> string -> int -> (unit, string) result
val _rp_validate_float :
  min:float -> max:float -> string -> float -> (unit, string) result
val _rp_deser_int :
  [> `Float of Float.t | `Int of int ] -> (int, string) result
val _rp_deser_float :
  [> `Float of float | `Int of int ] -> (float, string) result
val _rp_deser_bool : [> `Bool of 'a ] -> ('a, string) result
val _rp_int :
  key:string ->
  default:(unit -> int) ->
  min_v:int ->
  max_v:int ->
  description:string -> unit -> int Runtime_params.param
val _rp_float :
  key:string ->
  default:(unit -> float) ->
  min_v:float ->
  max_v:float ->
  description:string -> unit -> float Runtime_params.param
val _rp_bool :
  key:string ->
  default:(unit -> bool) ->
  description:string -> unit -> bool Runtime_params.param
