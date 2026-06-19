type urgency =
  | Immediate
  | Normal
  | Low

let urgency_rank = function
  | Immediate -> 0
  | Normal -> 1
  | Low -> 2

type post_id = string

type board_stimulus_kind =
  | Post_created
  | Comment_added

type board_stimulus = {
  kind : board_stimulus_kind;
  author : string;
  title : string;
  content : string;
  hearth : string option;
  updated_at : float option;
}

type stimulus_payload =
  | Board_signal of board_stimulus
  | Bootstrap
  | No_progress_recovery
  | Fusion_completed of fusion_completion
      (* RFC-0266: an async [masc_fusion] deliberation finished. Wakes the
         calling keeper so the resolved answer arrives as actionable turn
         input on its next cycle, instead of being discovered passively. *)

and fusion_completion = {
  run_id : string;
  ok : bool;  (* judge synthesized vs denied/sink_failed/aborted. *)
  resolved_answer : string;
  (* judge resolved answer; a failure label when [ok = false]. *)
  board_post_id : string;
  (* correlates to the sink's board evidence post; "" if none was created. *)
}

let fusion_completion_post_id (fc : fusion_completion) =
  if String.equal fc.board_post_id "" then "fusion-run:" ^ fc.run_id
  else fc.board_post_id

type stimulus = {
  post_id : post_id;
  urgency : urgency;
  arrived_at : float;
  payload : stimulus_payload;
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

let payload_kind_label = function
  | Board_signal _ -> "board_signal"
  | Bootstrap -> "bootstrap"
  | No_progress_recovery -> "no_progress_recovery"
  | Fusion_completed _ -> "fusion_completed"

let is_board_signal = function
  | Board_signal _ -> true
  | Bootstrap | No_progress_recovery | Fusion_completed _ -> false

let drain_board_window ?(window_sec = 2.0) (queue : t) : stimulus list * t =
  let now = Unix.gettimeofday () in
  let is_board_in_window s =
    is_board_signal s.payload && Float.abs (now -. s.arrived_at) <= window_sec
  in
  let board, rest = List.partition is_board_in_window (to_list queue) in
  (to_list (sort_by_urgency (of_list board)), of_list rest)

let summary (queue : t) : string =
  Printf.sprintf "%d stimulus%s pending"
    queue.length
    (if queue.length = 1 then "" else "es")
