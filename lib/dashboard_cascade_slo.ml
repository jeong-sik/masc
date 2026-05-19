(** SLO projection (LT-11).

   Targets mirror infrastructure/monitoring/cascade-slo.yml.  Computed
   in-process from the live Cascade_strategy_trace ring so the MASC
   dashboard can render SLO status without reaching Prometheus. *)

open Dashboard_cascade_helpers

let slo_sample_limit = 1000
let slo_target_ordered_ratio = 0.99
let slo_target_exhaustion_count = 10
let slo_target_burn_rate = 1.0

let compute_slo_counts (events : Cascade_strategy_trace.event list) =
  List.fold_left
    (fun (total, ordered, exhausted) (ev : Cascade_strategy_trace.event) ->
       match ev.kind with
       | Ordered -> total + 1, ordered + 1, exhausted
       | Filtered_empty -> total + 1, ordered, exhausted
       | Exhausted -> total + 1, ordered, exhausted + 1)
    (0, 0, 0)
    events
;;

let slo_json () =
  let events = Cascade_strategy_trace.snapshot ~limit:slo_sample_limit () in
  let total, ordered, exhausted = compute_slo_counts events in
  let ordered_ratio =
    if total = 0 then 1.0 else Stdlib.Float.of_int ordered /. Stdlib.Float.of_int total
  in
  let burn_rate = (1.0 -. ordered_ratio) /. 0.01 in
  let ratio_violated = Stdlib.Float.compare ordered_ratio slo_target_ordered_ratio < 0 in
  let exhaustion_violated = exhausted > slo_target_exhaustion_count in
  let burn_violated = Stdlib.Float.compare burn_rate slo_target_burn_rate > 0 in
  let violations =
    List.filter_map
      (fun (name, violated) -> if violated then Some (`String name) else None)
      [ "ordered_ratio", ratio_violated
      ; "exhaustion_count", exhaustion_violated
      ; "burn_rate", burn_violated
      ]
  in
  let status =
    if ratio_violated || exhaustion_violated
    then "violated"
    else if burn_violated
    then "warn"
    else "ok"
  in
  `Assoc
    [ "updated_at", `String (now_iso ())
    ; "window_sample_size", `Int slo_sample_limit
    ; ( "targets"
      , `Assoc
          [ "ordered_ratio_min", `Float slo_target_ordered_ratio
          ; "exhaustion_count_max", `Int slo_target_exhaustion_count
          ; "burn_rate_max", `Float slo_target_burn_rate
          ] )
    ; ( "current"
      , `Assoc
          [ "ordered_ratio", `Float ordered_ratio
          ; "exhaustion_count", `Int exhausted
          ; "burn_rate", `Float burn_rate
          ; "total_events", `Int total
          ] )
    ; "status", `String status
    ; "violations", `List violations
    ]
;;
