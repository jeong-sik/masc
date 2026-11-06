module Objects = Agent_core.Checkpoint_objects
open Keeper_checkpoint_store_history_files
open Keeper_checkpoint_store_decode
open Keeper_checkpoint_store_summary
open Keeper_checkpoint_store_lineage

type read_use =
  | Read_only
  | Read_for_save of string  (** the Keeper that saves this lineage next *)

let load_agent_core_as ~read_use ~(session_dir : string) ~(session_id : string) :
    (Agent_core.Checkpoint.t, checkpoint_load_error) result =
  (* Absence comes from [read_checkpoint_bytes]'s typed owned-file read, not
     [file_exists], whose boolean also covers stat failures. An unreadable
     existing checkpoint must not become a fresh Keeper history.
     One read path for Eio and non-Eio contexts: [read_checkpoint_bytes]
     reads on a system thread when the fs capability is installed, and the
     decode is routed off the calling fiber (#25077). A [session_id] that is
     not one real path segment (empty, a separator, NUL) is a
     [Store_error]. *)
  if not (leaf_is_real_segment session_id) then
    Error (Store_error "session_id is not a real path segment")
  else
  let path = agent_core_checkpoint_path ~session_dir ~session_id in
  let identity_before = canonical_identity_opt path in
  match
    Option.bind identity_before (fun identity ->
      reusable_written_value ~canonical_path:path ~identity)
  with
  | Some checkpoint -> Ok checkpoint
  | None ->
    try
      match read_checkpoint_bytes ~session_dir path with
      | Error e -> Error e
      | Ok bytes ->
        let memo = Objects.create_memo () in
        (match decode_head_off_scheduler ~session_dir ~memo bytes with
         | Error e -> Error (classify_objects_error e)
         | Ok (head, ckpt) ->
           publish_summary_after_parse ~canonical_path:path ~identity_before ~objects:Objects_seen head;
           (match read_use with
            | Read_only -> Ok ckpt
            | Read_for_save keeper_name ->
              keep_read_lineage ~canonical_path:path ~identity_before ~memo ~keeper_name ckpt;
              Ok (handed_out ckpt)))
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | Unix.Unix_error (errno, _, _) as exn ->
      Error (Read_failed { cause = Os_error errno; detail = Printexc.to_string exn })
    | exn -> Error (Read_failed { cause = Read_raised; detail = Printexc.to_string exn })

type turn_history =
  | Saved_history of Agent_core.Checkpoint.t
  | No_saved_history
  | Saved_history_superseded of { expected : int; got : int }

let turn_history_of_load = function
  | Ok checkpoint -> Ok (Saved_history checkpoint)
  | Error Not_found -> Ok No_saved_history
  | Error (Superseded_version { expected; got }) ->
    Ok (Saved_history_superseded { expected; got })
  | Error
      ( ( Store_error _
        | Parse_error _
        | Newer_version _
        | Io_error _
        | Read_failed _
        | Agent_core_error _
        | Objects_invalid _ ) as error ) -> Error error
;;

let load_agent_core ~session_dir ~session_id =
  load_agent_core_as ~read_use:Read_only ~session_dir ~session_id

let load_agent_core_for_save ~keeper_name ~session_dir ~session_id =
  load_agent_core_as ~read_use:(Read_for_save keeper_name) ~session_dir ~session_id

(** Message count of the canonical checkpoint. Answered from the canonical
    summary while the file on disk is the one the summary was taken from;
    otherwise from the head on disk, with no object read (RFC-0476 §3.5).
    [Ok None] when there is no checkpoint. *)
let canonical_message_count ~(session_dir : string) ~(session_id : string)
  : (int option, checkpoint_load_error) result =
  if not (leaf_is_real_segment session_id) then
    Error (Store_error "session_id is not a real path segment")
  else
    let canonical_path = agent_core_checkpoint_path ~session_dir ~session_id in
    match cached_summary ~canonical_path with
    | Some summary -> Ok (Some summary.summary_message_count)
    | None ->
      (match
         protect_summary_read ~on_exception:canonical_read_exception (fun () ->
           let identity_before = canonical_identity_opt canonical_path in
           Result.bind (read_checkpoint_bytes ~session_dir canonical_path) (fun bytes ->
             head_of_bytes_off_scheduler bytes
             |> Result.map_error classify_objects_error
             |> Result.map (fun head ->
                  publish_summary_after_parse ~canonical_path ~identity_before
                    ~objects:Objects_unchecked head;
                  head)))
       with
       | Ok head -> Ok (Some (Objects.message_count head.history))
       | Error Not_found -> Ok None
       | Error
           (( Store_error _
            | Parse_error _
            | Superseded_version _
            | Newer_version _
            | Io_error _
            | Read_failed _
            | Agent_core_error _
            | Objects_invalid _ ) as error) -> Error error)

let canonical_byte_count ~(session_dir : string) ~(session_id : string)
  : (int option, checkpoint_load_error) result =
  if not (leaf_is_real_segment session_id) then
    Error (Store_error "session_id is not a real path segment")
  else
    let canonical_path = agent_core_checkpoint_path ~session_dir ~session_id in
    match cached_summary ~canonical_path with
    | Some summary -> Ok (Some summary.identity.size)
    | None ->
      (match Unix.stat canonical_path with
       | stats when stats.Unix.st_kind = Unix.S_REG -> Ok (Some stats.Unix.st_size)
       | _ -> Error (Store_error "canonical checkpoint is not a regular file")
       | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
       | exception Unix.Unix_error (code, _, _) ->
         Error
           (Store_error
              ("canonical checkpoint stat failed: " ^ Unix.error_message code)))
