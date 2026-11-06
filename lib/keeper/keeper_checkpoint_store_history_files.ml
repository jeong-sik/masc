let agent_core_checkpoint_path ~(session_dir : string) ~(session_id : string) =
  Filename.concat session_dir (session_id ^ ".json")

let agent_core_history_prefix = "agent-core-snapshot-"
let agent_core_history_suffix = ".json"

let before_history_link_hook : (unit -> unit) option Atomic.t = Atomic.make None

let archive_created_ms_of_filename (filename : string) : int option =
  let len = String.length filename in
  let prefix_len = String.length agent_core_history_prefix in
  let suffix_len = String.length agent_core_history_suffix in
  let created_ms_digits = 13 in
  if len <> prefix_len + created_ms_digits + suffix_len
     || not (String.starts_with ~prefix:agent_core_history_prefix filename)
     || not (String.ends_with ~suffix:agent_core_history_suffix filename)
  then None
  else
    let raw = String.sub filename prefix_len created_ms_digits in
    if String.for_all (fun char -> Char.compare char '0' >= 0 && Char.compare char '9' <= 0) raw
    then int_of_string_opt raw
    else None
;;

let is_agent_core_history_file ~(session_dir : string) (filename : string) : bool =
  let canonical_filename = Filename.basename session_dir ^ ".json" in
  (not (String.equal filename canonical_filename))
  && Option.is_some (archive_created_ms_of_filename filename)
;;

let list_agent_core_history_files ~(session_dir : string) : string list =
  if not (Fs_compat.file_exists session_dir) then []
  else
    Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
      Sys.readdir session_dir
      |> Array.to_list
      |> List.filter (is_agent_core_history_file ~session_dir)
      |> List.sort (fun a b -> String.compare b a))

(* Each entry is a copy of the head the canonical held (RFC-0476 §3.2), so it
   costs the head's bytes; the objects are shared. The only reader is the
   dashboard checkpoint list, which decodes every retained entry to describe
   it, so the count is also what that request costs.

   Disk and how far back an operator can look pull against each other, and
   which way to lean is theirs to say, so the window is the runtime setting
   [keeper.checkpoint_history_retained] rather than a number a deploy fixed.

   This store does not read it. A setting read can raise (its default is read
   from the environment), and in here it would raise inside the best-effort
   archive wrapper that swallows it, so the prune would stop without ever
   saying so. The caller reads the setting and passes the answer in; the
   stale-guard "raw Domain saves through Unix context" test saves from a raw
   Domain that way. *)

let agent_core_history_path ~(session_dir : string) ~(snapshot_id : string) =
  Filename.concat session_dir snapshot_id

(* A name below the session root ([leaf] of a session_dir, or a
   [snapshot_id] appended by [agent_core_history_path]) must denote exactly one
   directory entry. An empty, ".", ".." or separator-bearing name makes
   [Filename.concat parent name] (and the [^ ".checkpoint.lock"] sibling
   derived from a session location) resolve outside the session root, so
   every downstream consumer would inherit the escape. A NUL byte would
   truncate the path at the syscall boundary, so it is rejected here before
   any filesystem side effect. *)
let leaf_is_real_segment leaf =
  (not (String.equal leaf ""))
  && (not (String.equal leaf Filename.current_dir_name))
  && (not (String.equal leaf Filename.parent_dir_name))
  && not
       (String.exists
          (fun c -> String.contains Filename.dir_sep c || Char.equal c '\000')
          leaf)

let agent_core_history_snapshot_id_of_created_at (created_at : float) : string =
  let created_ms = max 0 (int_of_float (created_at *. 1000.0)) in
  Printf.sprintf "%s%013d%s"
    agent_core_history_prefix created_ms agent_core_history_suffix

let agent_core_history_snapshot_id_of_checkpoint (ckpt : Agent_core.Checkpoint.t) : string =
  agent_core_history_snapshot_id_of_created_at ckpt.created_at

let prune_agent_core_history ~(session_dir : string) ~(retained : int) : unit =
  let files = list_agent_core_history_files ~session_dir in
  if List.length files > retained then
    files
    |> List.filteri (fun index _ -> index >= retained)
    |> List.iter (fun filename ->
         let path = agent_core_history_path ~session_dir ~snapshot_id:filename in
         try
           Eio_guard.run_in_systhread ~label:"keeper.checkpoint.history.unlink"
             (fun () -> Sys.remove path)
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
             Log.Keeper.warn "AGENT_CORE snapshot cleanup failed for %s: %s"
               path (Printexc.to_string exn);
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string CheckpointFailures)
               ~labels:[("site", Keeper_checkpoint_store_failure_site.(to_label Agent_core_cleanup))]
               ())

