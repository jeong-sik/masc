type read =
  | Server_health
  | Refresh_pass
  | Asks
  | Confirmations

type failure = { read : read; since : float; count : int }

(* At most one failure per read, in the order the notice draws them. *)
type t = failure list

let empty = []

(* The reads of the whole server come first: a question or confirm-queue read
   that fails may be failing because the server does. *)
let whole_server = function
  | Server_health | Refresh_pass -> true
  | Asks | Confirmations -> false

let position = function
  | Server_health -> 0
  | Refresh_pass -> 1
  | Asks -> 2
  | Confirmations -> 3

let earlier left right =
  match Bool.compare (whole_server right.read) (whole_server left.read) with
  | 0 ->
      (match Float.compare left.since right.since with
       | 0 -> Int.compare (position left.read) (position right.read)
       | order -> order)
  | order -> order

let failed failures read ~at =
  if List.exists (fun failure -> failure.read = read) failures then
    List.map
      (fun failure ->
        if failure.read = read then { failure with count = failure.count + 1 }
        else failure)
      failures
  else List.stable_sort earlier ({ read; since = at; count = 1 } :: failures)

let succeeded failures read =
  List.filter (fun failure -> failure.read <> read) failures

let failures failures = failures

let read_name ~ko = function
  | Server_health -> if ko then "서버 상태" else "server health"
  | Refresh_pass -> if ko then "새로 읽기" else "refresh"
  | Asks -> if ko then "질문" else "questions"
  | Confirmations -> if ko then "승인 대기" else "confirmations"

let notice_text ~ko ~now ~next_try failure =
  let failed = read_name ~ko failure.read ^ if ko then " 읽기 실패" else " read failed" in
  let at =
    Masc_tui_value.Instant.detail_text Masc_tui_value.Instant.To_minute ~now failure.since in
  let started = if ko then at ^ " 부터" else "since " ^ at in
  let separator = " \xc2\xb7 " in
  let run =
    if failure.count = 1 then failed ^ separator ^ started
    else
      let count = Masc_tui_value.Count.grouped failure.count in
      failed ^ separator
      ^ (if ko then count ^ "회 연속" else count ^ " in a row")
      ^ separator ^ started
  in
  match next_try with
  | Some moment when whole_server failure.read ->
      let at = Masc_tui_value.Instant.detail_text Masc_tui_value.Instant.To_second ~now moment in
      run ^ separator ^ (if ko then "다음 시도 " ^ at else "next try " ^ at)
  | Some _ | None -> run
