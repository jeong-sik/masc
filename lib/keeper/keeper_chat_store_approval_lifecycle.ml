open Keeper_approval_lifecycle
open Keeper_chat_types
open Keeper_chat_store_paths
open Keeper_chat_store_redaction
open Keeper_chat_store_row_codec
open Keeper_chat_store_append_primitives
open Keeper_chat_store_transcript_load

(* Content equality for the [Already_present] branch of the append-once
   paths: does the row that already holds this approval's slot say the same
   thing as the row we were about to write? Only durable facts take part:
   which approval, which phase, what the replay produced ([artifact_ref]),
   and which tool when both sides know it.

   [call_summary] is deliberately not compared. It is a rendering, not a
   fact: the producing tool states it once from its typed input, on the Gate
   request ([Keeper_gate.request.call_summary]); the request row is written
   with that statement, the store redacts it before writing, and every later
   phase row copies the stored line back ([approval_request_call_summary]).
   The same approval_id therefore never carries two different facts under it,
   and two rows for the same slot differ in it for exactly two reasons that
   are not conflicts: a request row that was never written or carried no
   statement leaves every later copy [None], and the redaction snapshot
   changed between the two writes. Comparing it would turn either into
   "conflicting content" on the append path and into a spurious correction
   row on the replay path. The consequence accepted: a slot first written
   without a summary is not backfilled by a later writer that has one, the
   same way [tool_name] is not. Pinned by
   test/test_keeper_chat_store_approval_summary.ml. *)
let approval_lifecycle_equal left right =
  let artifact_equal left right =
    match left, right with
    | None, None -> true
    | Some left, Some right ->
      String.equal left.Tool_output.sha256 right.Tool_output.sha256
      && Int.equal left.bytes right.bytes
      && String.equal left.mime right.mime
      && String.equal left.preview right.preview
    | None, Some _ | Some _, None -> false
  in
  let tool_name_equal left right =
    match left, right with
    | Some left, Some right -> String.equal left right
    | None, _ | _, None -> true
  in
  String.equal left.approval_id right.approval_id
  && tool_name_equal left.tool_name right.tool_name
  && left.phase = right.phase
  && artifact_equal left.artifact_ref right.artifact_ref
;;

type approval_lifecycle_append =
  | Approval_lifecycle_exact of append_once_result
  | Approval_lifecycle_conflict of approval_lifecycle

let approval_lifecycle_is_replay = function
  | Approval_requested -> false
  | Approval_replay_applied
  | Approval_replay_applied_with_warning
  | Approval_replay_failed
  | Approval_replay_indeterminate -> true
  | Approval_resolved_approved
  | Approval_resolved_rejected
  | Approval_continuation_recorded
  | Approval_continuation_failed -> false
;;

