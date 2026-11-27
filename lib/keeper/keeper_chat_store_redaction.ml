open Keeper_chat_types

(* The GitHub CLI credential ([hosts.yml]) lives outside the generic keeper
   secret projection roots (see [Keeper_github_identity]), so the plain
   [snapshot] never captured it and a [gh] token could reach chat rows
   unmasked (#28925 gap 2). The execute-output path already snapshots it
   ([Keeper_tool_execute_runtime]); this brings the chat sink to parity. *)
let redaction_for ~base_dir ~keeper_name =
  Keeper_secret_redaction.snapshot_with_additional_secret_files
    ~redact_identity_scalars:
      (Runtime_params.get Runtime_settings.keeper_chat_redact_identity_scalars)
    ~additional_secret_files:
      (Keeper_github_identity.secret_files_of_base_path
         ~base_path:base_dir
         ~keeper_name)
    ~base_path:base_dir
    ~keeper_name

let redact_attachment redaction (att : attachment) =
  (* Never run text secret-redaction regexes over binary/base64 payloads or
     canonical attachment IDs/URLs. Redact only the human-supplied filename. *)
  { att with name = Keeper_secret_redaction.redact_text redaction att.name }

let att_id_of_url url =
  let trimmed = String.trim url in
  let prefix = Attachment_store.url_prefix in
  let plen = String.length prefix in
  if String.starts_with ~prefix trimmed
  then
    let rest = String.sub trimmed plen (String.length trimmed - plen) in
    let raw_id =
      match String.index_opt rest '?' with
      | Some idx -> String.sub rest 0 idx
      | None -> rest
    in
    match Attachment_store.parse_id raw_id with
    | Ok _ -> Some raw_id
    | Error _ -> None
  else None

let attachment_of_meta ~(fallback_name : string) (meta : Attachment_store.meta) : attachment =
  let name =
    match meta.filename with
    | Some f when String.trim f <> "" -> f
    | Some _ | None ->
      if String.trim fallback_name <> "" then fallback_name else meta.id
  in
  { id = meta.id
  ; att_type = Attachment_store.media_kind_to_string meta.kind
  ; name
  ; size = meta.bytes
  ; mime_type = meta.mime_type
  ; data = Attachment_store.url_of_id meta.id
  ; width = meta.width
  ; height = meta.height
  }

let persist_as_tool_blob ~base_dir ?redaction ~mime ~raw_payload ~width ~height (att : attachment) =
  let trimmed = String.trim raw_payload in
  if String.equal trimmed "" then { att with data = ""; width; height }
  else
    match Tool_output.decode_from_agent_core raw_payload with
    | Tool_output.Decoded _ -> { att with width; height }
    | Tool_output.Not_marker | Tool_output.Invalid_marker _ ->
      let redacted =
        match redaction with
        | Some r -> Keeper_secret_redaction.redact_text r raw_payload
        | None -> raw_payload
      in
      let reference =
        Tool_blob_store.put_durable
          (Tool_blob_store.create ~base_path:base_dir)
          ~bytes:redacted
          ~mime
        |> fun reference -> Tool_output.with_preview reference "attachment payload"
      in
      let data = Tool_output.encode_for_agent_core (Tool_output.Stored reference) in
      { att with
        size = if att.size > 0 then att.size else String.length redacted
      ; data
      ; width
      ; height
      }

let persisted_attachment ?redaction ~base_dir (att : attachment) =
  (* Persist supported binary payloads in [Attachment_store] (never base64 in
     [Tool_blob_store]) and replace [att.data] with the canonical attachment
     URL [/api/v1/attachments/att_<64hex>]. Textual / unsupported attachments
     (e.g. .txt/.md/.csv/.json) and non-base64 payloads are redacted and stored
     durably in [Tool_blob_store] so zero text originals are lost. *)
  let store = Attachment_store.create ~base_path:base_dir in
  let existing_id =
    match Attachment_store.parse_id (String.trim att.id) with
    | Ok _ -> Some (String.trim att.id)
    | Error _ -> att_id_of_url att.data
  in
  match existing_id with
  | Some att_id ->
    (match Attachment_store.get_meta store ~id:att_id with
     | Ok (Some meta) ->
       ignore (Attachment_store.promote_to_durable store ~id:meta.id);
       attachment_of_meta ~fallback_name:att.name meta
     | Ok None | Error _ ->
       { att with
         id = att_id
       ; data = Attachment_store.url_of_id att_id
       })
  | None ->
    let trimmed = String.trim att.data in
    let payload =
      match String.index_opt trimmed ',' with
      | Some comma when String_util.starts_with_ci ~prefix:"data:" trimmed ->
        String.sub trimmed (comma + 1) (String.length trimmed - comma - 1)
      | _ -> trimmed
    in
    let fallback_mime =
      let m = String.trim att.mime_type in
      if String.equal m "" then "text/plain" else m
    in
    match Base64.decode payload with
    | Error _ ->
      persist_as_tool_blob
        ~base_dir
        ?redaction
        ~mime:fallback_mime
        ~raw_payload:att.data
        ~width:att.width
        ~height:att.height
        att
    | Ok bytes ->
      let declared_mime =
        let m = String.trim att.mime_type in
        if String.equal m "" then None else Some m
      in
      let filename =
        let n = String.trim att.name in
        if String.equal n "" then None else Some n
      in
      let stored =
        match
          Attachment_store.put
            ?declared_mime
            ?filename
            ~origin:Attachment_store.User_upload
            ~created_by:"user"
            ~retention:Attachment_store.Durable
            store
            ~bytes
        with
        | Ok meta -> Ok meta
        | Error (Attachment_store.Mime_mismatch _) ->
          Attachment_store.put
            ?filename
            ~origin:Attachment_store.User_upload
            ~created_by:"user"
            ~retention:Attachment_store.Durable
            store
            ~bytes
        | Error
            (( Attachment_store.Empty_payload
             | Attachment_store.Payload_too_large _
             | Attachment_store.Unsupported_or_unknown_format _
             | Attachment_store.Forbidden_mime _
             | Attachment_store.Invalid_keeper_name _
             | Attachment_store.Store_io_failed _ ) as err) -> Error err
      in
      (match stored with
       | Ok meta -> attachment_of_meta ~fallback_name:att.name meta
       | Error (Attachment_store.Store_io_failed msg) ->
         failwith ("attachment store write failed: " ^ msg)
       | Error
           ( Attachment_store.Empty_payload
           | Attachment_store.Payload_too_large _
           | Attachment_store.Unsupported_or_unknown_format _
           | Attachment_store.Forbidden_mime _
           | Attachment_store.Mime_mismatch _
           | Attachment_store.Invalid_keeper_name _ ) ->
         let width, height =
           match Keeper_image_dimensions.image_dimensions bytes with
           | Some (w, h) -> Some w, Some h
           | None -> att.width, att.height
         in
         persist_as_tool_blob
           ~base_dir
           ?redaction
           ~mime:fallback_mime
           ~raw_payload:bytes
           ~width
           ~height
           att)

let redact_tool_call redaction tc =
  { tc with args = Keeper_secret_redaction.redact_text redaction tc.args }

let redact_string redaction value =
  Keeper_secret_redaction.redact_text redaction value

let redact_string_opt redaction =
  Option.map (redact_string redaction)

let redact_trace_json redaction json =
  (* Caller-supplied trace tool args/results can carry a secret embedded in a
     key name (e.g. a header/param used as a dict key), not only in values.
     [redact_json] covers both, so the traversal policy is the redactor's and
     not assembled here. *)
  Keeper_secret_redaction.redact_json redaction json

let redact_table_cell redaction = function
  | Keeper_chat_blocks.Cell_text value ->
    Keeper_chat_blocks.Cell_text (redact_string redaction value)
  | Keeper_chat_blocks.Cell_value { v; num; muted } ->
    Keeper_chat_blocks.Cell_value { v = redact_string redaction v; num; muted }

let redact_trace_step redaction = function
  | Keeper_chat_blocks.Trace_think { text; content_withheld; ts; agent_core_block_index } ->
    Keeper_chat_blocks.Trace_think
      { text = (if content_withheld then "" else redact_string redaction text)
      ; content_withheld
      ; ts = redact_string_opt redaction ts
      ; agent_core_block_index
      }
  | Keeper_chat_blocks.Trace_reason { text; detail; ts } ->
    Keeper_chat_blocks.Trace_reason
      { text = redact_string redaction text
      ; detail = redact_string_opt redaction detail
      ; ts = redact_string_opt redaction ts
      }
  | Keeper_chat_blocks.Trace_tool
      { name
      ; tool_call_id
      ; execution_id
      ; status
      ; dur
      ; args
      ; result
      ; ts
      ; agent_core_block_index
      } ->
    Keeper_chat_blocks.Trace_tool
      { name = redact_string redaction name
      ; tool_call_id = redact_string_opt redaction tool_call_id
      ; execution_id
      ; status
      ; dur = redact_string_opt redaction dur
      ; args = Option.map (redact_trace_json redaction) args
      ; result = Option.map (redact_trace_json redaction) result
      ; ts = redact_string_opt redaction ts
      ; agent_core_block_index
      }

let redact_block redaction = function
  | Keeper_chat_blocks.Text { html } ->
    Keeper_chat_blocks.Text { html = redact_string redaction html }
  | Keeper_chat_blocks.Heading { html } ->
    Keeper_chat_blocks.Heading { html = redact_string redaction html }
  | Keeper_chat_blocks.Unordered_list { items } ->
    Keeper_chat_blocks.Unordered_list
      { items = List.map (redact_string redaction) items }
  | Keeper_chat_blocks.Callout { severity; html } ->
    Keeper_chat_blocks.Callout
      { severity = redact_string_opt redaction severity
      ; html = redact_string redaction html
      }
  | Keeper_chat_blocks.Table { head; rows } ->
    Keeper_chat_blocks.Table
      { head = List.map (redact_table_cell redaction) head
      ; rows = List.map (List.map (redact_table_cell redaction)) rows
      }
  | Keeper_chat_blocks.Code { cap; html; source } ->
    Keeper_chat_blocks.Code
      { cap = redact_string_opt redaction cap
      ; html = redact_string redaction html
      ; source = redact_string_opt redaction source
      }
  | Keeper_chat_blocks.Mermaid { source; caption } ->
    Keeper_chat_blocks.Mermaid
      { source = redact_string redaction source
      ; caption = redact_string_opt redaction caption
      }
  | Keeper_chat_blocks.Chart { chart_type; title; series; labels; x_label; y_label; y_max } ->
    Keeper_chat_blocks.Chart
      { chart_type
      ; title = redact_string redaction title
      ; series =
          List.map
            (fun ({ label; color; values } : Keeper_chat_blocks.chart_series) ->
               { Keeper_chat_blocks.label = redact_string redaction label
               ; color
               ; values
               })
            series
      ; labels = Option.map (List.map (redact_string redaction)) labels
      ; x_label = redact_string_opt redaction x_label
      ; y_label = redact_string_opt redaction y_label
      ; y_max
      }
  | Keeper_chat_blocks.Svg { svg; cap } ->
    Keeper_chat_blocks.Svg
      { svg = redact_string redaction svg
      ; cap = redact_string_opt redaction cap
      }
  | Keeper_chat_blocks.Voice { secs; wave; via; size; transcript; src } ->
    Keeper_chat_blocks.Voice
      { secs
      ; wave
      ; via = redact_string_opt redaction via
      ; size = redact_string_opt redaction size
      ; transcript = redact_string_opt redaction transcript
      ; src = redact_string_opt redaction src
      }
  | Keeper_chat_blocks.Attach
      { name; dims; src; svg; ph; via; size; data; mime_type; size_bytes; kind } ->
    Keeper_chat_blocks.Attach
      { name = redact_string redaction name
      ; dims = redact_string_opt redaction dims
      ; src = redact_string_opt redaction src
      ; svg = redact_string_opt redaction svg
      ; ph = redact_string_opt redaction ph
      ; via = redact_string_opt redaction via
      ; size = redact_string_opt redaction size
      ; data = redact_string_opt redaction data
      ; mime_type = redact_string_opt redaction mime_type
      ; size_bytes
      ; kind = redact_string_opt redaction kind
      }
  | Keeper_chat_blocks.Image { src; cap; mime_type } ->
    Keeper_chat_blocks.Image
      { src = redact_string redaction src
      ; cap = redact_string_opt redaction cap
      ; mime_type = redact_string_opt redaction mime_type
      }
  | Keeper_chat_blocks.Link { url; title; meta } ->
    Keeper_chat_blocks.Link
      { url = redact_string redaction url
      ; title = redact_string redaction title
      ; meta = redact_string redaction meta
      }
  | Keeper_chat_blocks.Fusion { board_post_id; run_id } ->
    (* board_post_id/run_id are opaque, system-generated lookup keys
       (Board.Post_id.to_string -> "p-<hex>", and the fusion run id), not
       free-form content. The dashboard fetches the board post by
       board_post_id and renders its meta_json; these strings are never
       displayed as text. Redacting a key that is never shown cannot
       protect a secret — it can only corrupt the fusion linkage so the
       lazy-fetch by id fails. Skip redaction at the field level: both
       fields are destructured and reconstructed (not [Fusion _]) so
       adding a new fusion field breaks compilation and forces a redaction
       decision. This is a structural exclusion of an id field, not a
       string-pattern exception. *)
    Keeper_chat_blocks.Fusion { board_post_id; run_id }
  | Keeper_chat_blocks.Status { kind } ->
    Keeper_chat_blocks.Status { kind }
  | Keeper_chat_blocks.Trace { trace; omitted } ->
    Keeper_chat_blocks.Trace
      { trace = List.map (redact_trace_step redaction) trace; omitted }
  | Keeper_chat_blocks.Thinking { content; redacted } ->
    Keeper_chat_blocks.Thinking
      { content = redact_string redaction content; redacted }

let redact_blocks redaction =
  Option.map (List.map (redact_block redaction))

let redact_audio redaction a =
  { a with
    audio_url = Option.map (redact_string redaction) a.audio_url;
    message_text = redact_string redaction a.message_text;
  }

let redact_approval_lifecycle redaction lifecycle =
  let artifact_ref =
    Option.map
      (fun artifact_ref ->
        Tool_output.with_preview
          artifact_ref
          (redact_string redaction artifact_ref.Tool_output.preview))
      lifecycle.artifact_ref
  in
  { lifecycle with
    tool_name = Option.map (redact_string redaction) lifecycle.tool_name
  ; call_summary = Option.map (redact_string redaction) lifecycle.call_summary
  ; artifact_ref
  }

let redact_message redaction msg =
  let attachments =
    Option.map (List.map (redact_attachment redaction)) msg.attachments
  in
  let blocks = redact_blocks redaction msg.blocks in
  let audio = Option.map (redact_audio redaction) msg.audio in
  let approval_lifecycle =
    Option.map (redact_approval_lifecycle redaction) msg.approval_lifecycle
  in
  let content =
    let redacted = Keeper_secret_redaction.redact_text redaction msg.content in
    match msg.role with
    | Role.Request_failure -> Keeper_request_failure.sanitize_person_text redacted
    | Role.User | Role.Assistant | Role.System | Role.Tool -> redacted
  in
  { msg with
    content;
    attachments;
    blocks;
    audio;
    approval_lifecycle;
  }
