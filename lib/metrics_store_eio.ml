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
type config = Workspace_utils.config

(** Get metrics directory *)
let metrics_dir (config : config) =
  Filename.concat (Workspace_utils.masc_dir config) "metrics"

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

type read_error =
  | Invalid_agent_id of string
  | Invalid_window of int
  | Source_unavailable of { path : string; message : string }
  | Invalid_record of { path : string; line : int; message : string }

let read_error_to_string = function
  | Invalid_agent_id name -> Printf.sprintf "invalid metric agent identity: %S" name
  | Invalid_window days -> Printf.sprintf "metric days must be positive: %d" days
  | Source_unavailable { path; message } -> Printf.sprintf "%s: %s" path message
  | Invalid_record { path; line; message } ->
      Printf.sprintf "%s:%d: %s" path line message

let ( let* ) = Result.bind

let valid_agent_id name =
  not (String.equal (String.trim name) "" || String.equal name "." || String.equal name "..")
  && String.equal (Filename.basename name) name
  && not (String.contains name '\000')

let owned_error path error =
  Source_unavailable
    { path; message = Fs_compat.owned_regular_file_read_error_to_string error }

let read_inventory config path =
  Fs_compat.read_owned_directory_if_present ~owner_uid:(Unix.getuid ())
    ~ownership_root:(Workspace_utils.masc_dir config) path
  |> Result.map_error (owned_error path)

(** Every nonblank physical line must decode under the exact source identity.
    A rejected row never becomes an empty or partially successful metric pool. *)
let read_metrics_file config ~agent_id file =
  let* contents =
    Fs_compat.load_owned_regular_file
      ~ownership_root:(Workspace_utils.masc_dir config) file
    |> Result.map_error (owned_error file)
  in
  match contents with
  | None -> Error (Source_unavailable { path = file; message = "captured metric file disappeared" })
  | Some contents ->
      let rec parse line_number acc = function
        | [] -> Ok (List.rev acc)
        | line :: rest when String.equal (String.trim line) "" ->
            parse (line_number + 1) acc rest
        | line :: rest ->
            let invalid message = Error (Invalid_record { path = file; line = line_number; message }) in
            let decoded =
              try Ok (Yojson.Safe.from_string line)
              with Yojson.Json_error _ -> invalid "invalid metric JSON"
            in
            let* json = decoded in
            (match task_metric_of_yojson json with
             | Error _ -> invalid "invalid metric record"
             | Ok metric ->
                 if not (String.equal metric.agent_id agent_id) then
                   invalid "metric agent identity differs from directory"
                 else if not (Float.is_finite metric.started_at)
                   || not (Option.fold ~none:true ~some:Float.is_finite metric.completed_at) then
                   invalid "metric timestamps must be finite"
                 else parse (line_number + 1) (metric :: acc) rest)
      in
      parse 1 [] (String.split_on_char '\n' contents)

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

(** Read and filter against one query window, without changing raw identity. *)
let read_recent config ~agent_id ~days =
  if not (valid_agent_id agent_id) then Error (Invalid_agent_id agent_id)
  else if days <= 0 then Error (Invalid_window days)
  else
    let now = Time_compat.now () in
    let cutoff = now -. Masc_time_constants.days_to_seconds days in
    let dir = agent_metrics_dir config agent_id in
    let* inventory = read_inventory config dir in
    let files =
      match inventory with
      | None -> []
      | Some names ->
          names
          |> List.filter (fun name -> Filename.check_suffix name ".jsonl")
          |> filter_recent_month_filenames ~now ~days
          |> List.map (Filename.concat dir)
    in
    let rec read acc = function
      | [] -> Ok (List.rev acc)
      | file :: rest ->
          safe_yield ();
          let* rows = read_metrics_file config ~agent_id file in
          read (List.rev_append rows acc) rest
    in
    let* rows = read [] files in
    Ok (now, List.filter
      (fun (metric : task_metric) -> metric.started_at >= cutoff && metric.started_at <= now)
      rows)

let get_recent config ~agent_id ~days =
  Result.map snd (read_recent config ~agent_id ~days)

(** Calculate aggregated metrics for fitness - synchronous *)
let calculate_agent_metrics config ~agent_id ~days =
  let* now, metrics = read_recent config ~agent_id ~days in
  if Stdlib.List.length metrics = 0 then
    Ok None
  else
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

    Ok (Some {
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
    })

(** Successful inventory includes only observed agent directories. *)
let get_all_agents config =
  let dir = metrics_dir config in
  let* inventory = read_inventory config dir in
  let rec directories acc = function
    | [] -> Ok (List.rev acc)
    | name :: rest ->
        let path = Filename.concat dir name in
        (match Fs_compat.exact_path_kind ~follow:false path with
         | Exact_kind Unix.S_DIR -> directories (name :: acc) rest
         | Exact_kind (Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK) ->
             directories acc rest
         | Exact_kind Unix.S_LNK | Exact_missing | Exact_unknown ->
             Error (Source_unavailable { path; message = "metric directory identity unavailable" }))
  in
  match inventory with None -> Ok [] | Some names -> directories [] names
