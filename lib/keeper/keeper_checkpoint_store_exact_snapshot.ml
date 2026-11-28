module Objects = Agent_core.Checkpoint_objects
open Keeper_checkpoint_store_history_files
open Keeper_checkpoint_store_decode
open Keeper_checkpoint_store_summary
open Keeper_checkpoint_store_lineage
open Keeper_checkpoint_store_session
open Keeper_checkpoint_store_canonical
open Keeper_checkpoint_store_ref_errors

type exact_checkpoint_snapshot =
  { checkpoint : Agent_core.Checkpoint.t
  ; reference : Keeper_checkpoint_ref.t
  }

let exact_snapshot_checkpoint snapshot = snapshot.checkpoint
let exact_snapshot_reference snapshot = snapshot.reference
let exact_snapshot_messages snapshot = snapshot.checkpoint.messages

(* A reference names the checkpoint's content digest, which a
   value and every head written for it share. *)
let checkpoint_ref_of_content (content : Objects.digest) (checkpoint : Agent_core.Checkpoint.t) =
  match Keeper_id.Trace_id.of_string checkpoint.Agent_core.Checkpoint.session_id with
  | Error reason -> Error (Session_id_invalid reason)
  | Ok trace_id ->
    Keeper_checkpoint_ref.of_persisted
      ~trace_id
      ~turn_count:checkpoint.turn_count
      ~sha256:(content :> string)
    |> Result.map_error (fun error -> Ref_create_failed error)

let exact_snapshot_of_checkpoint ~expected_session_id ~content checkpoint =
  match checkpoint_ref_of_content content checkpoint with
  | Error error -> Error (Ref_identity_invalid error)
  | Ok reference
    when not
           (Keeper_id.Trace_id.equal
              expected_session_id reference.trace_id) ->
    Error
      (Ref_session_mismatch
         { expected = expected_session_id; actual = reference.trace_id })
  | Ok reference -> Ok { checkpoint; reference }
;;

let exact_snapshot_of_value ~expected_session_id checkpoint =
  offload_checkpoint_cpu (fun () ->
    match Objects.content_digest (Objects.create_memo ()) checkpoint with
    | Error error -> Error (Ref_read_failed (classify_core_error error))
    | Ok content -> exact_snapshot_of_checkpoint ~expected_session_id ~content checkpoint)
;;

let exact_snapshot_of_head_bytes ~session_dir ~expected_session_id head_bytes =
  match decode_head_read_only_off_scheduler ~session_dir head_bytes with
  | Error error -> Error (Ref_read_failed (classify_objects_error error))
  | Ok (head, checkpoint) ->
    exact_snapshot_of_checkpoint
      ~expected_session_id ~content:(Objects.head_content_digest head) checkpoint
;;

