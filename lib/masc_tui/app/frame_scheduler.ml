type pace =
  | Pace_interactive
  | Pace_animation

let frame_interval_60fps_ns = 16_666_667L
let frame_interval_30fps_ns = 33_333_333L
let backpressure_retry_ns = 8_000_000L

let interval_ns = function
  | Pace_interactive -> frame_interval_60fps_ns
  | Pace_animation -> frame_interval_30fps_ns

type decision =
  | Render_now
  | Skip_backpressure of { retry_at_ns : int64 }
  | Wait_until of { deadline_ns : int64 }
  | Sleep_idle

type next_deadline = Next_deadline_ns of int64 option

type sample = {
  render_us : int;
  diff_us : int;
}

type telemetry = {
  frames_rendered : int;
  frames_skipped_backpressure : int;
  last_render_us : int;
  last_diff_us : int;
  last_dirty_cells : int;
  last_bytes_emitted : int;
  avg_render_us : int;
  avg_diff_us : int;
  max_render_us : int;
  window_samples : int;
}

type t = {
  dirty : bool;
  pace : pace;
  last_present_ns : int64 option;
  extra_deadline_ns : int64 option;
  window_capacity : int;
  samples : sample list;
  frames_rendered : int;
  frames_skipped_backpressure : int;
  last_render_us : int;
  last_diff_us : int;
  last_dirty_cells : int;
  last_bytes_emitted : int;
  max_render_us : int;
}

let create ?(window_capacity = 60) () =
  {
    dirty = true;
    pace = Pace_interactive;
    last_present_ns = None;
    extra_deadline_ns = None;
    window_capacity = max 1 window_capacity;
    samples = [];
    frames_rendered = 0;
    frames_skipped_backpressure = 0;
    last_render_us = 0;
    last_diff_us = 0;
    last_dirty_cells = 0;
    last_bytes_emitted = 0;
    max_render_us = 0;
  }

let faster_pace a b =
  match a, b with
  | Pace_interactive, _ | _, Pace_interactive -> Pace_interactive
  | Pace_animation, Pace_animation -> Pace_animation

let mark_dirty ?(pace = Pace_interactive) t =
  let next_pace = if t.dirty then faster_pace t.pace pace else pace in
  { t with dirty = true; pace = next_pace }

let set_extra_deadline extra_deadline_ns t = { t with extra_deadline_ns }
let is_dirty t = t.dirty
let current_pace t = t.pace

let add_saturating a b =
  let sum = Int64.add a b in
  if Int64.compare b 0L > 0 && Int64.compare sum a < 0 then Int64.max_int
  else sum

let earliest_opt a b =
  match a, b with
  | None, x | x, None -> x
  | Some x, Some y -> Some (if Int64.compare x y <= 0 then x else y)

let decide ~now_ns ~output_behind t =
  if not t.dirty then
    match t.extra_deadline_ns with
    | None -> Sleep_idle
    | Some deadline_ns -> Wait_until { deadline_ns }
  else if output_behind then
    Skip_backpressure { retry_at_ns = add_saturating now_ns backpressure_retry_ns }
  else
    match t.last_present_ns with
    | None -> Render_now
    | Some last_ns ->
        let due_ns = add_saturating last_ns (interval_ns t.pace) in
        if Int64.compare now_ns due_ns >= 0 then Render_now
        else Wait_until { deadline_ns = due_ns }

let take_prefix limit xs =
  let rec loop n acc = function
    | [] -> List.rev acc
    | _ when n <= 0 -> List.rev acc
    | x :: rest -> loop (n - 1) (x :: acc) rest
  in
  loop limit [] xs

let record_rendered ~now_ns ~render_us ~diff_us ~dirty_cells ~bytes_emitted t =
  let render_us = max 0 render_us in
  let diff_us = max 0 diff_us in
  let dirty_cells = max 0 dirty_cells in
  let bytes_emitted = max 0 bytes_emitted in
  let samples =
    take_prefix t.window_capacity ({ render_us; diff_us } :: t.samples)
  in
  {
    t with
    dirty = false;
    pace = Pace_animation;
    last_present_ns = Some now_ns;
    samples;
    frames_rendered = t.frames_rendered + 1;
    last_render_us = render_us;
    last_diff_us = diff_us;
    last_dirty_cells = dirty_cells;
    last_bytes_emitted = bytes_emitted;
    max_render_us = max t.max_render_us render_us;
  }

let record_skipped_backpressure ~now_ns:_ t =
  {
    t with
    dirty = true;
    frames_skipped_backpressure = t.frames_skipped_backpressure + 1;
  }

let next_deadline ~now_ns ~output_behind t =
  match decide ~now_ns ~output_behind t with
  | Render_now -> Next_deadline_ns (Some now_ns)
  | Skip_backpressure { retry_at_ns } ->
      Next_deadline_ns (earliest_opt (Some retry_at_ns) t.extra_deadline_ns)
  | Wait_until { deadline_ns } ->
      Next_deadline_ns (earliest_opt (Some deadline_ns) t.extra_deadline_ns)
  | Sleep_idle -> Next_deadline_ns None

let telemetry t =
  let count = List.length t.samples in
  let sum_render, sum_diff =
    List.fold_left
      (fun (sr, sd) s -> (sr + s.render_us, sd + s.diff_us))
      (0, 0) t.samples
  in
  let avg_render_us = if count = 0 then 0 else sum_render / count in
  let avg_diff_us = if count = 0 then 0 else sum_diff / count in
  {
    frames_rendered = t.frames_rendered;
    frames_skipped_backpressure = t.frames_skipped_backpressure;
    last_render_us = t.last_render_us;
    last_diff_us = t.last_diff_us;
    last_dirty_cells = t.last_dirty_cells;
    last_bytes_emitted = t.last_bytes_emitted;
    avg_render_us;
    avg_diff_us;
    max_render_us = t.max_render_us;
    window_samples = count;
  }
