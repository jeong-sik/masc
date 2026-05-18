(** Built-in Prometheus metric registration. *)

let register ~add () =
  Prometheus_builtin_metrics_part1.register ~add ();
  Prometheus_builtin_metrics_part2.register ~add ();
  Prometheus_builtin_metrics_part3.register ~add ();
  Prometheus_builtin_metrics_part4.register ~add ();
  Prometheus_builtin_metrics_part5.register ~add ();
;;
