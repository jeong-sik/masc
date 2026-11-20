type t =
  | Answering
  | Failing of { failures : int; retry_at : Masc_tui_wake.Mono.t; retry_wall_at : float }
  | Recovered of { failures : int }

type ask = Revalidate | Operator_key | Owed_pass

type screen_ask = Owed_read_due | Operator_change

type stream_open = Opened_each_time | Opened_after_failure

let answering = Answering

let probe_failed ~retry_s ~max_retry_s ~now ~wall_now t =
  let failures =
    1
    + (match t with
       | Failing { failures; _ } | Recovered { failures } -> failures
       | Answering -> 0)
  in
  let wait = Float.min max_retry_s (retry_s *. Float.pow 2.0 (float_of_int (failures - 1))) in
  Failing
    { failures; retry_at = Masc_tui_wake.Mono.after now wait; retry_wall_at = wall_now +. wait }

let pass_answered (_ : t) = Answering

let answered_again = function
  | Failing _ | Recovered _ -> Recovered { failures = 0 }
  | Answering -> Answering

let stream_opened opened t =
  match opened, t with
  | Opened_after_failure, Failing { failures; _ } -> Recovered { failures }
  | Opened_after_failure, (Answering | Recovered _) -> t
  | Opened_each_time, (Answering | Failing _ | Recovered _) -> t

let next_try = function
  | Failing { retry_wall_at; _ } -> Some retry_wall_at
  | Answering | Recovered _ -> None

let due ~now = function
  | Failing { retry_at; _ } ->
      Masc_tui_wake.reached_mono Masc_tui_wake.Refresh_retry ~now ~at:retry_at
  | Recovered _ -> true
  | Answering -> false

let starts ~now ask t =
  match ask, t with
  | Operator_key, (Answering | Failing _ | Recovered _) -> true
  | Revalidate, (Answering | Recovered _) -> true
  | Revalidate, Failing _ -> false
  | Owed_pass, (Answering | Failing _ | Recovered _) -> due ~now t

let screen_read_starts ~now ask t =
  starts ~now
    (match ask with
     | Owed_read_due -> Revalidate
     | Operator_change -> Operator_key)
    t
