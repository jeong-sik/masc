module Objects = Agent_core.Checkpoint_objects
open Keeper_checkpoint_store_history_files
open Keeper_checkpoint_store_decode
open Keeper_checkpoint_store_summary
open Keeper_checkpoint_store_session

(* The bytes go into one allocation of the size the descriptor reports, and
   the identity returned is the descriptor's, so it names the file the bytes
   came from: the lineage reuse in [load_ref_locked] relies on that. The bytes
   are refused as changed while read when the descriptor is not the regular
   file [lstat] saw at the path, or when the file ends early, or when its
   identity moved during the read: the file was replaced or rewritten in
   place under the read, and the bytes are not one version of it. *)
let load_canonical_bytes_strict path =
  let unix_error error operation argument =
    Read_failed
      { cause = Os_error error
      ; detail = Printf.sprintf "%s(%s): %s"
          operation argument (Unix.error_message error)
      }
  in
  let changed_while_read () =
    Read_failed
      { cause = Changed_while_read
      ; detail = "canonical checkpoint changed while it was read: " ^ path
      }
  in
  let read_exact fd size =
    let bytes = Bytes.create size in
    let rec fill offset =
      if offset = size
      then Some (Bytes.unsafe_to_string bytes)
      else
        match Unix.read fd bytes offset (size - offset) with
        | 0 -> None
        | count -> fill (offset + count)
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> fill offset
    in
    fill 0
  in
  let read () =
    match Unix.lstat path with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
    | exception Unix.Unix_error (error, operation, argument) ->
      Error (unix_error error operation argument)
    | stat when stat.Unix.st_kind <> Unix.S_REG ->
      Error (Io_error ("canonical checkpoint is not a regular file: " ^ path))
    | path_stats ->
      (try
         let fd = Unix.openfile path [ Unix.O_CLOEXEC; Unix.O_RDONLY ] 0 in
         Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
           let opened = Unix.fstat fd in
           if opened.Unix.st_kind <> Unix.S_REG
              || opened.Unix.st_dev <> path_stats.Unix.st_dev
              || opened.Unix.st_ino <> path_stats.Unix.st_ino
           then Error (changed_while_read ())
           else (
             let identity = canonical_identity_of_stats opened in
             match read_exact fd identity.size with
             | None -> Error (changed_while_read ())
             | Some content ->
               if canonical_identity_equal identity (canonical_identity_of_stats (Unix.fstat fd))
               then Ok (Some (identity, content))
               else Error (changed_while_read ())))
       with
       | Unix.Unix_error (error, operation, argument) ->
         Error (unix_error error operation argument))
  in
  match Eio_guard.run_in_systhread ~label:"checkpoint-read" read with
  | Ok content -> Ok content
  | Error _ as error -> error
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> Error (Io_error (Printexc.to_string exn))

(* What a save needs from the canonical: the head alone, no message object.
   From the summary while it describes the file, otherwise from a parse of
   the head, which publishes the summary. *)
type known_canonical =
  { known_session_id : string
  ; known_turn_count : int
  ; known_head : Objects.head
  ; known_objects : head_objects
  }

let known_of_summary summary =
  { known_session_id = summary.summary_session_id
  ; known_turn_count = summary.summary_turn_count
  ; known_head = summary.summary_head
  ; known_objects = summary.summary_objects
  }

(* The head on disk now, parsed, with the identity of the file read. *)
let parsed_canonical ~canonical_path
  : ((canonical_identity * Objects.head) option, checkpoint_load_error) result =
  match load_canonical_bytes_strict canonical_path with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some (identity, content)) ->
    (match head_of_bytes_off_scheduler content with
     | Error error -> Error (classify_objects_error error)
     | Ok head -> Ok (Some (identity, head)))

let known_canonical ~canonical_path
  : (known_canonical option, checkpoint_load_error) result =
  match cached_summary ~canonical_path with
  | Some summary -> Ok (Some (known_of_summary summary))
  | None ->
    (match parsed_canonical ~canonical_path with
     | Error _ as error -> error
     | Ok None -> Ok None
     | Ok (Some (identity, head)) ->
       let summary = summary_of_head ~identity ~objects:Objects_unchecked head in
       publish_summary_after_parse
         ~canonical_path ~identity_before:(Some identity) ~objects:Objects_unchecked head;
       Ok (Some (known_of_summary summary)))

(* The segments before [head]'s last one and every segment's bundles, read
   from the last segment back, or the first segment that could not be read
   whole. *)
(* The objects the canonical names that the session does not hold. A head
   this process has seen whole names none; one only parsed is checked file
   by file, so the save that follows writes the missing ones again instead
   of naming them once more. An object missing behind the last segment
   cannot be written again in its place, so that segment is reported absent
   and the save does not keep it. *)
let absent_objects ~session_dir (known : known_canonical) =
  match known.known_objects with
  | Objects_seen -> []
  | Objects_unchecked ->
    let head = known.known_head in
    let missing digests =
      List.filter
        (fun digest -> not (Keeper_checkpoint_object_store.present ~session_dir digest))
        digests
    in
    let named = missing (Objects.head_objects head) in
    (match head.history.segment, Keeper_checkpoint_object_store.walk_segments ~session_dir head with
     | None, (Keeper_checkpoint_object_store.Segments_reached _ | Segment_unreachable _) -> named
     | Some last, Keeper_checkpoint_object_store.Segment_unreachable _ -> last.segment :: named
     | Some last, Keeper_checkpoint_object_store.Segments_reached reached ->
       (match missing reached with
        | [] -> named
        | _ :: _ -> last.segment :: named))

