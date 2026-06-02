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

type t =
  { front : stimulus list
  ; back_rev : stimulus list
  ; length : int
  }

let empty : t = { front = []; back_rev = []; length = 0 }

let length q = q.length

let is_empty q = q.length = 0

let enqueue (queue : t) (s : stimulus) : t =
  { queue with back_rev = s :: queue.back_rev; length = queue.length + 1 }

let to_list (queue : t) : stimulus list =
  match queue.back_rev with
  | [] -> queue.front
  | back_rev -> queue.front @ List.rev back_rev

let of_list (items : stimulus list) : t =
  { front = items; back_rev = []; length = List.length items }

let dequeue (queue : t) : (stimulus * t) option =
  match queue.front with
  | s :: rest -> Some (s, { queue with front = rest; length = queue.length - 1 })
  | [] ->
    (match List.rev queue.back_rev with
     | [] -> None
     | s :: rest -> Some (s, { front = rest; back_rev = []; length = queue.length - 1 }))

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
  of_list (aux [] (to_list queue))

let sort_by_urgency (queue : t) : t =
  queue
  |> to_list
  |> List.stable_sort
       (fun a b -> Int.compare (urgency_rank a.urgency) (urgency_rank b.urgency))
  |> of_list

type stimulus_class =
  | Board_signal
  | Bootstrap
  | Alive_but_stuck_recovery
  | Stay_silent_recovery
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
  else if has_prefix "{\"source\":\"stay_silent_recovery\"" then
    Stay_silent_recovery
  (* Board signals carry JSON with "source":"board_signal". Lightweight
     prefix check avoids a full Yojson parse in the data layer. *)
  else if has_prefix "{\"source\":\"board_signal\"" then Board_signal
  else
    Unsupported
      (String.sub s.payload 0 (min 40 (String.length s.payload)))

let drain_board_window ?(window_sec = 2.0) (queue : t) : stimulus list * t =
  let now = Unix.gettimeofday () in
  let is_board_in_window s =
    match classify s with
    | Board_signal -> Float.abs (now -. s.arrived_at) <= window_sec
    | _ -> false
  in
  let board, rest = List.partition is_board_in_window (to_list queue) in
  (to_list (sort_by_urgency (of_list board)), of_list rest)

let summary (queue : t) : string =
  Printf.sprintf "%d stimulus%s pending"
    queue.length
    (if queue.length = 1 then "" else "es")
