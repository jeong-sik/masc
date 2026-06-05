let metric_oas_params_of_schema_sec =
  "retired_prometheus_oas_params_of_schema_seconds"
;;

let metric_oas_make_tool_bundle_sec =
  "retired_prometheus_oas_make_tool_bundle_seconds"
;;

let hist_disabled = lazy true

let observe ~metric:_ ~start:_ = ()

let register () = ()
