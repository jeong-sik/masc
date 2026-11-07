open Keeper_approval_lifecycle
open Keeper_chat_types
open Keeper_chat_projection
open Keeper_chat_store_paths

let parse_stream_lifecycle ~path json =
  let invalid detail =
    report_persistence_read_drop
      ~reason:Read_drop_reason.Invalid_payload
      ~path ~detail;
    None
  in
  let rec parse_items acc = function
    | [] -> Some (List.rev acc)
    | `String label :: rest -> (
        match stream_lifecycle_event_of_label label with
        | Some event -> parse_items (event :: acc) rest
        | None ->
            invalid (Printf.sprintf "unknown stream_lifecycle event %S" label))
    | _ :: _ -> invalid "stream_lifecycle contains non-string event"
  in
  match json with
  | `List [] -> None
  | `List items -> parse_items [] items
  | _ -> invalid "stream_lifecycle field is not a list"

let parse_approval_lifecycle ~path = function
  | `Assoc fields ->
    let invalid detail =
      report_persistence_read_drop
        ~reason:Read_drop_reason.Invalid_payload
        ~path
        ~detail;
      None
    in
    let string_field name =
      match List.assoc_opt name fields with
      | Some (`String value) when String.trim value <> "" -> Some value
      | Some _ | None -> None
    in
    (match string_field "approval_id", string_field "phase" with
     | Some approval_id, Some phase_label ->
       (match approval_lifecycle_phase_of_label phase_label with
        | None ->
          invalid (Printf.sprintf "unknown approval lifecycle phase %S" phase_label)
        | Some phase ->
          let tool_name = string_field "tool_name" in
          let artifact_ref =
            match List.assoc_opt "artifact_ref" fields with
            | None -> Ok None
            | Some json ->
              (match Tool_output.normalized_artifact_ref_of_json json with
               | Tool_output.Decoded_normalized_artifact_ref value -> Ok (Some value)
               | Tool_output.Not_normalized_artifact_ref ->
                 Error "approval lifecycle artifact_ref is not a normalized reference"
               | Tool_output.Invalid_normalized_artifact_ref { detail } -> Error detail)
          in
          (match artifact_ref with
           | Error detail -> invalid detail
           | Ok artifact_ref ->
             let phase_requires_artifact =
               match phase with
               | Approval_requested
               | Approval_resolved_approved
               | Approval_resolved_rejected
               | Approval_continuation_recorded
               | Approval_continuation_failed -> false
               | Approval_replay_applied
               | Approval_replay_applied_with_warning
               | Approval_replay_failed
               | Approval_replay_indeterminate -> true
             in
             if phase_requires_artifact <> Option.is_some artifact_ref
             then invalid "approval lifecycle artifact_ref does not match its phase"
             else
               Some
                 { approval_id
                 ; tool_name
                 ; phase
                 ; artifact_ref
                 ; call_summary = string_field "call_summary"
                 }))
     | None, _ | _, None ->
       invalid "approval lifecycle is missing approval_id or phase")
  | _ ->
    report_persistence_read_drop
      ~reason:Read_drop_reason.Invalid_payload
      ~path
      ~detail:"approval_lifecycle field is not an object";
    None

(* R3: producer-assigned message id.  [encode_line] is the sole writer, so
   minting here makes it impossible to persist a row without an id.  The
   process-monotonic counter disambiguates the user/tool/assistant rows of
   one turn (they share a timestamp); the microsecond timestamp orders ids
   across processes.  Minted ids are persisted, so reads are deterministic
   even though the mint itself is not. *)
let message_id_counter = Atomic.make 0

let mint_message_id ~ts =
  let n = Atomic.fetch_and_add message_id_counter 1 in
  Printf.sprintf "msg-%016.0f-%d" (ts *. 1_000_000.) n

let validate_row_fields fields =
  (* RFC-0232 retired the label-only [source] field long before this list
     existed (#20976). Rows written before that still carry it, so the strict
     reader must tolerate it: a retired label never restores a typed surface,
     but it must not delete the row either — [surface] reads as [None] and the
     row stays (test/test_surface_ref.ml, "source-only row does not restore
     surface").

     The retired row-level [kind] label is absent from this list on purpose,
     and unlike [source] it stays refused.  docs/evidence/godfiles-20261008/kind-contract.md
     closes that row shape with no compatibility or migration path: a row
     still carrying [kind] is unknown row metadata, not assistant speech, so
     it is dropped with [unknown chat row field "kind"] rather than read.
     test/test_keeper_chat_store.ml, "retired kind row dropped
     (kind-contract)" pins the drop. *)
  let allowed =
    [ "id"; "role"; "content"; "ts"; "attachments"; "mentions"; "tool_call_id"
    ; "execution_id"; "tool_call_name"; "surface"; "conversation_id"
    ; "external_message_id"; "workspace_id"; "speaker_id"; "speaker_name"
    ; "speaker_authority"; "audio"; "blocks"; "turn_ref"; "stream_lifecycle"
    ; "approval_lifecycle"; "delivery_key"; "transcript_slot"; "source" ] in
  match List.find_opt (fun (key, _) -> not (List.mem key allowed)) fields with
  | None -> Ok ()
  | Some (key, _) -> Error (Printf.sprintf "unknown chat row field %S" key)
;;

let encode_line ~(role : Role.t) ~content ~ts ?message_id ?attachments ?tool_call_id
    ?execution_id ?tool_call_name ?surface ?conversation_id ?external_message_id ?workspace_id
    ?speaker
    ?audio ?blocks ?mentions ?turn_ref
    ?stream_lifecycle ?approval_lifecycle ?provenance ()
    : string =
  let surface_field =
    match surface with
    | None -> []
    | Some s -> [ ("surface", Surface_ref.to_json s) ]
  in
  let message_id =
    match message_id with
    | Some value -> value
    | None -> mint_message_id ~ts
  in
  let base_fields = [
    ("id", `String message_id);
    ("role", `String (Role.to_label role));
    ("content", `String content);
    ("ts", `Float ts);
  ] in
  (* Only Keeper speech has a default rich-text projection. The diagnostic
     on a failed-request row is server-owned text; completed blocks supplied
     by the producer are retained independently of that failure. *)
  let blocks =
    match blocks, role with
    | Some _, _ -> blocks
    | None, Role.Assistant when String.trim content <> "" ->
      Some (Keeper_chat_blocks.parse_text_to_blocks content)
    | None, (Role.User | Role.Assistant | Role.System | Role.Tool | Role.Request_failure) -> None
  in
  (* Some [] records the writer's explicit no-mention decision. None is used
     only where this row has no mention metadata supplied by its writer. *)
  let mention_fields =
    match mentions with
    | None -> []
    | Some ids ->
        [ ( "mentions",
            `List
              (List.map
                 (fun id ->
                   `String (Keeper_identity.Keeper_id.to_string id))
                 ids) )
        ]
  in
  let attachment_fields =
    match attachments with
    | None | Some [] -> []
    | Some atts ->
        let att_json = List.map (fun (att : attachment) ->
          `Assoc ([
            ("id", `String att.id);
            ("type", `String att.att_type);
            ("name", `String att.name);
            ("size", `Int att.size);
            ("mime_type", `String att.mime_type);
            ("data", `String att.data);
          ]
          @ (match (att.width, att.height) with
             | Some width, Some height ->
               [ ("width", `Int width); ("height", `Int height) ]
             | _ -> []))
        ) atts in
        [("attachments", `List att_json)]
  in
  let all_fields =
    base_fields
    @ attachment_fields
    @ mention_fields
    @ Json_util.string_field_if_present "tool_call_id" tool_call_id
    @ Json_util.string_field_if_present "execution_id"
        (Option.map Ids.Execution_id.to_string execution_id)
    @ Json_util.string_field_if_present "tool_call_name" tool_call_name
    @ surface_field
    @ Json_util.string_field_if_present "conversation_id" conversation_id
    @ Json_util.string_field_if_present "external_message_id" external_message_id
    @ Json_util.string_field_if_present "workspace_id" workspace_id
    @ speaker_fields speaker
    @ audio_fields audio
    @ blocks_fields blocks
    @ Json_util.string_field_if_present "turn_ref" (Option.map Ids.Turn_ref.to_string turn_ref)
    @ stream_lifecycle_fields stream_lifecycle
    @ approval_lifecycle_fields approval_lifecycle
    @ (match provenance with
       | None -> []
       | Some value ->
         Keeper_chat_delivery_identity.delivery_provenance_fields value)
  in
  Yojson.Safe.to_string (`Assoc all_fields)
