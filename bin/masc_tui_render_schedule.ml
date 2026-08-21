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
  mutable preempt_deadline : bool;
  mutable last_rendered_at_ns : int64 option;
}

let create ~min_interval_ns () =
  if Int64.compare min_interval_ns 0L < 0 then
    invalid_arg "render interval must be non-negative";
  { min_interval_ns;
    pending = Some Force;
    preempt_deadline = true;
    last_rendered_at_ns = None;
  }

let request schedule request =
  match request, schedule.pending with
  | Force, _ ->
      schedule.pending <- Some Force;
      schedule.preempt_deadline <- true
  | Input, Some Background ->
      (* User input supersedes a scheduled background paint, matching pi's
         immediate-render path without turning a byte burst into one write per
         byte. Subsequent input inside the same frame window still coalesces. *)
      schedule.pending <- Some Input;
      schedule.preempt_deadline <- true
  | Input, Some Force -> ()
  | Input, Some Input | Input, None -> schedule.pending <- Some Input
  | Background, None -> schedule.pending <- Some Background
  | Background, Some (Input | Background | Force) -> ()

let deadline schedule =
  Option.map
    (fun rendered_at -> Int64.add rendered_at schedule.min_interval_ns)
    schedule.last_rendered_at_ns

let take schedule ~now_ns =
  match schedule.pending with
  | None -> Idle
  | Some _ ->
    match deadline schedule with
    | Some due
      when (not schedule.preempt_deadline) && Int64.compare now_ns due < 0 ->
        Wait_until due
    | None | Some _ ->
        schedule.pending <- None;
        schedule.preempt_deadline <- false;
        schedule.last_rendered_at_ns <- Some now_ns;
        Render

let input_timeout_seconds schedule ~now_ns ~maximum =
  let maximum = max 0.0 maximum in
  match schedule.pending with
  | None -> maximum
  | Some _ when schedule.preempt_deadline -> 0.0
  | Some _ ->
    match deadline schedule with
    | None -> 0.0
    | Some due ->
        let remaining_ns = Int64.sub due now_ns in
        if Int64.compare remaining_ns 0L <= 0 then 0.0
        else
          min maximum (Int64.to_float remaining_ns /. 1_000_000_000.0)

let nonnegative_width width = max 0 width

let keeper_context_bar_width ~inner_width =
  nonnegative_width (min 30 (inner_width - 40))

module Input_wait = struct
  type 'a poll_result =
    | Ready of 'a
    | Timed_out
    | Interrupted

  let nanoseconds_per_second = 1_000_000_000.0

  let await ~now_ns ~timeout_ns ~poll =
    if Int64.compare timeout_ns 0L < 0 then
      invalid_arg "input wait must be non-negative";
    let deadline_ns = Int64.add (now_ns ()) timeout_ns in
    let rec loop () =
      let remaining_ns = Int64.sub deadline_ns (now_ns ()) in
      let remaining_seconds =
        if Int64.compare remaining_ns 0L <= 0 then 0.0
        else Int64.to_float remaining_ns /. nanoseconds_per_second
      in
      match poll remaining_seconds with
      | Ready value -> Some value
      | Timed_out -> None
      | Interrupted ->
          if Int64.compare (now_ns ()) deadline_ns >= 0 then None else loop ()
    in
    loop ()
end

module Input_shortcut = struct
  let is_quit ~message_mode key =
    (not message_mode) && (String.equal key "q" || String.equal key "Q")

  let opens_keepers ~message_mode key =
    (not message_mode) && String.equal key "2"
end

module Viewport = struct
  (* This is the largest fixed-row budget declared by a surface, not a promise
     that every variable section already accounts for the viewport. *)
  let minimum_fixed_chrome_rows = 14
  let requires_compact_frame ~rows = rows < minimum_fixed_chrome_rows
end

type overview_allocation = {
  attention_rows : int;
  task_error_rows : int;
  task_rows : int;
}

