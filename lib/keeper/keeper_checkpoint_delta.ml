(** Keeper_checkpoint_delta — Delta-based checkpoint storage and retrieval.

    Enables incremental checkpoint storage by tracking only message deltas
    since the last checkpoint, reducing I/O and storage costs for long-running
    keeper sessions.

    Delta checkpoint format:
    - base_checkpoint_id: Reference to base checkpoint containing full context
    - new_messages: Only messages added since base checkpoint
    - message_offset: Index of first new message in full history
    - incremental_token_count: Tokens added since base

    On restore:
    1. Load base checkpoint (full context)
    2. Apply delta messages on top
    3. Recompute token counts

    @since delta-context-optimization *)

open Printf

(* ================================================================ *)
(* Delta Checkpoint Types                                            *)
(* ================================================================ *)

type delta_checkpoint = {
  checkpoint_id : string;
  base_checkpoint_id : string option;  (* None = full checkpoint *)
  timestamp : float;
  generation : int;
  message_offset : int;  (* Index of first new message in full history *)
  new_messages : Agent_sdk.Types.message list;
  incremental_token_count : int;
  total_message_count : int;  (* Total after applying delta *)
  total_token_count : int;  (* Total after applying delta *)
}

type delta_chain = {
  base : Keeper_working_context.checkpoint;
  deltas : delta_checkpoint list;
}

(* ================================================================ *)
(* Delta Configuration                                               *)
(* ================================================================ *)

(** Maximum number of deltas before forcing a new full checkpoint.
    Prevents unbounded delta chains that would slow restore. *)
let max_delta_chain_length = 5

(** Minimum messages in a checkpoint to enable delta mode.
    Small checkpoints are not worth delta optimization. *)
let min_messages_for_delta = 3

(* ================================================================ *)
(* Delta Checkpoint Creation                                         *)
(* ================================================================ *)

let should_use_delta
    ~(prev_ckpt : Keeper_working_context.checkpoint option)
    ~(current_messages : Agent_sdk.Types.message list)
    ~(delta_chain_length : int) : bool =
  match prev_ckpt with
  | None -> false  (* First checkpoint must be full *)
  | Some prev ->
    (* Enable delta if:
       1. Previous checkpoint exists
       2. Current message count meets minimum
       3. Delta chain not too long
       4. Actually have new messages *)
    prev.message_count >= min_messages_for_delta &&
    List.length current_messages > prev.message_count &&
    delta_chain_length < max_delta_chain_length

let create_delta_checkpoint
    ~(checkpoint_id : string)
    ~(base_ckpt : Keeper_working_context.checkpoint)
    ~(ctx : Keeper_working_context.working_context)
    ~(generation : int) : delta_checkpoint =
  let message_offset = base_ckpt.message_count in
  let new_messages =
    let rec drop n lst =
      match n, lst with
      | 0, _ -> lst
      | _, [] -> []
      | n, _ :: rest -> drop (n - 1) rest
    in
    drop base_ckpt.message_count ctx.messages
  in
  let incremental_token_count =
    List.fold_left (fun acc msg ->
      acc + Keeper_working_context.msg_tokens msg
    ) 0 new_messages
  in
  {
    checkpoint_id;
    base_checkpoint_id = Some base_ckpt.checkpoint_id;
    timestamp = Time_compat.now ();
    generation;
    message_offset;
    new_messages;
    incremental_token_count;
    total_message_count = List.length ctx.messages;
    total_token_count = ctx.token_count;
  }

(* ================================================================ *)
(* Delta Serialization                                               *)
(* ================================================================ *)

let delta_to_json (delta : delta_checkpoint) : Yojson.Safe.t =
  `Assoc [
    ("checkpoint_id", `String delta.checkpoint_id);
    ("base_checkpoint_id",
     match delta.base_checkpoint_id with
     | Some id -> `String id
     | None -> `Null);
    ("timestamp", `Float delta.timestamp);
    ("generation", `Int delta.generation);
    ("message_offset", `Int delta.message_offset);
    ("new_messages", `List (List.map Keeper_working_context.message_to_json delta.new_messages));
    ("incremental_token_count", `Int delta.incremental_token_count);
    ("total_message_count", `Int delta.total_message_count);
    ("total_token_count", `Int delta.total_token_count);
    ("format_version", `String "delta-v1");
  ]

let delta_of_json (json : Yojson.Safe.t) : delta_checkpoint =
  let open Yojson.Safe.Util in
  {
    checkpoint_id = json |> member "checkpoint_id" |> to_string;
    base_checkpoint_id = json |> member "base_checkpoint_id" |> to_string_option;
    timestamp = json |> member "timestamp" |> to_number;
    generation = json |> member "generation" |> to_int;
    message_offset = json |> member "message_offset" |> to_int;
    new_messages =
      json |> member "new_messages" |> to_list
      |> List.map Keeper_working_context.message_of_json;
    incremental_token_count = json |> member "incremental_token_count" |> to_int;
    total_message_count = json |> member "total_message_count" |> to_int;
    total_token_count = json |> member "total_token_count" |> to_int;
  }

