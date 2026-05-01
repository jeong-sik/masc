open Base
module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** MASC Metrics Store - Agent Performance Tracking (Eio Native)

    Pure synchronous metrics operations.
    Compatible with Eio direct-style concurrency.

    에이전트 성과 측정 데이터 저장:
    - Task completion rates
    - Response times
    - Error rates
    - Collaboration patterns (for Hebbian learning)

    Storage: .masc/metrics/{agent_name}/YYYY-MM.jsonl
*)

(** Task completion metric *)
type task_metric = {
  id: string;               (* Unique metric ID *)
  agent_id: string;         (* Agent name: claude, gemini, codex *)
  task_id: string;          (* Task being measured *)
  started_at: float;        (* Unix timestamp *)
  completed_at: float option [@default None];  (* None if still in progress *)
  success: bool;            (* Task succeeded? *)
  error_message: string option [@default None];  (* Error if failed *)
  collaborators: string list;  (* Other agents involved - for Hebbian *)
  handoff_from: string option [@default None];  (* Previous agent if handoff *)
  handoff_to: string option [@default None];    (* Next agent if handoff out *)
} [@@deriving yojson, show]

(** Aggregated metrics for fitness calculation *)
type agent_metrics = {
  agent_id: string;
  period_start: float;      (* Start of measurement period *)
  period_end: float;        (* End of measurement period *)
  total_tasks: int;
  completed_tasks: int;
  failed_tasks: int;
  avg_completion_time_s: float;
  task_completion_rate: float;  (* 0.0-1.0 *)
  error_rate: float;            (* 0.0-1.0 *)
  handoff_success_rate: float;  (* 0.0-1.0 *)
  unique_collaborators: string list;
} [@@deriving yojson, show]

(** Config type alias for clarity *)
type config = Coord_utils.config

(** Get metrics directory *)
let metrics_dir (config : config) =
  Filename.concat (Coord_utils.masc_dir config) "metrics"

(** Get agent-specific metrics directory *)
let agent_metrics_dir config agent_id =
  Filename.concat (metrics_dir config) agent_id

(** Ensure metrics directories exist *)
let ensure_metrics_dir config agent_id =
  let agent_dir = agent_metrics_dir config agent_id in
  Fs_compat.mkdir_p agent_dir

(** Get current month's file path *)
let current_month_file config agent_id =
  let tm = Unix.gmtime (Time_compat.now ()) in
  let filename = Printf.sprintf "%04d-%02d.jsonl"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) in
  Filename.concat (agent_metrics_dir config agent_id) filename

(** Generate unique metric ID *)
let metric_counter = Atomic.make 0

let generate_id () =
  (* Use [fetch_and_add] rather than [Atomic.incr; Atomic.get] so the counter
     read is atomic with the increment. With the split pair, two fibers can
     both [incr] before either [get], and both observe the same post-increment
     value, producing duplicate IDs for entries in the same millisecond. *)
  let sequence = Atomic.fetch_and_add metric_counter 1 + 1 in
  let timestamp_ms = Stdlib.Int.of_float (Time_compat.now () *. 1000.) in
  Printf.sprintf "metric-%d-%06d" timestamp_ms sequence

(* Async write queue: callers push (file, line) entries into a bounded stream.
   A background fiber drains the stream and batches file appends, eliminating
   the previous global mutex + synchronous I/O pattern that blocked all writers. *)

type write_entry = { file: string; line: string }

let write_queue : write_entry Eio.Stream.t = Eio.Stream.create 256

let queue_active = Atomic.make false

(** Record a new task metric.
    Lock-free: serializes the metric to JSON and pushes to the write queue.
    Actual file I/O happens in the background flush fiber. *)
let record config (metric : task_metric) : unit =
  ensure_metrics_dir config metric.agent_id;
  let file = current_month_file config metric.agent_id in
  let json = task_metric_to_yojson metric in
  let line = Yojson.Safe.to_string json ^ "\n" in
  if Atomic.get queue_active then
    Eio.Stream.add write_queue { file; line }
  else
    (* Fallback: no flush fiber running (tests, pre-init). Direct write. *)
    Fs_compat.append_file file line

(** Drain all pending entries from the write queue, batching by file. *)
let flush_pending () =
  let batch = Hashtbl.create 8 in
  let rec drain () =
    match Eio.Stream.take_nonblocking write_queue with
    | None -> ()
    | Some entry ->
        let prev = Option.value ~default:(Buffer.create 256) (Hashtbl.find_opt batch entry.file) in
        Buffer.add_string prev entry.line;
        Hashtbl.replace batch entry.file prev;
        drain ()
  in
  drain ();
  Hashtbl.iter (fun file buf ->
    (try Fs_compat.append_file file (Buffer.contents buf)
     with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
       Log.Metrics.error "flush_pending: append failed for %s: %s"
         file (Stdlib.Printexc.to_string exn))
  ) batch

(** Start the background flush fiber. Call once inside Eio_main.run.
    Drains the write queue every 500ms or when the stream has entries. *)
let start_flush_fiber ~clock =
  let flush_interval_s = 0.5 in
  Atomic.set queue_active true;
  let rec loop () =
    Eio.Time.sleep clock flush_interval_s;
    flush_pending ();
    loop ()
  in
  loop ()

(** Create a new task metric (helper) - pure *)
let create_metric ~agent_id ~task_id ?(collaborators=[]) ?handoff_from () =
  {
    id = generate_id ();
    agent_id;
    task_id;
    started_at = Time_compat.now ();
    completed_at = None;
    success = false;
    error_message = None;
    collaborators;
    handoff_from;
    handoff_to = None;
  }

