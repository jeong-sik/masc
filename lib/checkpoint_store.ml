(** Checkpoint Store - Persistence for long-running chain executions

    Enables checkpoint/resume for chains that may be interrupted or need
    to continue across sessions. Checkpoints are stored as JSON files
    in ~/.cache/masc/checkpoints/

    Key features:
    - Save checkpoint after each node completes
    - Resume from any checkpoint by run_id
    - List checkpoints for a specific chain
    - Cleanup old checkpoints

    Uses Eio for file I/O operations.
*)

(* Fiber-safe random state for run ID generation *)
let checkpoint_rng = Random.State.make_self_init ()

(** Token usage tracking - re-exported from Chain_category *)
type token_usage = Chain_category.token_usage

(** A single checkpoint capturing execution state *)
type checkpoint = {
  run_id: string;           (** Unique identifier for this execution run *)
  chain_id: string;         (** Chain definition identifier *)
  node_id: string;          (** Last completed node ID *)
  outputs: (string * string) list;  (** Node outputs accumulated so far *)
  traces: Chain_types.trace_entry list;  (** Execution traces *)
  timestamp: float;         (** Unix timestamp when checkpoint was created *)
  total_tokens: token_usage option;  (** Accumulated token usage *)
}

(** Checkpoint store configuration *)
type checkpoint_store = {
  base_dir: string;  (** Base directory for checkpoint files *)
}

(** Default checkpoint directory *)
let default_base_dir () =
  match Env_config.Chain.Paths.checkpoint_dir_opt () with
  | Some path -> path
  | None ->
      let home =
        match Env_config_core.home_dir_opt () with
        | Some h -> h
        | None -> "/tmp"
      in
      Filename.concat home ".cache/masc/checkpoints"

(** Create a new checkpoint store *)
let create ?(base_dir = default_base_dir ()) () =
  { base_dir }

(** Ensure the checkpoint directory exists *)
let ensure_dir path =
  Fs_compat.mkdir_p path

(** Generate a unique run ID *)
let generate_run_id () =
  let timestamp = Time_compat.now () in
  let random = Random.State.int checkpoint_rng 0xFFFF in
  Printf.sprintf "%d_%04x" (int_of_float (timestamp *. 1000.0)) random

(** Get the file path for a checkpoint *)
let checkpoint_path store run_id =
  Filename.concat store.base_dir (run_id ^ ".json")