(* ================================================================ *)
(* Delta File I/O                                                    *)
(* ================================================================ *)

let delta_checkpoint_path ~(session_dir : string) ~(checkpoint_id : string) =
  Filename.concat session_dir (sprintf "delta-%s.json" checkpoint_id)

let save_delta ~(session_dir : string) (delta : delta_checkpoint) : unit =
  let path = delta_checkpoint_path ~session_dir ~checkpoint_id:delta.checkpoint_id in
  let json = delta_to_json delta in
  let content = Yojson.Safe.to_string json in
  Keeper_fs.save_atomic path content

let load_delta ~(session_dir : string) ~(checkpoint_id : string) : delta_checkpoint option =
  let path = delta_checkpoint_path ~session_dir ~checkpoint_id in
  if not (Sys.file_exists path) then None
  else
    try
      let content = Fs_compat.load_file path in
      let json = Yojson.Safe.from_string content in
      Some (delta_of_json json)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Keeper.warn "Failed to load delta checkpoint %s: %s"
        checkpoint_id (Printexc.to_string exn);
      None

(* ================================================================ *)
(* Delta Chain Reconstruction                                        *)
(* ================================================================ *)

(** Reconstruct full context by applying delta chain.
    Returns None if chain is broken (missing base or delta). *)
let reconstruct_from_deltas
    ~(base : Keeper_working_context.checkpoint)
    ~(deltas : delta_checkpoint list)
    ~(max_tokens : int) : Keeper_working_context.working_context option =
  try
    (* Start with base checkpoint context *)
    let base_ctx = Keeper_working_context.restore_checkpoint base ~max_tokens in

    (* Apply each delta in order *)
    let final_ctx =
      List.fold_left (fun ctx delta ->
        (* Verify message offset matches current message count *)
        if List.length ctx.messages <> delta.message_offset then
          failwith (sprintf "Delta offset mismatch: expected %d, got %d"
            delta.message_offset (List.length ctx.messages));

        (* Append new messages *)
        Keeper_working_context.append_many ctx delta.new_messages
      ) base_ctx deltas
    in

    Some final_ctx
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn "Failed to reconstruct from deltas: %s"
      (Printexc.to_string exn);
    None

(* ================================================================ *)
(* Delta Chain Discovery                                             *)
(* ================================================================ *)

(** Find all delta checkpoints in session directory and build dependency map. *)
let discover_delta_chain
    ~(session_dir : string)
    ~(latest_checkpoint_id : string) : delta_chain option =
  (* Load the latest checkpoint (might be delta or full) *)
  let latest_delta_opt =
    load_delta ~session_dir ~checkpoint_id:latest_checkpoint_id
  in

  match latest_delta_opt with
  | None ->
    (* Not a delta checkpoint - try loading as full checkpoint *)
    None
  | Some latest_delta ->
    match latest_delta.base_checkpoint_id with
    | None ->
      (* Delta with no base = corrupted *)
      Log.Keeper.warn "Delta checkpoint %s has no base_checkpoint_id"
        latest_checkpoint_id;
      None
    | Some base_id ->
      (* Walk backwards to find base and intermediate deltas *)
      let rec walk_chain acc current_id =
        match load_delta ~session_dir ~checkpoint_id:current_id with
        | None ->
          (* Not a delta - should be full checkpoint *)
          (match Keeper_checkpoint_store.load_latest ~session_dir with
           | None -> None
           | Some base ->
             if base.checkpoint_id = current_id then
               Some (base, List.rev acc)
             else
               None)
        | Some delta ->
          match delta.base_checkpoint_id with
          | None -> None  (* Corrupted delta *)
          | Some next_base_id ->
            walk_chain (delta :: acc) next_base_id
      in

      (match walk_chain [latest_delta] base_id with
       | Some (base, deltas) ->
         Some { base; deltas }
       | None -> None)

(* ================================================================ *)
(* Delta Metrics                                                     *)
(* ================================================================ *)

let compute_delta_efficiency (delta : delta_checkpoint) : float =
  if delta.total_message_count = 0 then 0.0
  else
    let new_msg_count = List.length delta.new_messages in
    float_of_int new_msg_count /. float_of_int delta.total_message_count

let compute_chain_stats (chain : delta_chain) : string =
  let total_deltas = List.length chain.deltas in
  let total_new_messages =
    List.fold_left (fun acc delta ->
      acc + List.length delta.new_messages
    ) 0 chain.deltas
  in
  let avg_efficiency =
    if total_deltas = 0 then 0.0
    else
      let sum_eff = List.fold_left (fun acc delta ->
        acc +. compute_delta_efficiency delta
      ) 0.0 chain.deltas in
      sum_eff /. float_of_int total_deltas
  in
  sprintf "Delta chain: base=%s, deltas=%d, new_msgs=%d, avg_efficiency=%.2f%%"
    chain.base.checkpoint_id total_deltas total_new_messages (avg_efficiency *. 100.0)
