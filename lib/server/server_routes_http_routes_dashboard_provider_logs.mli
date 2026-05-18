val dashboard_provider_logs_json : unit -> Yojson.Safe.t

val dashboard_provider_log_tail_json :
  Httpun.Request.t -> Httpun.Status.t * Yojson.Safe.t
