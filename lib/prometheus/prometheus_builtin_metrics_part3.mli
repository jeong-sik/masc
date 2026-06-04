type metric_kind = [ `Counter | `Gauge | `Histogram ]

type register_histogram =
  name:string -> help:string -> ?labels:(string * string) list -> unit -> unit

type inc_counter =
  string -> ?labels:(string * string) list -> ?delta:float -> unit -> unit

val register
  :  add:(string -> string -> metric_kind -> unit)
  -> register_histogram:register_histogram
  -> inc_counter:inc_counter
  -> unit
  -> unit
