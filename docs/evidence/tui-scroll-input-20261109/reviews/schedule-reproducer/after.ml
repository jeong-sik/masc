type decision =
  | Idle
  | Wait_until of int64
  | Render

type request =
  | Input
  | Background
  | Force

type t = {
  min_interval_ns : int64;
  mutable pending : request option;
  mutable last_started_at_ns : int64 option;
  mutable last_completed_at_ns : int64 option;
}

let create ~min_interval_ns () =
  if Int64.compare min_interval_ns 0L < 0 then
    invalid_arg "render interval must be non-negative";
  { min_interval_ns;
    pending = Some Force;
    last_started_at_ns = None;
    last_completed_at_ns = None;
  }

let request schedule request =
  match request, schedule.pending with
  | Force, _ -> schedule.pending <- Some Force
  | Input, Some Force -> ()
  | Input, Some (Input | Background) | Input, None -> schedule.pending <- Some Input
  | Background, None -> schedule.pending <- Some Background
  | Background, Some (Input | Background | Force) -> ()

let deadline ~after_work schedule =
  let previous = if after_work then
      match schedule.last_completed_at_ns with
      | Some _ as completed -> completed
      | None -> schedule.last_started_at_ns
    else schedule.last_started_at_ns in
  Option.map
    (fun rendered_at -> Int64.add rendered_at schedule.min_interval_ns)
    previous

let take ~input_pending schedule ~now_ns =
  let render () =
    schedule.pending <- None;
    schedule.last_started_at_ns <- Some now_ns;
    schedule.last_completed_at_ns <- None;
    Render
  in
  match schedule.pending with
  | None -> Idle
  | Some Force -> render ()
  | Some Input when not input_pending -> render ()
  | Some (Input | Background as request) ->
    (* Available input can still be combined. A continuous stream keeps the
       frame interval; once it drains, the branch above presents its result
       without waiting for more input that may never arrive. *)
    match deadline ~after_work:(request = Input) schedule with
    | Some due when Int64.compare now_ns due < 0 ->
        Wait_until due
    | None | Some _ -> render ()

let completed schedule ~now_ns =
  schedule.last_completed_at_ns <- Some now_ns

let input_timeout_seconds schedule ~now_ns ~maximum =
  let maximum = max 0.0 maximum in
  match schedule.pending with
  | None -> maximum
  | Some (Force | Input) -> 0.0
  | Some Background ->
    (match deadline ~after_work:false schedule with
     | None -> 0.0
     | Some due ->
       let remaining_ns = Int64.sub due now_ns in
       if Int64.compare remaining_ns 0L <= 0 then 0.0
       else min maximum (Int64.to_float remaining_ns /. 1_000_000_000.0))

let show = function Render -> "render" | Idle -> "idle" | Wait_until at -> "wait:" ^ Int64.to_string at
let ns x = Int64.mul (Int64.of_int x) 1000000L
let () =
 let schedule = create ~min_interval_ns:(ns 16) () in
 ignore (take ~input_pending:false schedule ~now_ns:0L);
 completed schedule ~now_ns:(ns 64);
 request schedule Input;
 print_endline (show (take ~input_pending:true schedule ~now_ns:(ns 65)))
