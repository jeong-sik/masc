type rate_limit =
  | Unknown_scope_rate_limit of { noted_at : float; retry_after : float option }

type attempt_failure =
  | Server_error
  | Provider_capacity
  | Network_transient
  | Provider_timeout
[@@deriving enumerate]

type failure_scope =
  | Keeper_scoped
  | Provider_wide

let failure_scope = function
  | Server_error | Provider_capacity -> Provider_wide
  | Network_transient | Provider_timeout -> Keeper_scoped

let attempt_failure_to_wire_name = function
  | Server_error -> "server_error"
  | Provider_capacity -> "provider_capacity"
  | Network_transient -> "network_transient"
  | Provider_timeout -> "provider_timeout"

let attempt_failure_of_wire_name s = List.find_opt (fun v -> String.equal (attempt_failure_to_wire_name v) s) all_of_attempt_failure

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

let clear_keeper_failure ~recorded_by current =
  match current.failed_attempt with
  | None -> current
  | Some (Failed_attempt { failure; recorded_by = owner; _ }) ->
      (match failure_scope failure with
       | Keeper_scoped when same_recorder owner recorded_by ->
           { current with failed_attempt = None }
       | Keeper_scoped | Provider_wide -> current)

let failed_attempt_for_keeper ?keeper_name current =
  match current.failed_attempt with
  | None -> None
  | Some (Failed_attempt { failure; recorded_by; _ }) as mark ->
      (match failure_scope failure with
       | Provider_wide -> mark
       | Keeper_scoped ->
           (match keeper_name with
            | Some name when same_recorder recorded_by (keeper_recorder ~keeper_name:name) ->
                mark
            | Some _ | None -> None))

let for_keeper ?keeper_name current =
  { current with failed_attempt = failed_attempt_for_keeper ?keeper_name current }

module Recorder_map = Map.Make (struct
  type t = recorder

  let compare (Keeper_recorder left) (Keeper_recorder right) =
    String.compare left.keeper_name right.keeper_name
end)

type scoped_state =
  { shared : candidate_backpressure
  ; keeper_failures : failed_attempt Recorder_map.t
  }

let empty_scoped =
  { shared = empty
  ; keeper_failures = Recorder_map.empty
  }

let is_scoped_empty state =
  is_empty state.shared && Recorder_map.is_empty state.keeper_failures

let note_scoped_rate_limit ~noted_at ~retry_after state =
  { state with shared = note_rate_limit ~noted_at ~retry_after state.shared }

let note_scoped_failed_attempt ~noted_at ~failure ~recorded_by state =
  match failure_scope failure with
  | Provider_wide ->
      { state with
        shared = note_failed_attempt ~noted_at ~failure ~recorded_by state.shared
      }
  | Keeper_scoped ->
      let updated =
        Recorder_map.update recorded_by
          (function
            | Some (Failed_attempt existing) as keep when existing.noted_at > noted_at ->
                keep
            | Some (Failed_attempt _) | None ->
                Some (Failed_attempt { noted_at; failure; recorded_by }))
          state.keeper_failures
      in
      { state with keeper_failures = updated }

let clear_scoped_keeper_failure ~recorded_by state =
  { shared = clear_keeper_failure ~recorded_by state.shared
  ; keeper_failures = Recorder_map.remove recorded_by state.keeper_failures
  }

let clear_scoped_provider_failure state =
  { state with shared = empty }

let observe_scoped ~now state =
  { state with shared = observe ~now state.shared }

let scoped_failed_attempt_for_keeper ?keeper_name state =
  let keeper_mark =
    match keeper_name with
    | None -> None
    | Some name ->
        Recorder_map.find_opt (keeper_recorder ~keeper_name:name) state.keeper_failures
  in
  match keeper_mark with
  | Some _ -> keeper_mark
  | None -> failed_attempt_for_keeper ?keeper_name state.shared

let scoped_for_keeper ?keeper_name state =
  { rate_limit = state.shared.rate_limit
  ; failed_attempt = scoped_failed_attempt_for_keeper ?keeper_name state
  }