(* The continuation settles once per approval, at the continuation slot:
   recorded when the turn that received the replay completed or durably
   checkpointed, failed when that turn failed after the provider answered.
   Either one is the settlement the intake reads before re-delivering the
   approval (#32956). *)
let approval_lifecycle_is_continuation = function
  | Approval_continuation_recorded
  | Approval_continuation_failed -> true
  | Approval_requested
  | Approval_resolved_approved
  | Approval_resolved_rejected
  | Approval_replay_applied
  | Approval_replay_applied_with_warning
  | Approval_replay_failed
  | Approval_replay_indeterminate -> false
;;

let append_approval_lifecycle_at_slot_once
      ~base_dir
      ~keeper_name
      ~lifecycle
      ~transcript_slot
  =
  let open Keeper_chat_delivery_identity in
  let approval_id = lifecycle.approval_id in
    (try
       ensure_dir_once ~base_dir;
       let redaction = redaction_for ~base_dir ~keeper_name in
       let lifecycle = redact_approval_lifecycle redaction lifecycle in
       let delivery_key = Approval_lifecycle approval_id in
       let provenance = { delivery_key; transcript_slot } in
       let path = chat_path ~base_dir ~keeper_name in
       let ts = Time_compat.now () in
       let row_id = mint_message_id ~ts in
       (* The row's fact is [approval_lifecycle], and [transcript_slot] says
          which step it is -- a correction is [Approval_replay_correction], not
          a sentence saying so. The store used to compose a Korean retelling of
          both into [content], which made a machine-written row read as
          something a Keeper said and put display wording in the persistence
          layer. Every reader now takes the typed fields and words them itself
          (masc #33016). *)
       let line =
         encode_line
           ~role:Role.System
           ~content:""
           ~ts
           ~message_id:row_id
           ~approval_lifecycle:lifecycle
           ~provenance
           ()
       in
       match append_line_once path ~provenance ~row_id line with
       | Error _ as error -> error
       | Ok (Appended _ as result) ->
         announce_appended ~keeper_name ();
         Ok (Approval_lifecycle_exact result)
       | Ok (Already_present { row_id } as result) ->
         (match
            load_all ~base_dir ~keeper_name
            |> List.find_opt (fun message -> String.equal message.id row_id)
          with
          | Some { approval_lifecycle = Some existing; _ }
            when approval_lifecycle_equal existing lifecycle ->
            Ok (Approval_lifecycle_exact result)
          | Some { approval_lifecycle = Some existing; _ } ->
            Ok (Approval_lifecycle_conflict existing)
          | Some _ ->
            Error "approval lifecycle provenance row has no lifecycle content"
          | None -> Error "approval lifecycle provenance row is unreadable")
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       let detail = Printexc.to_string exn in
       Log.Keeper.warn
         "keeper_chat_store: approval lifecycle append failed for %s: %s"
         (sanitize_name keeper_name)
         detail;
       Error detail)

let append_approval_lifecycle_once ~base_dir ~keeper_name ~lifecycle =
  let open Keeper_chat_delivery_identity in
  let transcript_slot =
    match lifecycle.phase with
    | Approval_requested -> Approval_request
    | Approval_resolved_approved | Approval_resolved_rejected ->
      Approval_resolution
    | Approval_replay_applied
    | Approval_replay_applied_with_warning
    | Approval_replay_failed
    | Approval_replay_indeterminate -> Approval_replay
    | Approval_continuation_recorded
    | Approval_continuation_failed -> Approval_continuation
  in
  match
    append_approval_lifecycle_at_slot_once
      ~base_dir
      ~keeper_name
      ~lifecycle
      ~transcript_slot
  with
  | Error _ as error -> error
  | Ok (Approval_lifecycle_exact result) -> Ok result
  | Ok (Approval_lifecycle_conflict existing) ->
    (* The slot is settled once; say by what, so a caller that reports this
       as "projection failed" still names the phase already there. *)
    Error
      (Printf.sprintf
         "approval lifecycle provenance exists with conflicting content: \
          approval %s already holds phase %s where phase %s was to be appended"
         lifecycle.approval_id
         (approval_lifecycle_phase_to_label existing.phase)
         (approval_lifecycle_phase_to_label lifecycle.phase))
;;

let existing_approval_lifecycle_at_slot
      ~base_dir
      ~keeper_name
      ~approval_id
      ~transcript_slot
  =
  let open Keeper_chat_delivery_identity in
  load_all ~base_dir ~keeper_name
  |> List.find_map (fun message ->
    match message.delivery_provenance, message.approval_lifecycle with
    | ( Some
          { delivery_key = Approval_lifecycle existing_approval_id
          ; transcript_slot = existing_slot
          }
      , Some existing_lifecycle )
      when String.equal (Request_id.to_string existing_approval_id) approval_id
           && transcript_slot_equal existing_slot transcript_slot ->
      Some (message.id, existing_lifecycle)
    | ( ( None
        | Some
            { delivery_key =
                ( Operation _
                | Operation_checkpoint _
                | Operation_native _
                | Fusion_run _
                | Workspace_message _
                | Connector_message _
                | Approval_lifecycle _
                | Autonomous_turn _ )
            ; _
            } )
      , (None | Some _) ) -> None)
;;

let reconcile_approval_replay_lifecycle_once ~base_dir ~keeper_name ~lifecycle =
  let open Keeper_chat_delivery_identity in
  if not (approval_lifecycle_is_replay lifecycle.phase)
  then Error "approval replay reconciliation requires a replay lifecycle phase"
  else
    let redaction = redaction_for ~base_dir ~keeper_name in
    let redacted_lifecycle = redact_approval_lifecycle redaction lifecycle in
    match
      existing_approval_lifecycle_at_slot
        ~base_dir
        ~keeper_name
        ~approval_id:lifecycle.approval_id
        ~transcript_slot:Approval_replay_correction
    with
    | Some (row_id, existing)
      when approval_lifecycle_equal existing redacted_lifecycle ->
      Ok (Already_present { row_id })
    | Some _ -> Error "approval replay correction exists with conflicting content"
    | None ->
      (match
         append_approval_lifecycle_at_slot_once
           ~base_dir
           ~keeper_name
           ~lifecycle
           ~transcript_slot:Approval_replay
       with
       | Error _ as error -> error
       | Ok (Approval_lifecycle_exact result) -> Ok result
       | Ok (Approval_lifecycle_conflict previous) ->
         (match
            append_approval_lifecycle_at_slot_once
              ~base_dir
              ~keeper_name
              ~lifecycle
              ~transcript_slot:Approval_replay_correction
          with
          | Error _ as error -> error
          | Ok
              (Approval_lifecycle_exact
                (Appended _ as result)) ->
            Log.Keeper.warn
              ~keeper_name
              "approval replay chat correction appended approval=%s previous_phase=%s canonical_phase=%s"
              lifecycle.approval_id
              (approval_lifecycle_phase_to_label previous.phase)
              (approval_lifecycle_phase_to_label lifecycle.phase);
            Ok result
          | Ok (Approval_lifecycle_exact (Already_present _ as result)) -> Ok result
          | Ok (Approval_lifecycle_conflict _) ->
            Error "approval replay correction exists with conflicting content"))
;;

let approval_lifecycle_phase_present
      ~base_dir
      ~keeper_name
      ~approval_id
      ~phase
  =
  load_all ~base_dir ~keeper_name
  |> List.exists (fun message ->
    match message.approval_lifecycle with
    | Some lifecycle ->
      String.equal lifecycle.approval_id approval_id && lifecycle.phase = phase
    | None -> false)
;;

let approval_continuation_settled ~base_dir ~keeper_name ~approval_id =
  load_all ~base_dir ~keeper_name
  |> List.exists (fun message ->
    match message.approval_lifecycle with
    | Some lifecycle ->
      String.equal lifecycle.approval_id approval_id
      && approval_lifecycle_is_continuation lifecycle.phase
    | None -> false)
;;

(* The request row is written by the queue with the producer's statement in
   hand ([Keeper_gate.request.call_summary]); no later writer has the
   producer, so every later phase row copies the line from here. Read from the
   stored row, so the copy carries the redaction the store applied. *)
let approval_request_call_summary ~base_dir ~keeper_name ~approval_id =
  Option.bind
    (existing_approval_lifecycle_at_slot
       ~base_dir
       ~keeper_name
       ~approval_id
       ~transcript_slot:Keeper_chat_delivery_identity.Approval_request)
    (fun (_row_id, lifecycle) -> lifecycle.call_summary)
;;
