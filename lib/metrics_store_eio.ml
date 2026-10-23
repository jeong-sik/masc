(** MASC Metrics Store - Agent Performance Tracking (Eio Native)

    Pure synchronous metrics operations.
    Compatible with Eio direct-style concurrency.

    에이전트 성과 측정 데이터 저장:
    - Task completion rates
    - Response times
    - Error rates
    - Collaboration patterns (for Hebbian learning)

    Storage: .masc/metrics/<SHA256(exact agent)>/YYYY-MM.jsonl
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
  Filename.concat (metrics_dir config) Digestif.SHA256.(digest_string agent_id |> to_hex)

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
  not (String.equal (String.trim name) "")

let owned_error path error =
  Source_unavailable
    { path; message = Fs_compat.owned_regular_file_read_error_to_string error }

let read_inventory config path =
  Fs_compat.read_owned_directory_if_present ~owner_uid:(Unix.getuid ())
    ~ownership_root:(Workspace_utils.masc_dir config) path
  |> Result.map_error (owned_error path)

type record_receipt = Enqueued | Written

type record_error =
  | Invalid_metric_identity of string
  | Metric_store_failure of { path : string; message : string }

let record_error_to_string = function
  | Invalid_metric_identity name -> Printf.sprintf "invalid metric identity: %S" name
  | Metric_store_failure { path; message } -> Printf.sprintf "%s: %s" path message

let store_schema = "masc.agent-metrics/v1"
let identity_schema = "masc.agent-metric-identity/v1"
let store_document config = Filename.concat (metrics_dir config) "store.json"
let identity_document config agent_id = Filename.concat (agent_metrics_dir config agent_id) "identity.json"

let parse_document bytes =
  try Ok (Yojson.Safe.from_string bytes)
  with Yojson.Json_error _ -> Error "invalid metric identity JSON"

let check_store_document bytes =
  let* json = parse_document bytes in
  match json with
  | `Assoc fields when List.length fields = 1 && List.assoc_opt "schema" fields = Some (`String store_schema) -> Ok ()
  | _ -> Error "unsupported metric store format"

