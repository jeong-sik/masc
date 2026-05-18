type metric_kind = [ `Counter | `Gauge | `Histogram ]

val register : add:(string -> string -> metric_kind -> unit) -> unit -> unit
