type t =
  | Answering
  | Failing of { failures : int; retry_at : float }
  | Recovered

type ask = Revalidate | Operator_key | Owed_pass

let answering = Answering

let probe_failed ~retry_s ~max_retry_s ~now t =
  let failures =
    1 + (match t with Failing { failures; _ } -> failures | Answering | Recovered -> 0)
  in
  let wait = Float.min max_retry_s (retry_s *. Float.pow 2.0 (float_of_int (failures - 1))) in
  Failing { failures; retry_at = now +. wait }

let pass_answered (_ : t) = Answering

let probe_answered = function
  | Failing _ | Recovered -> Recovered
  | Answering -> Answering

let due ~now = function
  | Failing { retry_at; _ } -> now >= retry_at
  | Recovered -> true
  | Answering -> false

let starts ~now ask t =
  match ask, t with
  | Operator_key, (Answering | Failing _ | Recovered) -> true
  | Revalidate, (Answering | Recovered) -> true
  | Revalidate, Failing _ -> false
  | Owed_pass, (Answering | Failing _ | Recovered) -> due ~now t