let load_ref_and_head_locked ~session_dir ~expected_session_id =
  let canonical_path =
    agent_core_checkpoint_path
      ~session_dir
      ~session_id:(Keeper_id.Trace_id.to_string expected_session_id)
  in
  match load_canonical_bytes_strict canonical_path with
  | Error error -> Error (Ref_read_failed error)
  | Ok None -> Error Ref_not_found
  | Ok (Some (identity_before, head_bytes)) ->
    (* A Keeper's lineage holds what a load gives for the head it wrote or
       read, under that file's identity, so the objects of a head of that
       identity are not read again. The head is read: the reference is its
       content digest. *)
    let decoded =
      match reusable_written_value ~canonical_path ~identity:identity_before with
      | Some checkpoint ->
        Result.map (fun head -> head, checkpoint) (head_of_bytes_off_scheduler head_bytes)
      | None -> decode_head_read_only_off_scheduler ~session_dir head_bytes
    in
    (match decoded with
     | Error error -> Error (Ref_read_failed (classify_objects_error error))
     | Ok (head, checkpoint) ->
       (* Published from the lineage's value too. The save or load that kept
          it published this identity's summary, but an unlocked reader that
          parsed the file before it can have replaced that summary since, and
          the next save's watermark reads it. *)
       publish_summary_after_parse
         ~canonical_path
         ~identity_before:(Some identity_before)
         ~objects:Objects_seen
         head;
       exact_snapshot_of_checkpoint
         ~expected_session_id ~content:(Objects.head_content_digest head) checkpoint
       |> Result.map (fun snapshot -> snapshot, head))

let load_ref_locked ~session_dir ~expected_session_id =
  load_ref_and_head_locked ~session_dir ~expected_session_id |> Result.map fst

let with_agent_core_exact_snapshot ~session_dir ~session_id f =
  match Keeper_id.Trace_id.of_string session_id with
  | Error reason -> Error (Ref_identity_invalid (Session_id_invalid reason))
  | Ok expected_session_id ->
    (match
       with_session_lock ~session_dir (fun session_dir ->
         match load_ref_locked ~session_dir ~expected_session_id with
         | Error _ as error -> error
         | Ok snapshot -> Ok (f snapshot))
     with
     | Ok result -> result
     | Error detail -> Error (Ref_lock_failed detail))

let load_agent_core_exact_snapshot ~session_dir ~session_id =
  with_agent_core_exact_snapshot ~session_dir ~session_id Fun.id

type canonical_history_boundary =
  { closed_messages : int
  ; open_messages : int
  }

let load_agent_core_exact_snapshot_with_boundary ~session_dir ~session_id =
  match Keeper_id.Trace_id.of_string session_id with
  | Error reason -> Error (Ref_identity_invalid (Session_id_invalid reason))
  | Ok expected_session_id ->
    (match
       with_session_lock ~session_dir (fun session_dir ->
         match load_ref_and_head_locked ~session_dir ~expected_session_id with
         | Error _ as error -> error
         | Ok (snapshot, (head : Objects.head)) ->
           let open_messages = List.length head.history.open_messages in
           let closed_messages = Objects.message_count head.history - open_messages in
           Ok (snapshot, {closed_messages; open_messages}))
     with
     | Ok result -> result
     | Error detail -> Error (Ref_lock_failed detail))

let load_agent_core_with_ref ~session_dir ~session_id =
  load_agent_core_exact_snapshot ~session_dir ~session_id
  |> Result.map (fun snapshot ->
    exact_snapshot_checkpoint snapshot, exact_snapshot_reference snapshot)
;;

(* The head names its session without an object read, so a canonical of
   another session is refused here as a load refuses it. What is read after
   that is what [Objects.find_last] reads: the messages from the last one
   back to the one that answers [find]. No summary of the canonical is
   published: this reading has not seen every object the head names, and
   [known_canonical] parses a head nobody published. *)
let find_last_agent_core_message ~session_dir ~session_id find =
  match Keeper_id.Trace_id.of_string session_id with
  | Error reason -> Error (Ref_identity_invalid (Session_id_invalid reason))
  | Ok expected_session_id ->
    let find_in_canonical session_dir =
      let canonical_path =
        agent_core_checkpoint_path
          ~session_dir
          ~session_id:(Keeper_id.Trace_id.to_string expected_session_id)
      in
      match load_canonical_bytes_strict canonical_path with
      | Error error -> Error (Ref_read_failed error)
      | Ok None -> Error Ref_not_found
      | Ok (Some ((_ : canonical_identity), head_bytes)) ->
        offload_checkpoint_cpu (fun () ->
          match Objects.head_of_string head_bytes with
          | Error error -> Error (Ref_read_failed (classify_objects_error error))
          | Ok (head : Objects.head) ->
            (match Keeper_id.Trace_id.of_string head.header.session_id with
             | Error reason -> Error (Ref_identity_invalid (Session_id_invalid reason))
             | Ok actual when not (Keeper_id.Trace_id.equal actual expected_session_id) ->
               Error (Ref_session_mismatch { expected = expected_session_id; actual })
             | Ok (_ : Keeper_id.Trace_id.t) ->
               Objects.find_last
                 ~read_object:(Keeper_checkpoint_object_store.read ~session_dir)
                 head
                 find
               |> Result.map_error (fun error ->
                 Ref_read_failed (classify_objects_error error))))
    in
    (match with_session_lock ~session_dir find_in_canonical with
     | Ok result -> result
     | Error detail -> Error (Ref_lock_failed detail))
;;
