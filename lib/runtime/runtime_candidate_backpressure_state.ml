type rate_limit =
  | Unknown_scope_rate_limit of { noted_at : float; retry_after : float option }

type attempt_failure =
  | Server_error
  | Provider_capacity
  | Network_transient
  | Provider_timeout

let attempt_failure_to_wire_name = function
  | Server_error -> "server_error"
  | Provider_capacity -> "provider_capacity"
  | Network_transient -> "network_transient"
  | Provider_timeout -> "provider_timeout"

let attempt_failure_of_wire_name = function
  | "server_error" -> Some Server_error
  | "provider_capacity" -> Some Provider_capacity
  | "network_transient" -> Some Network_transient
  | "provider_timeout" -> Some Provider_timeout
  | _ -> None

type recorder = Keeper_recorder of { keeper_name : string }

let recorder_keeper_name (Keeper_recorder { keeper_name }) = keeper_name

let keeper_recorder ~keeper_name = Keeper_recorder { keeper_name }

let same_recorder (Keeper_recorder left) (Keeper_recorder right) =
  String.equal left.keeper_name right.keeper_name

type failed_attempt =
  | Failed_attempt of { noted_at : float; failure : attempt_failure; recorded_by : recorder }

type candidate_backpressure =
  { rate_limit : rate_limit option
  ; failed_attempt : failed_attempt option
  }

let empty = { rate_limit = None; failed_attempt = None }

let is_empty = function
  | { rate_limit = None; failed_attempt = None } -> true
  | { rate_limit = Some _; failed_attempt = _ } | { rate_limit = None; failed_attempt = Some _ } -> false

let note_rate_limit ~noted_at ~retry_after current =
  let retry_after = Keeper_runtime_failure_route.usable_retry_after retry_after in
  match current.rate_limit with
  | Some (Unknown_scope_rate_limit existing) when existing.noted_at > noted_at -> current
  | Some (Unknown_scope_rate_limit _) | None ->
      { current with rate_limit = Some (Unknown_scope_rate_limit { noted_at; retry_after }) }

let note_failed_attempt ~noted_at ~failure ~recorded_by current =
  match current.failed_attempt with
  | Some (Failed_attempt existing) when existing.noted_at > noted_at -> current
  | Some (Failed_attempt _) | None ->
      { current with failed_attempt = Some (Failed_attempt { noted_at; failure; recorded_by }) }

let observe ~now current =
  match current.rate_limit with
  | None -> current
  | Some (Unknown_scope_rate_limit { noted_at; retry_after }) ->
      (match retry_after with
       | Some seconds when now -. noted_at >= seconds -> { current with rate_limit = None }
       | Some _ | None -> current)
