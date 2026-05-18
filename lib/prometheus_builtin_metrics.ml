(** Built-in Prometheus metric registration. *)

type metric_kind = [ `Counter | `Gauge | `Histogram ]

type register_histogram =
  name:string -> help:string -> ?labels:(string * string) list -> unit -> unit

type inc_counter =
  string -> ?labels:(string * string) list -> ?delta:float -> unit -> unit

let register
      ~(add : string -> string -> metric_kind -> unit)
      ~(register_histogram : register_histogram)
      ~(inc_counter : inc_counter)
      ()
  =
  Prometheus_builtin_metrics_part1.register ~add ~register_histogram ~inc_counter ();
  Prometheus_builtin_metrics_part2.register ~add ~register_histogram ~inc_counter ();
  Prometheus_builtin_metrics_part3.register ~add ~register_histogram ~inc_counter ();
  Prometheus_builtin_metrics_part4.register ~add ~register_histogram ~inc_counter ();
  Prometheus_builtin_metrics_part5.register ~add ~register_histogram ~inc_counter ();
;;
