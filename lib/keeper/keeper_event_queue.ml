type urgency =
  | Immediate
  | Normal
  | Low

let urgency_rank = function
  | Immediate -> 0
  | Normal -> 1
  | Low -> 2

type post_id = string

type stimulus = {
  post_id : post_id;
  urgency : urgency;
  arrived_at : float;
  payload : string;
}

type t = stimulus list

let empty : t = []

let length = List.length

let is_empty = function [] -> true | _ -> false

let enqueue (queue : t) (s : stimulus) : t = queue @ [ s ]

let dequeue : t -> (stimulus * t) option = function
  | [] -> None
  | s :: rest -> Some (s, rest)

let dedup_by_post_id ?(window_seconds = 60.0) (queue : t) : t =
  let within_window a b =
    Float.abs (a.arrived_at -. b.arrived_at) <= window_seconds
  in
  let rec aux acc = function
    | [] -> List.rev acc
    | s :: rest ->
        let later =
          List.filter
            (fun s' -> not (s'.post_id = s.post_id && within_window s s'))
            rest
        in
        aux (s :: acc) later
  in
  aux [] queue

let sort_by_urgency (queue : t) : t =
  List.stable_sort
    (fun a b -> Int.compare (urgency_rank a.urgency) (urgency_rank b.urgency))
    queue

type stimulus_class =
  | Board_signal
  | Bootstrap
  | Alive_but_stuck_recovery
  | Stale_watchdog_idle_recovery
  | Unsupported of string

let classify (s : stimulus) : stimulus_class =
  let has_prefix prefix =
    let payload_len = String.length s.payload in
    let prefix_len = String.length prefix in
    payload_len >= prefix_len
    && String.equal (String.sub s.payload 0 prefix_len) prefix
  in
  if String.equal s.payload "Keeper bootstrap signal" then Bootstrap
  else if has_prefix "{\"source\":\"alive_but_stuck_recovery\"" then
    Alive_but_stuck_recovery
  else if has_prefix "{\"source\":\"stale_watchdog_idle_recovery\"" then
    Stale_watchdog_idle_recovery
  (* Board signals carry JSON with "source":"board_signal". Lightweight
     prefix check avoids a full Yojson parse in the data layer. *)
  else if has_prefix "{\"source\":\"board_signal\"" then Board_signal
  else
    Unsupported
      (String.sub s.payload 0 (min 40 (String.length s.payload)))

let summary (queue : t) : string =
  Printf.sprintf "%d stimulus%s pending"
    (List.length queue)
    (if List.length queue = 1 then "" else "es")
