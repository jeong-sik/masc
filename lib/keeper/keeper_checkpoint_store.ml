(** Keeper_checkpoint_store — checkpoint file I/O.

    Handles saving, loading, listing, and pruning checkpoint JSON files
    within a session directory. Separated from [Keeper_working_context]
    so that file I/O concerns do not mix with context types and
    pure operations.

    @since keeper-ctx-split *)

open Printf

(* ================================================================ *)
(* Checkpoint File Conventions                                        *)
(* ================================================================ *)

let checkpoint_prefix = "ckpt-"
let checkpoint_suffix = ".json"

let is_checkpoint_file (filename : string) : bool =
  let len = String.length filename in
  len > String.length checkpoint_prefix + String.length checkpoint_suffix
  && String.sub filename 0 (String.length checkpoint_prefix) = checkpoint_prefix
  && String.sub filename (len - String.length checkpoint_suffix)
       (String.length checkpoint_suffix) = checkpoint_suffix

(* ================================================================ *)
(* List                                                               *)
(* ================================================================ *)

let list_checkpoints ~(session_dir : string) : string list =
  if not (Sys.file_exists session_dir) then []
  else
    Sys.readdir session_dir
    |> Array.to_list
    |> List.filter is_checkpoint_file
    |> List.sort (fun a b -> compare b a)

(** Maximum number of checkpoint files to retain per session.
    Only the latest N are kept; older ones are deleted after each save. *)
let max_checkpoints_retained = 3

(* ================================================================ *)
(* Prune                                                              *)
(* ================================================================ *)

let prune ~(session_dir : string) ~(keep : int) : int =
  let files = list_checkpoints ~session_dir in
  if List.length files <= keep then 0
  else
    let to_remove = List.filteri (fun i _ -> i >= keep) files in
    List.iter (fun filename ->
      let path = Filename.concat session_dir filename in
      (try Sys.remove path
       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
         Log.Keeper.warn "checkpoint cleanup failed for %s: %s"
           path (Printexc.to_string exn)))
      to_remove;
    List.length to_remove

(* ================================================================ *)
(* Save                                                               *)
(* ================================================================ *)

