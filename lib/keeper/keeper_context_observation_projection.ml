(** Current Keeper context-observation projection.

    Context occupancy has no owner-boundary measurement in the current
    runtime contract. This module is the single wire projection for that
    absence and for the separate, provider-reported last-turn usage. *)

let missing_measurement_json () =
  `Assoc
    [ "kind", `String "not_observed"
    ; "reason", `String "context_measurement_missing"
    ]
;;

let missing_context_fields () =
  let unavailable = missing_measurement_json () in
  let context =
    `Assoc
      [ "source", `Null
      ; "context_ratio", `Null
      ; "context_tokens", `Null
      ; "context_max", `Null
      ; "metrics_unavailable", unavailable
      ]
  in
  [ "context_ratio", `Null
  ; "context_tokens", `Null
  ; "context_max", `Null
  ; "context_source", `Null
  ; "context_metrics_unavailable", unavailable
  ; "context", context
  ]
;;

let last_turn_usage_json_of_meta
      (meta : Keeper_meta_contract.keeper_meta)
  =
  let usage = meta.runtime.usage in
  match usage.last_usage_reported_at with
  | None -> `Null
  | Some observed_at ->
    `Assoc
      [ "input_tokens", `Int usage.last_input_tokens
      ; "output_tokens", `Int usage.last_output_tokens
      ; "total_tokens", `Int usage.last_total_tokens
      ; ( "observed_at"
        , `String (Masc_domain.iso8601_of_unix_seconds observed_at) )
      ; "source", `String "keeper_runtime_usage"
      ]
;;
