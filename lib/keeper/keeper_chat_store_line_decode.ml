open Keeper_chat_types
open Keeper_chat_store_paths
open Keeper_chat_store_row_codec
open Keeper_chat_store_delivery_rules

type strict_decode_cause =
  | Invalid_surface of string
  | Unknown_speaker_authority of string
  | Missing_speaker_authority
  | Invalid_row_contract of string
  | Unreadable_file of string

type strict_decode_error =
  { location : string
  ; cause : strict_decode_cause
  }

let strict_decode_error_to_string { location; cause } =
  match cause with
  | Invalid_surface detail ->
    Printf.sprintf "%s invalid surface field: %s" location detail
  | Unknown_speaker_authority label ->
    Printf.sprintf "%s unknown speaker_authority %S" location label
  | Missing_speaker_authority ->
    Printf.sprintf "%s speaker_id/speaker_name without speaker_authority" location
  | Invalid_row_contract detail -> Printf.sprintf "%s %s" location detail
  | Unreadable_file detail -> detail

type parsed_line =
  { message : chat_message option
  ; strict_decode_error : strict_decode_cause option
  }

let parse_line_decoded ~file_path (line : string) : parsed_line =
  try
    let json = Yojson.Safe.from_string line in
    let role_label =
      Json_util.get_string_with_default json ~key:"role" ~default:""
    in
    let content = Json_util.get_string_with_default json ~key:"content" ~default:"" in
    let ts =
      match Json_util.assoc_member_opt "ts" json with
      | Some (`Float f) -> Some f
      | Some _ | None -> None
    in
    let opt_string key =
      match Json_util.assoc_member_opt key json with
      | Some (`String value) when String.trim value <> "" -> Some value
      | _ -> None
    in
    let tool_call_id = opt_string "tool_call_id" in
    let execution_id_result =
      match json with
      | `Assoc fields -> execution_id_of_fields fields
      | _ -> Ok None
    in
    let execution_id =
      match execution_id_result with
      | Ok execution_id -> execution_id
      | Error _ -> None
    in
    let tool_call_name = opt_string "tool_call_name" in
    let surface, surface_error =
      match Json_util.assoc_member_opt "surface" json with
      | None -> None, None
      | Some surface_json -> (
          match Surface_ref.of_json surface_json with
          | Ok s -> Some s, None
          | Error detail ->
              (* A persisted surface is the row's only typed routing
                 identity. One that does not decode cannot be read as
                 "no surface": that would move a connector message into
                 unscoped global history. Both readers refuse the row —
                 the permissive reader drops it (counted here as a read
                 drop), the strict reader stops at it. *)
              report_persistence_read_drop
                ~reason:Read_drop_reason.Invalid_payload
                ~path:file_path
                ~detail:(Printf.sprintf "invalid surface field: %s" detail);
              None, Some (Invalid_surface detail))
    in
    let conversation_id = opt_string "conversation_id" in
    let external_message_id = opt_string "external_message_id" in
    let workspace_id = opt_string "workspace_id" in
    let speaker, speaker_error =
      let speaker_id = opt_string "speaker_id" in
      let speaker_name = opt_string "speaker_name" in
      match opt_string "speaker_authority" with
      | Some label -> (
          match authority_of_label label with
          | Some speaker_authority ->
              Some { speaker_id; speaker_name; speaker_authority }, None
          | None ->
              (* Unknown authority label: surface it instead of guessing
                 a class; the row itself stays valid. *)
              report_persistence_read_drop
                ~reason:Read_drop_reason.Invalid_payload
                ~path:file_path
                ~detail:
                  (Printf.sprintf "unknown speaker_authority %S" label);
              None, Some (Unknown_speaker_authority label))
      | None ->
          (match speaker_id, speaker_name with
           | None, None -> None, None
           | _ ->
               (* id/name without an authority class never comes from our
                  writer; report so the producer gets fixed. *)
               report_persistence_read_drop
                 ~reason:Read_drop_reason.Invalid_payload
                 ~path:file_path
                 ~detail:"speaker_id/speaker_name without speaker_authority";
               None, Some Missing_speaker_authority)
    in
    let strict_decode_error =
      match surface_error with
      | Some _ -> surface_error
      | None -> speaker_error
    in
    let audio =
      match Json_util.assoc_member_opt "audio" json with
      | Some (`Assoc fields) ->
          let get k =
            match List.assoc_opt k fields with
            | Some (`String s) -> Some s
            | _ -> None
          in
          (match get "token", get "mime" with
           | Some token, Some mime ->
               let duration_sec =
                 match List.assoc_opt "duration_sec" fields with
                 | Some (`Float f) -> Some f
                 | _ -> None
               in
               let message_text = Option.value (get "message_text") ~default:"" in
               let audio_url = get "audio_url" in
               let device_id = get "device_id" in
               let expired =
                 match List.assoc_opt "expired" fields with
                 | Some (`Bool b) -> b
                 | _ -> false
               in
               Some { token; audio_url; mime; duration_sec; message_text; device_id; expired }
           | _ ->
               (* audio without token+mime is malformed; drop the field but
                  keep the row (text-only render). *)
               report_persistence_read_drop
                 ~reason:Read_drop_reason.Invalid_payload
                 ~path:file_path
                 ~detail:"audio field missing token/mime";
               None)
      | _ -> None
    in
    let attachments =
      match Json_util.assoc_member_opt "attachments" json with
      | Some (`List att_list) ->
          let atts = List.filter_map (fun att_json ->
            match att_json with
            | `Assoc _ ->
                (* No guard: Json_util getters absorb type errors into their
                   defaults, so this body is total — the catch that wrapped it
                   could only hide asynchronous exceptions. *)
                let id = Json_util.get_string_with_default att_json ~key:"id" ~default:"" in
                let att_type = Json_util.get_string_with_default att_json ~key:"type" ~default:"" in
                let name = Json_util.get_string_with_default att_json ~key:"name" ~default:"" in
                let size = (match Json_util.assoc_member_opt "size" att_json with
                  | Some (`Int i) -> i | _ -> 0) in
                let mime_type = Json_util.get_string_with_default att_json ~key:"mime_type" ~default:"" in
                let data = Json_util.get_string_with_default att_json ~key:"data" ~default:"" in
                let int_of key = (match Json_util.assoc_member_opt key att_json with
                  | Some (`Int i) when i >= 0 -> Some i | _ -> None) in
                if id = "" || data = "" then None
                else Some
                  { id; att_type; name; size; mime_type; data
                  ; width = int_of "width"; height = int_of "height" }
            | _ -> None
          ) att_list in
          if atts = [] then None else Some atts
      | _ -> None
    in
    let mentions =
      (* Absent field = pre-P4 row or no mentions; both read as [].
         Entries that cannot mint an id are reported and skipped — the
         row itself stays valid (losing one malformed mention must not
         drop the whole line from the lane). *)
      match Json_util.assoc_member_opt "mentions" json with
      | None -> []
      | Some (`List items) ->
          List.filter_map
            (fun item ->
              match item with
              | `String value -> (
                  match Keeper_identity.Keeper_id.of_string value with
                  | Some _ as id -> id
                  | None ->
                      report_persistence_read_drop
                        ~reason:
                          Read_drop_reason.Invalid_payload
                        ~path:file_path
                        ~detail:
                          (Printf.sprintf "empty mention entry %S" value);
                      None)
              | _ ->
                  report_persistence_read_drop
                    ~reason:
                      Read_drop_reason.Invalid_payload
                    ~path:file_path
                    ~detail:"non-string mention entry";
                  None)
            items
      | Some _ ->
          report_persistence_read_drop
            ~reason:Read_drop_reason.Invalid_payload
            ~path:file_path
            ~detail:"mentions field is not a list";
          []
    in
    let blocks =
      match Json_util.assoc_member_opt "blocks" json with
      | None -> None
      | Some blocks_json -> (
          match Keeper_chat_blocks.blocks_of_yojson blocks_json with
          | Some _ as blocks -> blocks
          | None ->
              report_persistence_read_drop
                ~reason:Read_drop_reason.Invalid_payload
                ~path:file_path
                ~detail:"invalid blocks field";
              None)
    in
    let contract_result = match json with
      | `Assoc fields -> validate_row_fields fields
      | _ -> Error "chat row must be an object" in
    let strict_decode_error = match contract_result with
      | Ok () -> strict_decode_error
      | Error detail ->
        report_persistence_read_drop ~reason:Read_drop_reason.Invalid_payload
          ~path:file_path ~detail;
        Some (Invalid_row_contract detail)
    in
    let turn_ref =
      (* RFC-0233 §7: parse the join key; a malformed value is surfaced as
         a read drop and reads as [None] — never repaired. *)
      match opt_string "turn_ref" with
      | None -> None
      | Some s -> (
          match Ids.Turn_ref.of_string s with
          | Some _ as tr -> tr
          | None ->
              report_persistence_read_drop
                ~reason:Read_drop_reason.Invalid_payload
                ~path:file_path
                ~detail:(Printf.sprintf "invalid turn_ref %S" s);
              None)
    in
    let stream_lifecycle =
      match Json_util.assoc_member_opt "stream_lifecycle" json with
      | None -> None
      | Some stream_lifecycle_json ->
          parse_stream_lifecycle ~path:file_path stream_lifecycle_json
    in
    let approval_lifecycle =
      match Json_util.assoc_member_opt "approval_lifecycle" json with
      | None -> None
      | Some lifecycle_json ->
        parse_approval_lifecycle ~path:file_path lifecycle_json
    in
    let delivery_provenance =
      (* Same read-drop convention as [turn_ref]: a malformed persisted
         value is surfaced and reads as [None] — the row stays valid.
         This reader only renders, so it can carry on without the
         provenance; [provenance_of_line] decodes the same pair through
         the same function but must fail its transaction instead, because
         a skipped row there would answer "not appended yet" for a
         delivery that is already on disk. *)
      match json with
      | `Assoc fields -> (
          match
            Keeper_chat_delivery_identity.delivery_provenance_of_fields fields
          with
          | Ok None -> None
          | Ok (Some provenance) -> Some provenance
          | Error detail ->
              report_persistence_read_drop
                ~reason:Read_drop_reason.Invalid_payload
                ~path:file_path
                ~detail:(Printf.sprintf "invalid delivery provenance: %s" detail);
              None)
      | _ -> None
    in
    let delivery_execution_identity_valid =
      match delivery_provenance with
      | Some provenance ->
        let validated = match json with
          | `Assoc fields -> validate_delivery_fields ~provenance fields
          | _ -> Error "delivery row must be an object" in
        (match validated with
         | Ok () -> true
         | Error detail ->
           report_persistence_read_drop
             ~reason:Read_drop_reason.Invalid_payload ~path:file_path
             ~detail:(Printf.sprintf "invalid delivery row identity: %s" detail);
           false)
      | None ->
        (match execution_id_result with
         | Ok _ -> true
         | Error detail ->
          report_persistence_read_drop
            ~reason:Read_drop_reason.Invalid_payload
            ~path:file_path
            ~detail:(Printf.sprintf "invalid execution identity: %s" detail);
          false)
    in
    let has_structured_payload =
      Option.is_some audio
      || Option.exists (fun values -> values <> []) attachments
      || Option.exists (fun values -> values <> []) blocks
      (* A Gate lifecycle row's payload is its typed phase. The store used to
         compose a sentence beside it, so the row also had text and passed
         here by accident; with the sentence gone the row is all typed field,
         and dropping it would delete the durable record of an external
         effect on read. *)
      || Option.is_some approval_lifecycle
      || Option.exists (fun provenance ->
           Keeper_chat_delivery_identity.transcript_slot_is_internal
             provenance.Keeper_chat_delivery_identity.transcript_slot) delivery_provenance
    in
    let message =
      if Option.is_some surface_error then None
      else if not delivery_execution_identity_valid then None
      else if role_label = "" || (content = "" && not has_structured_payload) then (
        report_persistence_read_drop
          ~reason:Read_drop_reason.Invalid_payload
          ~path:file_path
          ~detail:"chat row missing role and readable text/structured payload";
        None)
      else
        match contract_result, Role.of_label role_label with
        | Error _, _ -> None
        | Ok _, None ->
            (* RFC-0232 P1: an unknown role cannot participate in any lane
               semantics (watermark, pending, rendering); surface it
               instead of carrying an untyped row. *)
            report_persistence_read_drop
              ~reason:Read_drop_reason.Invalid_payload
              ~path:file_path
              ~detail:(Printf.sprintf "unknown chat row role %S" role_label);
            None
        | Ok _, Some Role.Tool when tool_call_name = None ->
            report_persistence_read_drop
              ~reason:Read_drop_reason.Invalid_payload
              ~path:file_path
              ~detail:"tool chat row missing non-empty tool_call_name";
            None
        | Ok (),
          Some
            (( Role.User
             | Role.Assistant
             | Role.System
             | Role.Request_failure
             | Role.Tool ) as role) ->
            (match opt_string "id", ts with
             | None, _ ->
                 report_persistence_read_drop
                   ~reason:Read_drop_reason.Invalid_payload
                   ~path:file_path
                   ~detail:"chat row missing nonblank id";
                 None
             | Some _, None ->
                 (* [encode_line] always writes a float [ts]; a row without one
                    cannot be ordered, paged or joined, so it is dropped. *)
                 report_persistence_read_drop
                   ~reason:Read_drop_reason.Invalid_payload
                   ~path:file_path
                   ~detail:"chat row missing float ts";
                 None
             | Some id, Some ts ->
                 Some
                   { id; role; content; ts; attachments; tool_call_id; execution_id;
                     tool_call_name; surface; conversation_id;
                     external_message_id; workspace_id; speaker; audio; blocks;
                     mentions; turn_ref; stream_lifecycle; approval_lifecycle;
                     delivery_provenance })
    in
    { message; strict_decode_error }
  with Yojson.Json_error detail ->
    report_persistence_read_drop
      ~reason:Read_drop_reason.Json_syntax_error
      ~path:file_path
      ~detail;
    { message = None; strict_decode_error = None }

let parse_line ~file_path line =
  (parse_line_decoded ~file_path line).message
;;
