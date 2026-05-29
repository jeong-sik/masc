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
  [< `Null | `Bool of 'a | `Int of int | `Intlit of 'b | `Float of Float.t | `String of 'c | `Assoc of 'd | `List of 'e ] ->
  (int, string) result
val _rp_deser_float :
  [< `Null | `Bool of 'a | `Int of int | `Intlit of 'b | `Float of float | `String of 'c | `Assoc of 'd | `List of 'e ] ->
  (float, string) result
val _rp_deser_bool :
  [< `Null | `Bool of 'a | `Int of 'b | `Intlit of 'c | `Float of 'd | `String of 'e | `Assoc of 'f | `List of 'g ] ->
  ('a, string) result
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
