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

let summary (queue : t) : string =
  Printf.sprintf "%d stimulus%s pending"
    (List.length queue)
    (if List.length queue = 1 then "" else "es")