(* ── Judging and removing an undecodable canonical ([masc_keeper_clear]) ─
   A canonical no turn can decode fails every turn (#37089), and nothing the
   store writes may replace it. The operator's clear deletes it, so the next
   turn starts from no checkpoint.

   Only bytes that were read and then rejected by the decoder for their
   content are removed. A read that returned no bytes (an OS failure, a file
   that changed during the read, a path that is not a regular file inside the
   owned chain, a session id that is not a path segment) says nothing about
   the content. A canonical a build that bumped [checkpoint_version] wrote is
   readable by that build. Both stay. A later build that changed the codec
   without a bump is not told apart from damage and is removed (#38680). The step that stopped decides this, not the
   [checkpoint_load_error] label: other readers in this module report OS
   failures as [Io_error]. *)

type canonical_judgement =
  | Judged_absent
  | Judged_decoded of Agent_core.Checkpoint.t
  | Judged_superseded of { expected : int; got : int }
  | Judged_newer of { expected : int; got : int }
  | Judged_undecodable of checkpoint_load_error
  | Judged_inconclusive of checkpoint_load_error

(* The read and the decode [load_agent_core] takes, one step at a time so the
   step that stopped is known. *)
let judge_canonical ~(session_dir : string) ~(session_id : string) : canonical_judgement =
  let raised cause exn =
    Judged_inconclusive (Read_failed { cause; detail = Printexc.to_string exn })
  in
  if not (leaf_is_real_segment session_id) then
    Judged_inconclusive (Store_error "session_id is not a real path segment")
  else
    let path = agent_core_checkpoint_path ~session_dir ~session_id in
    match read_checkpoint_bytes ~session_dir path with
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception (Unix.Unix_error (errno, _, _) as exn) -> raised (Os_error errno) exn
    | exception exn -> raised Read_raised exn
    | Error Not_found -> Judged_absent
    | Error
        (( Store_error _
         | Parse_error _
         | Superseded_version _
         | Newer_version _
         | Io_error _
         | Read_failed _
         | Agent_core_error _
         | Objects_invalid _ ) as error) -> Judged_inconclusive error
    | Ok bytes ->
      (match decode_head_off_scheduler ~session_dir ~memo:(Objects.create_memo ()) bytes with
       | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
       | exception exn -> raised Read_raised exn
       | Ok (_head, checkpoint) -> Judged_decoded checkpoint
       (* An object the OS could not read says nothing about what it holds. *)
       | Error (Objects.Object_unreadable _ as error) -> Judged_inconclusive (Objects_invalid error)
       | Error
           (( Objects.Head_invalid _
            | Objects.Checkpoint_invalid _
            | Objects.Object_missing _
            | Objects.Object_digest_mismatch _
            | Objects.Bundle_invalid _
            | Objects.Turn_mismatch _
            | Objects.Message_invalid _
            | Objects.Segment_invalid _
            | Objects.Header_object_invalid _ ) as error) ->
         (match classify_objects_error error with
          | Superseded_version { expected; got } -> Judged_superseded { expected; got }
          | Newer_version { expected; got } -> Judged_newer { expected; got }
          | (Parse_error _ | Store_error _ | Objects_invalid _) as undecodable ->
            Judged_undecodable undecodable
          (* The decoder failed for a reason that is not the content. *)
          | (Not_found | Io_error _ | Read_failed _ | Agent_core_error _) as error ->
            Judged_inconclusive error))

type undecodable_removal_outcome =
  | Removed of { undecodable : checkpoint_load_error }
  | Canonical_absent
  | Canonical_loadable

type undecodable_removal_error =
  | Removal_refused of checkpoint_load_error
  | Removal_failed of string
  | Removal_durability_unknown of string

let undecodable_removal_error_to_string = function
  | Removal_refused error ->
    "the checkpoint was not removed, because reading it again did not show bytes whose content fails to decode: "
    ^ checkpoint_load_error_to_string error
  | Removal_failed detail -> "the undecodable checkpoint was not removed: " ^ detail
  | Removal_durability_unknown detail ->
    "the undecodable checkpoint was removed, but the directory sync failed: " ^ detail

let remove_undecodable_canonical ~(session_dir : string) ~(session_id : string)
  : (undecodable_removal_outcome, undecodable_removal_error) result =
  if not (leaf_is_real_segment session_id) then
    Error (Removal_failed "session_id is not a real path segment")
  else
    let locked =
      with_session_lock ~session_dir (fun session_dir ->
        let remove undecodable =
          let canonical_path = agent_core_checkpoint_path ~session_dir ~session_id in
          let unlink_and_sync () =
            Unix.unlink canonical_path;
            match Keeper_fs_durable_directory.fsync_directory session_dir with
            | () -> Ok (Removed { undecodable })
            | exception ((Unix.Unix_error _ | Fun.Finally_raised _) as exn) ->
              Error (Removal_durability_unknown (Printexc.to_string exn))
          in
          match
            Eio_guard.run_in_systhread ~label:"keeper.checkpoint.remove-undecodable"
              unlink_and_sync
          with
          | result -> result
          | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
          | exception (Unix.Unix_error _ as exn) ->
            Error (Removal_failed (Printexc.to_string exn))
        in
        match judge_canonical ~session_dir ~session_id with
        | Judged_absent -> Ok Canonical_absent
        (* A turn starts from the first, and replaces the second on its first
           save. *)
        | Judged_decoded _ | Judged_superseded _ -> Ok Canonical_loadable
        | Judged_newer { expected; got } ->
          Error (Removal_refused (Newer_version { expected; got }))
        | Judged_inconclusive error -> Error (Removal_refused error)
        | Judged_undecodable undecodable -> remove undecodable)
    in
    match locked with
    | Ok result -> result
    | Error detail -> Error (Removal_failed detail)