let allocate_overview ~terminal_rows ~has_cluster ~attention_count ~event_count
    ~task_count ~has_task_error =
  (* Ten rows are invariant chrome; the cluster/project row is present only
     after a briefing has loaded. Reserve one row for a nonempty task block,
     then size the shared Attention / Recent Events panel from either side. *)
  let fixed_rows = 10 + (if has_cluster then 1 else 0) in
  let available = max 0 (terminal_rows - fixed_rows) in
  let desired_panel_rows =
    min 6 (max 1 (max attention_count event_count))
  in
  let desired_task_error_rows = if has_task_error then 1 else 0 in
  let desired_task_rows =
    if task_count <= 0 then
      if has_task_error then 0 else 1
    else
      min (if has_task_error then 4 else 5) task_count
  in
  let desired_task_block_rows =
    desired_task_error_rows + desired_task_rows
  in
  let reserved_task_rows = min 1 desired_task_block_rows in
  let attention_rows =
    min desired_panel_rows (max 0 (available - reserved_task_rows))
  in
  let task_block_rows =
    min desired_task_block_rows (max 0 (available - attention_rows))
  in
  let task_error_rows = min desired_task_error_rows task_block_rows in
  let task_rows =
    min desired_task_rows (max 0 (task_block_rows - task_error_rows))
  in
  { attention_rows; task_error_rows; task_rows }

type board_read_allocation = {
  body_rows : int;
  comment_rows : int;
}

let allocate_board_read ~terminal_rows ~body_line_count ~comment_count =
  (* Eight rows are invariant chrome. A visible Comments section adds its
     divider and heading; keep one body row when the post has body text, then
     give comments their existing five-row cap. *)
  let comment_count = max 0 comment_count in
  let comment_chrome_rows = if comment_count > 0 then 2 else 0 in
  let available = max 0 (terminal_rows - 8 - comment_chrome_rows) in
  let minimum_body_rows = if body_line_count > 0 then 1 else 0 in
  let comment_rows =
    min (min 5 comment_count) (max 0 (available - minimum_body_rows))
  in
  let body_rows = max 0 (available - comment_rows) in
  { body_rows; comment_rows }

type board_read_scroll = {
  normalized_scroll : int;
  body_offset : int;
  comment_offset : int;
}

let project_board_read_scroll ~body_line_count ~body_rows ~comment_count
    ~comment_rows scroll =
  let body_line_count = max 0 body_line_count in
  let body_rows = max 0 body_rows in
  let comment_count = max 0 comment_count in
  let comment_rows = max 0 comment_rows in
  let maximum_body_offset = max 0 (body_line_count - body_rows) in
  let maximum_comment_offset = max 0 (comment_count - comment_rows) in
  let maximum_scroll = maximum_body_offset + maximum_comment_offset in
  let normalized_scroll = max 0 (min scroll maximum_scroll) in
  let body_offset = min normalized_scroll maximum_body_offset in
  let comment_offset =
    min maximum_comment_offset (normalized_scroll - body_offset)
  in
  { normalized_scroll; body_offset; comment_offset }

module Terminal_size_cache = struct
  type t = {
    fallback : int * int;
    mutable cached : (int * int) option;
  }

  (* Box rows require two borders and one space on each side. Clamping a
     transient tiny resize keeps every renderer total without inventing
     surface-specific fallbacks. *)
  let normalize (rows, cols) = max 1 rows, max 4 cols

  let valid (rows, cols) = rows > 0 && cols > 0

  let create ~fallback =
    if not (valid fallback) then invalid_arg "terminal fallback must be positive";
    { fallback = normalize fallback; cached = None }

  let invalidate cache = cache.cached <- None

  let get cache ~probe =
    match cache.cached with
    | Some size -> size
    | None ->
        let size =
          match probe () with
          | Some size when valid size -> normalize size
          | Some _ | None -> cache.fallback
        in
        cache.cached <- Some size;
        size
end