let save
    ~(session_dir : string)
    (ckpt : Keeper_working_context.checkpoint) : unit =
  let path = Filename.concat session_dir
    (sprintf "%s%s" ckpt.checkpoint_id checkpoint_suffix) in
  let context_json =
    try Yojson.Safe.from_string ckpt.serialized
    with Eio.Cancel.Cancelled _ as e -> raise e | _ -> `String ckpt.serialized
  in
  let json = `Assoc [
    ("checkpoint_id", `String ckpt.checkpoint_id);
    ("timestamp", `Float ckpt.timestamp);
    ("generation", `Int ckpt.generation);
    ("message_count", `Int ckpt.message_count);
    ("token_count", `Int ckpt.token_count);
    ("context", context_json);
  ] in
  let content = Yojson.Safe.to_string json in
  Keeper_fs.save_atomic path content;
  (* Auto-prune old checkpoints after each save *)
  ignore (prune ~session_dir ~keep:max_checkpoints_retained)

(* ================================================================ *)
(* Load Latest                                                        *)
(* ================================================================ *)

let parse_checkpoint_file (path : string) : Keeper_working_context.checkpoint =
  let content = Fs_compat.load_file path in
  let json =
    content
    |> Inference_utils.sanitize_text_utf8
    |> Yojson.Safe.from_string
  in
  let open Yojson.Safe.Util in
  let serialized =
    try
      let ctx = json |> member "context" in
      if ctx = `Null then raise Not_found;
      Yojson.Safe.to_string ctx
    with Eio.Cancel.Cancelled _ as e -> raise e | _ ->
      json |> member "serialized" |> to_string
  in
  {
    Keeper_working_context.checkpoint_id =
      json |> member "checkpoint_id" |> to_string;
    timestamp = json |> member "timestamp" |> to_number;
    generation = json |> member "generation" |> to_int;
    message_count = json |> member "message_count" |> to_int;
    token_count = json |> member "token_count" |> to_int;
    serialized;
  }

let load_latest ~(session_dir : string) : Keeper_working_context.checkpoint option =
  match list_checkpoints ~session_dir with
  | [] -> None
  | latest :: _ ->
    let path = Filename.concat session_dir latest in
    (try Some (parse_checkpoint_file path)
     with Eio.Cancel.Cancelled _ as e -> raise e | _ -> None)

(* ================================================================ *)
(* OAS Checkpoint Compatibility                                      *)
(* ================================================================ *)

let oas_checkpoint_path ~(session_dir : string) ~(session_id : string) =
  Filename.concat session_dir (session_id ^ ".json")

(* ================================================================ *)
(* Delta Checkpoint Integration                                      *)
(* ================================================================ *)

(** Track delta chain length for a session.
    Returns (chain_length, last_full_checkpoint_id option) *)
let get_delta_chain_info ~(session_dir : string) : (int * string option) =
  match list_checkpoints ~session_dir with
  | [] -> (0, None)
  | latest :: rest ->
    (* Walk backwards counting deltas until we hit a full checkpoint *)
    let rec count_deltas acc checkpoint_files =
      match checkpoint_files with
      | [] -> (acc, None)
      | filename :: remaining ->
        let checkpoint_id =
          let prefix_len = String.length checkpoint_prefix in
          let suffix_len = String.length checkpoint_suffix in
          let total_len = String.length filename in
          String.sub filename prefix_len (total_len - prefix_len - suffix_len)
        in
        (* Try to load as delta checkpoint *)
        (match Keeper_checkpoint_delta.load_delta ~session_dir ~checkpoint_id with
         | None ->
           (* Not a delta - must be full checkpoint *)
           (acc, Some checkpoint_id)
         | Some delta ->
           match delta.base_checkpoint_id with
           | None -> (acc, Some checkpoint_id)  (* Delta with no base = treat as full *)
           | Some _ -> count_deltas (acc + 1) remaining)
    in
    count_deltas 0 (latest :: rest)

(** Save checkpoint, using delta format if enabled and appropriate. *)
let save_with_delta_support
    ~(session_dir : string)
    ~(prev_ckpt : Keeper_working_context.checkpoint option)
    ~(ctx : Keeper_working_context.working_context)
    ~(generation : int) : Keeper_working_context.checkpoint =
  let delta_enabled = Env_config_keeper.DeltaCheckpoint.enabled in

  if not delta_enabled then
    (* Delta disabled - save as full checkpoint *)
    let ckpt = Keeper_working_context.create_checkpoint ctx ~generation in
    save ~session_dir ckpt;
    ckpt
  else
    (* Delta enabled - check if we should use delta *)
    let (chain_length, _last_full_id) = get_delta_chain_info ~session_dir in
    let max_chain = Env_config_keeper.DeltaCheckpoint.max_chain_length in

    let should_use_delta =
      Keeper_checkpoint_delta.should_use_delta
        ~prev_ckpt
        ~current_messages:ctx.messages
        ~delta_chain_length:chain_length
    in

    if should_use_delta && chain_length < max_chain then
      (match prev_ckpt with
       | None ->
         (* No previous checkpoint - save as full *)
         let ckpt = Keeper_working_context.create_checkpoint ctx ~generation in
         save ~session_dir ckpt;
         ckpt
       | Some base_ckpt ->
         (* Save as delta checkpoint *)
         let checkpoint_id = Keeper_working_context.generate_checkpoint_id () in
         let delta =
           Keeper_checkpoint_delta.create_delta_checkpoint
             ~checkpoint_id
             ~base_ckpt
             ~ctx
             ~generation
         in
         Keeper_checkpoint_delta.save_delta ~session_dir delta;

         (* Also create a regular checkpoint structure for compatibility *)
         {
           Keeper_working_context.checkpoint_id;
           timestamp = delta.timestamp;
           generation = delta.generation;
           message_count = delta.total_message_count;
           token_count = delta.total_token_count;
           serialized = Keeper_working_context.serialize_context ctx;
         })
    else
      (* Chain too long or other conditions - save as full checkpoint *)
      let ckpt = Keeper_working_context.create_checkpoint ctx ~generation in
      save ~session_dir ckpt;
      ckpt

(** Load latest checkpoint, reconstructing from delta chain if needed. *)
let load_latest_with_delta_support
    ~(session_dir : string)
    ~(max_tokens : int) : Keeper_working_context.working_context option =
  let delta_enabled = Env_config_keeper.DeltaCheckpoint.enabled in

  match list_checkpoints ~session_dir with
  | [] -> None
  | latest_filename :: _ ->
    let checkpoint_id =
      let prefix_len = String.length checkpoint_prefix in
      let suffix_len = String.length checkpoint_suffix in
      let total_len = String.length latest_filename in
      String.sub latest_filename prefix_len (total_len - prefix_len - suffix_len)
    in

    if not delta_enabled then
      (* Delta disabled - load as full checkpoint *)
      (match load_latest ~session_dir with
       | None -> None
       | Some ckpt ->
         Some (Keeper_working_context.restore_checkpoint ckpt ~max_tokens))
    else
      (* Delta enabled - try to load as delta chain *)
      (match Keeper_checkpoint_delta.discover_delta_chain
               ~session_dir ~latest_checkpoint_id:checkpoint_id with
       | None ->
         (* Not a delta chain - load as full checkpoint *)
         (match load_latest ~session_dir with
          | None -> None
          | Some ckpt ->
            Some (Keeper_working_context.restore_checkpoint ckpt ~max_tokens))
       | Some chain ->
         (* Reconstruct from delta chain *)
         let stats = Keeper_checkpoint_delta.compute_chain_stats chain in
         Log.Keeper.info "Loading checkpoint from delta chain: %s" stats;
         Keeper_checkpoint_delta.reconstruct_from_deltas
           ~base:chain.base
           ~deltas:chain.deltas
           ~max_tokens)

let save_oas_error (detail : string) =
  Sys_error (Printf.sprintf "save_oas: %s" detail)

let save_oas ~(session_dir : string) (ckpt : Agent_sdk.Checkpoint.t) : unit =
  try
    ignore (Keeper_fs.ensure_dir session_dir);
    match Fs_compat.get_fs_opt () with
    | Some fs ->
        let dir = Eio.Path.(fs / session_dir) in
        (match Agent_sdk.Checkpoint_store.create dir with
         | Ok store -> (
             match Agent_sdk.Checkpoint_store.save store ckpt with
             | Ok () -> ()
             | Error err ->
                 raise (save_oas_error (Agent_sdk.Error.to_string err)))
         | Error err ->
             raise (save_oas_error (Agent_sdk.Error.to_string err)))
    | None ->
        Keeper_fs.save_atomic
          (oas_checkpoint_path ~session_dir ~session_id:ckpt.session_id)
          (Agent_sdk.Checkpoint.to_string ckpt)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Sys_error _ as e -> raise e
  | exn -> raise (save_oas_error (Printexc.to_string exn))

let load_oas ~(session_dir : string) ~(session_id : string) :
    Agent_sdk.Checkpoint.t option =
  match Fs_compat.get_fs_opt () with
  | Some fs ->
      let dir = Eio.Path.(fs / session_dir) in
      (match Agent_sdk.Checkpoint_store.create dir with
       | Ok store -> (
           match Agent_sdk.Checkpoint_store.load store session_id with
           | Ok ckpt -> Some ckpt
           | Error _ -> None)
       | Error _ -> None)
  | None ->
      let path = oas_checkpoint_path ~session_dir ~session_id in
      if Sys.file_exists path then
        try
          match Agent_sdk.Checkpoint.of_string (Fs_compat.load_file path) with
          | Ok ckpt -> Some ckpt
          | Error _ -> None
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | _ -> None
      else None