let parse_identity_document bytes =
  let* json = parse_document bytes in
  match json with
  | `Assoc fields when List.length fields = 2 && List.assoc_opt "schema" fields = Some (`String identity_schema) ->
      (match List.assoc_opt "agent_id" fields with
       | Some (`String name) when valid_agent_id name -> Ok name
       | _ -> Error "invalid metric identity document")
  | _ -> Error "unsupported metric identity document"

let read_document_opt config path =
  Fs_compat.load_owned_regular_file_with_snapshot ~owner_uid:(Unix.getuid ())
    ~ownership_root:(Workspace_utils.masc_dir config) path
  |> Result.map_error (owned_error path)
  |> Result.map (Option.map (fun (document : Fs_compat.owned_regular_file_contents) -> document.content))

let read_document config path =
  let* bytes = read_document_opt config path in
  match bytes with
  | Some bytes -> Ok bytes
  | None -> Error (Source_unavailable { path; message = "metric identity document is absent" })

(** Once a store is bound, a named read only checks the fixed format document.
    Inventory is needed only to distinguish a truly empty unbound store. *)
let check_store_layout config =
  let path = store_document config in
  let* document = read_document_opt config path in
  match document with
  | Some bytes ->
      let* () = check_store_document bytes
        |> Result.map_error (fun message -> Source_unavailable {path;message}) in
      Ok true
  | None ->
      let* inventory = read_inventory config (metrics_dir config) in
      (match inventory with
       | None | Some [] -> Ok false
       | Some (_ :: _) -> Error (Source_unavailable {path;message="nonempty metric store has no format binding"}))

let read_store_inventory config =
  let* bound = check_store_layout config in
  if not bound then Ok None
  else
    let* inventory = read_inventory config (metrics_dir config) in
    match inventory with
    | Some names -> Ok (Some names)
    | None -> Error (Source_unavailable {path=metrics_dir config;message="bound metric store disappeared"})

let read_agent_identity config ~directory =
  let path = Filename.concat directory "identity.json" in
  let* bytes = read_document config path in
  let* agent_id = parse_identity_document bytes
    |> Result.map_error (fun message -> Source_unavailable { path; message }) in
  if String.equal directory (agent_metrics_dir config agent_id) then Ok agent_id
  else Error (Source_unavailable { path; message = "metric identity differs from storage key" })

let check_agent_identity config agent_id =
  let directory = agent_metrics_dir config agent_id in
  let* observed = read_agent_identity config ~directory in
  if String.equal observed agent_id then Ok ()
  else Error (Source_unavailable { path = directory; message = "metric identity differs from requested agent" })

let record_source_error path error =
  Metric_store_failure { path; message = read_error_to_string error }

let expected_io path action =
  try action () with
  | Unix.Unix_error _ as error -> Error (Metric_store_failure { path; message = Printexc.to_string error })
  | Sys_error message -> Error (Metric_store_failure { path; message })
  | Eio.Io _ as error -> Error (Metric_store_failure { path; message = Printexc.to_string error })

(** Stage outside the unbound directory so another initializer's inventory
    does not mistake our private work for an incompatible store. Publish only
    complete, synced bytes; a competing binding is never replaced. *)
let publish_document ~directory ~path ~contents =
  let publish () =
    let staging_directory = Filename.dirname directory in
    let staged, channel = Fs_compat.open_atomic_temp_file ~temp_dir:staging_directory () in
    Fun.protect
      ~finally:(fun () ->
        close_out_noerr channel;
        try Unix.unlink staged with Unix.Unix_error (Unix.ENOENT, _, _) -> ())
      (fun () ->
        output_string channel (contents ^ "\n");
        flush channel;
        Unix.fsync (Unix.descr_of_out_channel channel);
        close_out channel;
        (try Fs_compat.rename_noreplace staged path
         with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
        (* Even the losing publisher syncs the complete winner. A sync failure
           leaves any published document in place; there is no rollback. *)
        Keeper_fs_durable_directory.fsync_directory directory;
        Keeper_fs_durable_directory.fsync_directory staging_directory)
  in
  match Fs_compat.execution_context () with
  | Non_eio -> publish ()
  | Eio_fiber -> Eio_unix.run_in_systhread ~label:"metric-identity-publication" publish

let bind_document config ~directory ~path ~contents ~validate =
  let read () = read_document_opt config path |> Result.map_error (record_source_error path) in
  let check bytes = validate bytes |> Result.map_error (fun message -> Metric_store_failure {path;message}) in
  let* prior = read () in
  match prior with
  | Some bytes -> check bytes
  | None ->
      let* inventory = read_inventory config directory |> Result.map_error (record_source_error directory) in
      let* () = match inventory with
        | None | Some [] -> Ok ()
        | Some (_ :: _) ->
            (* Another initializer may have published after our first read.
               Only a complete, matching binding can admit this inventory. *)
            let* current = read () in
            (match current with
             | Some bytes -> check bytes
             | None -> Error (Metric_store_failure {path;message="nonempty metric storage has no identity binding"})) in
      publish_document ~directory ~path ~contents;
      let* current = read () in
      match current with
      | Some bytes -> check bytes
      | None -> Error (Metric_store_failure {path;message="published metric identity disappeared"})

let prepare_directory config path =
  match Keeper_fs_durable_directory.ensure ~before_prepare:(fun () -> ())
    ~before_directory_fsync:(fun _ -> ()) ~ownership_root:(Workspace_utils.masc_dir config) path with
  | Ok _ -> Ok ()
  | Error (Operation_failed (error, backtrace)) -> Printexc.raise_with_backtrace error backtrace
  | Error (Directory_chain_failed failure) ->
      let path, message = match failure with
        | Non_directory_ancestor {path} -> path, "metric ancestor is not a directory"
        | Outside_ownership_root {ownership_root;path} -> path, "metric path is outside " ^ ownership_root
        | Missing_root {path} -> path, "metric ownership root is absent"
        | Creation_not_observed {path} -> path, "metric directory creation was not observed" in
      Error (Metric_store_failure {path;message})

let prepare_identity config agent_id =
  let root = metrics_dir config in
  let* () = prepare_directory config root in
  let* () = bind_document config ~directory:root ~path:(store_document config)
    ~contents:(Yojson.Safe.to_string (`Assoc ["schema", `String store_schema])) ~validate:check_store_document in
  let directory = agent_metrics_dir config agent_id in
  let* () = prepare_directory config directory in
  bind_document config ~directory ~path:(identity_document config agent_id)
    ~contents:(Yojson.Safe.to_string (`Assoc ["schema", `String identity_schema; "agent_id", `String agent_id]))
    ~validate:(fun bytes ->
      let* observed = parse_identity_document bytes in
      if String.equal observed agent_id then Ok () else Error "metric identity binding conflict")

let append_bound config ~agent_id file bytes =
  let* bound = check_store_layout config |> Result.map_error (record_source_error file) in
  let* () = if bound then Ok () else Error (Metric_store_failure {path=file;message="metric store binding disappeared"}) in
  let* () = check_agent_identity config agent_id |> Result.map_error (record_source_error file) in
  Fs_compat.append_file file bytes;
  Ok ()

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

type write_entry = { config: config; agent_id: string; file: string; line: string }

let write_queue : write_entry Eio.Stream.t = Eio.Stream.create 256

let queue_active = Atomic.make false

(** Bind the exact store/agent identity, then admit a queue entry or append.
    Metadata preparation performs I/O even when the metric body is queued. *)
let record config (metric : task_metric) =
  if not (valid_agent_id metric.agent_id) then Error (Invalid_metric_identity metric.agent_id)
  else
    let directory = agent_metrics_dir config metric.agent_id in
    expected_io directory (fun () ->
      let* () = prepare_identity config metric.agent_id in
      let file = current_month_file config metric.agent_id in
      let line = Yojson.Safe.to_string (task_metric_to_yojson metric) ^ "\n" in
      if Atomic.get queue_active then (
        Eio.Stream.add write_queue {config;agent_id=metric.agent_id;file;line};
        Ok Enqueued)
      else
        let* () = append_bound config ~agent_id:metric.agent_id file line in
        Ok Written)

(** Drain all pending entries from the write queue, batching by file. *)
let flush_pending () =
  let batch = Hashtbl.create 8 in
  let rec drain () =
    match Eio.Stream.take_nonblocking write_queue with
    | None -> ()
    | Some entry ->
        let config, agent_id, buffer = match Hashtbl.find_opt batch entry.file with
          | Some batch -> batch
          | None -> entry.config, entry.agent_id, Buffer.create 256 in
        Buffer.add_string buffer entry.line;
        Hashtbl.replace batch entry.file (config, agent_id, buffer);
        drain ()
  in
  drain ();
  Hashtbl.iter (fun file (config, agent_id, buffer) ->
    match expected_io file (fun () -> append_bound config ~agent_id file (Buffer.contents buffer)) with
    | Ok () -> ()
    | Error error -> Log.Metrics.error "flush_pending: %s" (record_error_to_string error)
    | exception (Eio.Cancel.Cancelled _ as error) -> raise error
    | exception error ->
        Log.Metrics.error "flush_pending: %s: %s" file (Printexc.to_string error)
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
    let* bound = check_store_layout config in
    let* inventory = if bound then read_inventory config dir else Ok None in
    let* () = match inventory with
      | None -> Ok ()
      | Some _ -> check_agent_identity config agent_id in
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
  let* inventory = read_store_inventory config in
  let rec directories acc = function
    | [] -> Ok (List.sort_uniq String.compare acc)
    | name :: rest ->
        let path = Filename.concat dir name in
        (match Fs_compat.exact_path_kind ~follow:false path with
         | Exact_kind Unix.S_DIR ->
             let* agent_id = read_agent_identity config ~directory:path in
             directories (agent_id :: acc) rest
         | Exact_kind (Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK) ->
             directories acc rest
         | Exact_kind Unix.S_LNK | Exact_missing | Exact_unknown ->
             Error (Source_unavailable { path; message = "metric directory identity unavailable" }))
  in
  match inventory with None -> Ok [] | Some names -> directories [] names