(** Convert checkpoint to JSON *)
let checkpoint_to_json (cp : checkpoint) : Yojson.Safe.t =
  let outputs_json = `Assoc (List.map (fun (k, v) -> (k, `String v)) cp.outputs) in
  let traces_json = `List (List.map Chain_types.trace_entry_to_yojson cp.traces) in
  let tokens_json = match cp.total_tokens with
    | None -> `Null
    | Some t -> Chain_category.token_usage_to_yojson t
  in
  `Assoc [
    ("run_id", `String cp.run_id);
    ("chain_id", `String cp.chain_id);
    ("node_id", `String cp.node_id);
    ("outputs", outputs_json);
    ("traces", traces_json);
    ("timestamp", `Float cp.timestamp);
    ("total_tokens", tokens_json);
  ]

(** Parse checkpoint from JSON *)
let checkpoint_of_json (json : Yojson.Safe.t) : (checkpoint, string) result =
  let open Yojson.Safe.Util in
  try
    let run_id = json |> member "run_id" |> to_string in
    let chain_id = json |> member "chain_id" |> to_string in
    let node_id = json |> member "node_id" |> to_string in
    let outputs =
      json |> member "outputs" |> to_assoc
      |> List.map (fun (k, v) -> (k, to_string v))
    in
    let traces =
      json |> member "traces" |> to_list
      |> List.filter_map (fun t ->
          match Chain_types.trace_entry_of_yojson t with
          | Ok entry -> Some entry
          | Error _ -> None)
    in
    let timestamp = json |> member "timestamp" |> to_float in
    let total_tokens =
      let t = json |> member "total_tokens" in
      if t = `Null then None
      else match Chain_category.token_usage_of_yojson t with
        | Ok usage -> Some usage
        | Error _ -> None
    in
    Ok { run_id; chain_id; node_id; outputs; traces; timestamp; total_tokens }
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Error (Printf.sprintf "Failed to parse checkpoint: %s" (Printexc.to_string exn))

(** Save a checkpoint to disk using Eio *)
let save_eio ~fs (store : checkpoint_store) (cp : checkpoint) : (unit, string) result =
  try
    ensure_dir store.base_dir;
    let path = checkpoint_path store cp.run_id in
    let json = checkpoint_to_json cp in
    let content = Yojson.Safe.pretty_to_string json in
    let file_path = Eio.Path.(fs / path) in
    Eio.Path.save ~create:(`Or_truncate 0o644) file_path content;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error (Printf.sprintf "Failed to save checkpoint: %s" (Printexc.to_string exn))

(** Save a checkpoint (non-Eio version for compatibility) *)
let save (store : checkpoint_store) (cp : checkpoint) : (unit, string) result =
  try
    ensure_dir store.base_dir;
    let path = checkpoint_path store cp.run_id in
    let json = checkpoint_to_json cp in
    let content = Yojson.Safe.pretty_to_string json in
    Out_channel.with_open_bin path (fun oc ->
      output_string oc content
    );
    Ok ()
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Error (Printf.sprintf "Failed to save checkpoint: %s" (Printexc.to_string exn))

(** Load a checkpoint from disk using Eio *)
let load_eio ~fs (store : checkpoint_store) ~run_id : (checkpoint, string) result =
  let path = checkpoint_path store run_id in
  let file_path = Eio.Path.(fs / path) in
  try
    let content = Eio.Path.load file_path in
    let json = Yojson.Safe.from_string content in
    checkpoint_of_json json
  with
  | Eio.Io _ -> Error (Printf.sprintf "Checkpoint not found: %s" run_id)
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printf.sprintf "Failed to load checkpoint: %s" (Printexc.to_string exn))

(** Load a checkpoint (non-Eio version) *)
let load (store : checkpoint_store) ~run_id : (checkpoint, string) result =
  let path = checkpoint_path store run_id in
  try
    let content =
      In_channel.with_open_bin path (fun ic ->
        really_input_string ic (in_channel_length ic))
    in
    let json = Yojson.Safe.from_string content in
    checkpoint_of_json json
  with
  | Sys_error _ -> Error (Printf.sprintf "Checkpoint not found: %s" run_id)
  | exn -> Error (Printf.sprintf "Failed to load checkpoint: %s" (Printexc.to_string exn))

(** List all checkpoints for a specific chain *)
let list_checkpoints (store : checkpoint_store) ~chain_id : checkpoint list =
  ensure_dir store.base_dir;
  try
    let entries = Sys.readdir store.base_dir |> Array.to_list in
    entries
    |> List.filter (fun name -> Filename.check_suffix name ".json")
    |> List.filter_map (fun name ->
        let run_id = Filename.chop_suffix name ".json" in
        match load store ~run_id with
        | Ok cp when cp.chain_id = chain_id -> Some cp
        | _ -> None)
    |> List.sort (fun a b -> compare b.timestamp a.timestamp)  (* newest first *)
  with Sys_error _ -> []

(** List all checkpoints *)
let list_all (store : checkpoint_store) : checkpoint list =
  ensure_dir store.base_dir;
  try
    let entries = Sys.readdir store.base_dir |> Array.to_list in
    entries
    |> List.filter (fun name -> Filename.check_suffix name ".json")
    |> List.filter_map (fun name ->
        let run_id = Filename.chop_suffix name ".json" in
        match load store ~run_id with
        | Ok cp -> Some cp
        | Error _ -> None)
    |> List.sort (fun a b -> compare b.timestamp a.timestamp)  (* newest first *)
  with Sys_error _ -> []

(** Delete a checkpoint *)
let delete (store : checkpoint_store) ~run_id : unit =
  let path = checkpoint_path store run_id in
  try Sys.remove path with Sys_error _ -> ()

(** Cleanup checkpoints older than max_age_hours, returns count of deleted *)
let cleanup_old (store : checkpoint_store) ~max_age_hours : int =
  let now = Time_compat.now () in
  let max_age_seconds = float_of_int max_age_hours *. 3600.0 in
  let all = list_all store in
  let old_checkpoints = List.filter (fun cp ->
    now -. cp.timestamp > max_age_seconds
  ) all in
  List.iter (fun cp -> delete store ~run_id:cp.run_id) old_checkpoints;
  List.length old_checkpoints

(** Create a checkpoint from execution state *)
let make_checkpoint
    ~run_id
    ~chain_id
    ~node_id
    ~outputs
    ~traces
    ?total_tokens
    () : checkpoint =
  {
    run_id;
    chain_id;
    node_id;
    outputs;
    traces;
    timestamp = Time_compat.now ();
    total_tokens;
  }