(** Mark task as completed - pure *)
let complete_metric metric ~success ?error_message ?handoff_to () =
  { metric with
    completed_at = Some (Time_compat.now ());
    success;
    error_message;
    handoff_to;
  }

(** Read metrics from a file - synchronous *)
let read_metrics_file file : task_metric list =
  if not (Fs_compat.file_exists file) then
    []
  else
    let content = Fs_compat.load_file file in
    let lines = String.split_on_char '\n' content
      |> List.filter (fun s -> not (String.equal (String.trim s) "")) in
    List.filter_map (fun line ->
      try
        let json = Yojson.Safe.from_string line in
        match task_metric_of_yojson json with
        | Ok m -> Some m
        | Error e ->
          let preview = String_util.utf8_safe ~max_bytes:53 ~suffix:"..." line |> String_util.to_string in
          Log.Metrics.error "Failed to parse metric: %s (line: %s)" e preview;
          None
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        let preview = String_util.utf8_safe ~max_bytes:53 ~suffix:"..." line |> String_util.to_string in
        Log.Metrics.error "JSON parse error: %s (line: %s)"
          (Stdlib.Printexc.to_string exn) preview;
        None
    ) lines

let safe_yield () =
  Safe_ops.protect ~default:() (fun () -> Eio.Fiber.yield ())

let month_key ~year ~month =
  (year * 12) + (month - 1)

let month_key_of_unix timestamp =
  let tm = Unix.gmtime timestamp in
  month_key ~year:(tm.Unix.tm_year + 1900) ~month:(tm.Unix.tm_mon + 1)

let parse_month_key_from_filename filename =
  if not (Filename.check_suffix filename ".jsonl") then
    None
  else
    match String.split_on_char '-' (Filename.chop_suffix filename ".jsonl") with
    | [ year_s; month_s ] -> (
        match Stdlib.int_of_string_opt year_s, Stdlib.int_of_string_opt month_s with
        | Some year, Some month when month >= 1 && month <= 12 ->
            Some (month_key ~year ~month)
        | _ -> None)
    | _ -> None

let filter_recent_month_filenames ~now ~days filenames =
  let cutoff = now -. Masc_time_constants.days_to_seconds days in
  let min_month = month_key_of_unix cutoff in
  let max_month = month_key_of_unix now in
  List.filter
    (fun filename ->
      match parse_month_key_from_filename filename with
      | Some key -> key >= min_month && key <= max_month
      | None -> true)
    filenames

(** Get recent metrics for an agent - synchronous *)
let get_recent config ~agent_id ~days : task_metric list =
  let now = Time_compat.now () in
  let cutoff = now -. Masc_time_constants.days_to_seconds days in
  let dir = agent_metrics_dir config agent_id in
  if not (Sys.file_exists dir) then
    []
  else
    let files =
      Sys.readdir dir |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".jsonl")
      |> filter_recent_month_filenames ~now ~days
      |> List.map (fun f -> Filename.concat dir f)
    in
    let all_metrics =
      List.concat_map
        (fun file ->
          safe_yield ();
          read_metrics_file file)
        files
    in
    List.filter (fun m -> Stdlib.Float.compare m.started_at cutoff >= 0) all_metrics

(** Calculate aggregated metrics for fitness - synchronous *)
let calculate_agent_metrics config ~agent_id ~days : agent_metrics option =
  let metrics = get_recent config ~agent_id ~days in
  if Stdlib.List.length metrics = 0 then
    None
  else
    let now = Time_compat.now () in
    let period_start = now -. Masc_time_constants.days_to_seconds days in
    let total = List.length metrics in
    let completed = List.filter (fun m -> Option.is_some m.completed_at) metrics in
    let successful = List.filter (fun m -> m.success) completed in
    let failed = List.filter (fun m -> not m.success) completed in

    (* Calculate average completion time *)
    let completion_times = List.filter_map (fun m ->
      match m.completed_at with
      | Some t -> Some (t -. m.started_at)
      | None -> None
    ) metrics in
    let avg_time = match completion_times with
      | [] -> 0.0
      | times ->
        let sum = List.fold_left (+.) 0.0 times in
        sum /. (Stdlib.Float.of_int (List.length times)) in

    (* Calculate handoff success rate *)
    let handoffs = List.filter (fun m -> Option.is_some m.handoff_from || Option.is_some m.handoff_to) metrics in
    let successful_handoffs = List.filter (fun m -> m.success) handoffs in
    let handoff_rate = if Stdlib.List.length handoffs > 0 then
      Stdlib.Float.of_int (List.length successful_handoffs) /. Stdlib.Float.of_int (List.length handoffs)
    else 1.0 in  (* No handoffs = perfect handoff rate *)

    (* Unique collaborators *)
    let all_collaborators = List.concat_map (fun m -> m.collaborators) metrics in
    let unique_collabs = List.sort_uniq String.compare all_collaborators in

    Some {
      agent_id;
      period_start;
      period_end = now;
      total_tasks = total;
      completed_tasks = List.length successful;
      failed_tasks = List.length failed;
      avg_completion_time_s = avg_time;
      task_completion_rate = if total > 0 then Stdlib.Float.of_int (List.length successful) /. Stdlib.Float.of_int total else 0.0;
      error_rate = if total > 0 then Stdlib.Float.of_int (List.length failed) /. Stdlib.Float.of_int total else 0.0;
      handoff_success_rate = handoff_rate;
      unique_collaborators = unique_collabs;
    }

(** Get all agents with metrics - synchronous *)
let get_all_agents config : string list =
  let dir = metrics_dir config in
  if not (Sys.file_exists dir) then
    []
  else
    let entries = Sys.readdir dir |> Array.to_list in
    List.filter (fun e ->
      let path = Filename.concat dir e in
      Sys.is_directory path
    ) entries
