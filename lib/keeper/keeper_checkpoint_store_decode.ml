open Printf
module Objects = Agent_core.Checkpoint_objects
open Keeper_checkpoint_store_history_files

(* Checkpoint payloads serialize to 0.7-1.4MB (see the [~pretty:false] note on
   [Keeper_fs.save_json_durable_atomic]). Encoding or decoding one on the
   calling fiber stalls every other fiber on the single-domain scheduler for
   the whole conversion (issue #25077; same class as the board_attention
   ledger re-parse hangs). Route the pure conversions through
   [Domain_pool_ref.submit_cpu_or_inline] — the typed CPU-weight policy layer
   keeper call sites are documented to prefer over the raw
   [Executor_pool_ref]; it re-raises job exceptions instead of rerunning the
   closure inline on failure, and falls back to inline execution for
   non-Eio callers itself (#25158) — the store is also reachable from raw
   Domains (see the stale-guard "raw Domain saves through Unix context"
   test). *)
let offload_checkpoint_cpu (f : unit -> 'a) : 'a =
  Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ f

let head_of_bytes_off_scheduler (content : string) =
  offload_checkpoint_cpu (fun () -> Objects.head_of_string content)

(* The objects a head names are read and decoded in the same pool job as the
   head (RFC-0476 §3.5). [memo] then holds the loaded messages. *)
let decode_head_off_scheduler ~session_dir ~memo (content : string) :
    (Objects.head * Agent_core.Checkpoint.t, Objects.load_error) result =
  offload_checkpoint_cpu (fun () ->
    match Objects.head_of_string content with
    | Error _ as error -> error
    | Ok head ->
      Objects.load memo ~read_object:(Keeper_checkpoint_object_store.read ~session_dir) head
      |> Result.map (fun checkpoint -> head, checkpoint))

type checkpoint_read_failure =
  | Os_error of Unix.error
  | Changed_while_read
  | Read_raised

type checkpoint_load_error =
  | Not_found
  | Store_error of string
  | Parse_error of string
  (** A canonical this binary recognises as an earlier [checkpoint_version].
      Apart from [Parse_error] because the two need opposite answers: a
      superseded canonical is replaceable, a corrupt one is not. *)
  | Superseded_version of { expected : int; got : int }
  (** A canonical a *later* [checkpoint_version] wrote: an older binary is
      reading a newer workspace. Nothing here replaces or deletes it, because
      the newer binary can still read it. Only a writer that bumped the
      version is told apart this way (#38680). *)
  | Newer_version of { expected : int; got : int }
  | Io_error of string
  | Read_failed of { cause : checkpoint_read_failure; detail : string }
  (** Catch-all for agent-core errors outside the Io / Serialization families
      (Api / Agent / Mcp / Config / Orchestration / Internal).
      Distinct from Io_error so observers can tell a local
      checkpoint-store I/O failure apart from an agent-core failure that
      surfaced during a load. (#8605 family) *)
  | Agent_core_error of string
  | Objects_invalid of Objects.load_error
  (** The head names a message object or bundle that is missing, unreadable
      or not what the head says it is. *)

(* A missing checkpoint never reaches here: [read_checkpoint_bytes]'s typed
   owned-file read decides absence before agent core runs. Every
   [Agent_core.Error.t] seen here is a real I/O, serialization or agent-core
   fault, routed by its variant without reading detail strings, so there is
   no [Not_found] arm. The match names every variant, so a new one is a build
   error that forces a routing decision. *)
let classify_core_error (e : Agent_core.Error.t) : checkpoint_load_error =
  match e with
  | Io (FileOpFailed r) ->
      Io_error (sprintf "file %s failed on %s: %s" r.op r.path r.detail)
  | Io (ValidationFailed r) -> Store_error r.detail
  | Serialization (JsonParseError r) -> Parse_error r.detail
  | Serialization (StructuredOutputParseError _) ->
      Parse_error (Agent_core.Error.to_string e)
  | Serialization (StructuredOutputStateError _) ->
      Agent_core_error (Agent_core.Error.to_string e)
  | Serialization (VersionMismatch r) when r.got < r.expected ->
      Superseded_version { expected = r.expected; got = r.got }
  (* Only a writer that bumped [checkpoint_version] reaches this arm; a codec
     change shipped without a bump fails later in the decode, as a
     [JsonParseError] or [UnknownVariant] (#38680). *)
  | Serialization (VersionMismatch r) when r.got > r.expected ->
      Newer_version { expected = r.expected; got = r.got }
  | Serialization (VersionMismatch r) ->
      Parse_error (sprintf "version mismatch: expected %d, got %d" r.expected r.got)
  | Serialization (UnknownVariant r) ->
      Parse_error (sprintf "unknown variant %s: %s" r.type_name r.value)
  | Api _ | Provider _ | Agent _ | Mcp _ | Config _
  | Orchestration _ | Media _ | Internal _ | Internal_carried { message = _; _ } ->
      Agent_core_error (Agent_core.Error.to_string e)

let classify_objects_error : Objects.load_error -> checkpoint_load_error = function
  | Objects.Head_invalid detail -> Parse_error detail
  | Objects.Checkpoint_invalid error -> classify_core_error error
  | ( Objects.Object_missing _
    | Objects.Object_unreadable _
    | Objects.Object_digest_mismatch _
    | Objects.Bundle_invalid _
    | Objects.Turn_mismatch _
    | Objects.Message_invalid _
    | Objects.Segment_invalid _
    | Objects.Header_object_invalid _ ) as error -> Objects_invalid error

(* Both checkpoint reads take their bytes through
   [Fs_compat.load_owned_regular_file]: the read runs on a system thread when
   the Eio filesystem is active, and the file must sit inside the owned chain
   the writers publish into ([~ownership_root], the parent of the session
   directory), so a symbolic link or a changed parent is refused. Until
   2026-09-05 the bytes came through [Fs_compat.load_file], whose Eio branch
   ([Eio.Path.load]) copied the 13-35 MB file on the calling fiber and held
   the main domain 45-180 ms per turn — the [openat -> switch] class of RFC
   main-domain-scheduler-latency §8.8. *)
let read_checkpoint_bytes ~(session_dir : string) path : (string, checkpoint_load_error) result =
  match
    Fs_compat.load_owned_regular_file
      ~ownership_root:(Filename.dirname session_dir)
      path
  with
  | Ok (Some bytes) -> Ok bytes
  | Ok None -> Error Not_found
  | Error error ->
    let detail = Fs_compat.owned_regular_file_read_error_to_string error in
    (match error.failure with
     | Fs_compat.Ownership_boundary_rejected _ | Fs_compat.Path_is_not_regular_file _
     | Fs_compat.Owned_path_owner_mismatch _
     | Fs_compat.Owned_path_writable_by_others _ ->
       Error (Io_error detail)
     | Fs_compat.Filesystem_identity_changed _ ->
       Error (Read_failed { cause = Changed_while_read; detail })
     | Fs_compat.Owned_file_operation_failed { cause = Unix.Unix_error (errno, _, _); _ } ->
       Error (Read_failed { cause = Os_error errno; detail })
     | Fs_compat.Owned_file_operation_failed _ ->
       Error (Read_failed { cause = Read_raised; detail }))

let load_agent_core_history_file ~(session_dir : string) ~(snapshot_id : string) :
    (Agent_core.Checkpoint.t, checkpoint_load_error) result =
  (* [snapshot_id] reaches this entry point from the dashboard HTTP
     surface; a non-segment id ("../..") would read outside the session
     directory, so it is refused as absent before any filesystem access. *)
  if not (leaf_is_real_segment snapshot_id) then Error Not_found
  else (
    let path = agent_core_history_path ~session_dir ~snapshot_id in
    if Fs_compat.file_exists path then
      try
        match read_checkpoint_bytes ~session_dir path with
        | Error e -> Error e
        | Ok bytes ->
          (match decode_head_off_scheduler ~session_dir ~memo:(Objects.create_memo ()) bytes with
           | Ok (_head, ckpt) -> Ok ckpt
           | Error e -> Error (classify_objects_error e))
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn -> Error (Io_error (Printexc.to_string exn))
    else Error Not_found)