let hardlink_agent_core_history_from_canonical
    ~(session_dir : string)
    ~(session_id : string)
    ~(snapshot_id : string) : (unit, string) result =
  let canonical_path = agent_core_checkpoint_path ~session_dir ~session_id in
  let snapshot_path = agent_core_history_path ~session_dir ~snapshot_id in
  if not (Fs_compat.file_exists canonical_path) then
    Error "canonical AGENT_CORE checkpoint is missing"
  else
    try
      let snapshot_exists = Fs_compat.file_exists snapshot_path in
      Eio_guard.run_in_systhread ~label:"keeper.checkpoint.history.link" (fun () ->
        Option.iter (fun hook -> hook ()) (Atomic.get before_history_link_hook);
        if snapshot_exists then Sys.remove snapshot_path;
        Unix.link canonical_path snapshot_path);
      Ok ()
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> Error (Printexc.to_string exn)

(* A save-scoped capability is carried to each checkpoint payload writer. It
   observes the pieces actually submitted to a successful canonical write and
   the bytes submitted to a successful archive fallback. A failed archive can
   have a partial effect, so its observation is unknown. *)
module Checkpoint_payload_writer = struct
  type t = Unmeasured | Measured of (int option -> unit)

  let note capability observation =
    match capability with
    | Unmeasured -> ()
    | Measured observe -> observe observation

  let count_pieces pieces =
    List.fold_left (fun total piece ->
      match total with
      | Some bytes when String.length piece <= max_int - bytes -> Some (bytes + String.length piece)
      | Some _ | None -> None) (Some 0) pieces

  let canonical capability ~write ~ownership_root path encode =
    match capability with
    | Unmeasured -> write ~ownership_root path encode
    | Measured observe ->
      let submitted = ref None in
      let result = write ~ownership_root path (fun () ->
        let pieces = encode () in
        submitted := count_pieces pieces;
        pieces) in
      (match result with
       | Ok _ -> observe !submitted
       | Error _ -> ());
      result

  let archive capability path bytes =
    let result = Keeper_fs.save_atomic path bytes in
    (match result with
     | Ok () -> note capability (Some (String.length bytes))
     | Error _ -> note capability None);
    result
end

(* A window of zero keeps nothing, so this writes nothing: the prune would
   delete the entry again on the way out. When the hardlink fails, the head
   bytes are written as the entry instead. *)
let save_agent_core_history
    ~payload_writer ~(session_dir : string) ~(retained : int) ~head_bytes
    (ckpt : Agent_core.Checkpoint.t) : unit =
  if retained <= 0 then prune_agent_core_history ~session_dir ~retained
  else begin
  let snapshot_id = agent_core_history_snapshot_id_of_checkpoint ckpt in
  let save_snapshot_file () =
    Checkpoint_payload_writer.archive payload_writer
      (agent_core_history_path ~session_dir ~snapshot_id) head_bytes
  in
  let save_result =
    match
      hardlink_agent_core_history_from_canonical
        ~session_dir ~session_id:ckpt.session_id ~snapshot_id
    with
    | Ok () -> Ok ()
    | Error _ -> save_snapshot_file ()
  in
  match save_result with
  | Ok () ->
    prune_agent_core_history ~session_dir ~retained
  | Error msg ->
    Log.Keeper.warn "save_agent_core_history failed for %s: %s" snapshot_id msg;
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string CheckpointFailures)
      ~labels:[("site", Keeper_checkpoint_store_failure_site.(to_label Agent_core_save))]
      ()
  end

type history_delete_result =
  | History_deleted of string
  | History_missing of string
  | History_refused of string
  | History_removal_failed of string

let delete_agent_core_history_files ~(session_dir : string) ~(snapshot_ids : string list)
    : history_delete_result list =
  List.map
    (fun snapshot_id ->
      (* The dashboard supplies filenames. Both containment and the same
         archive identity used by listing/pruning must hold before unlink;
         other files in this session are not checkpoint history entries. *)
      if not
           (leaf_is_real_segment snapshot_id
            && is_agent_core_history_file ~session_dir snapshot_id)
      then History_refused snapshot_id
      else
      let path = agent_core_history_path ~session_dir ~snapshot_id in
      if Fs_compat.file_exists path then (
        try
          Sys.remove path;
          History_deleted snapshot_id
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            Log.Keeper.warn "AGENT_CORE snapshot delete failed for %s: %s"
              path (Printexc.to_string exn);
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string CheckpointFailures)
              ~labels:[("site", Keeper_checkpoint_store_failure_site.(to_label Agent_core_delete))]
              ();
            History_removal_failed snapshot_id)
      else
        History_missing snapshot_id)
    snapshot_ids
;;

type history_cleared =
  { removed : int
  ; left : string list
  }

let delete_all_agent_core_history_files ~session_dir =
  match list_agent_core_history_files ~session_dir with
  | exception Sys_error detail -> Error detail
  | snapshot_ids ->
    Ok
      (List.fold_left
         (fun cleared -> function
            | History_deleted _ -> { cleared with removed = cleared.removed + 1 }
            | History_missing _ -> cleared
            | History_refused snapshot_id ->
              { cleared with left = (snapshot_id ^ ": not a history archive name") :: cleared.left }
            | History_removal_failed snapshot_id ->
              { cleared with left = (snapshot_id ^ ": removal failed") :: cleared.left })
         { removed = 0; left = [] }
         (delete_agent_core_history_files ~session_dir ~snapshot_ids)
       |> fun cleared -> { cleared with left = List.rev cleared.left })
;;
