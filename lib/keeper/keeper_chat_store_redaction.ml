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

let redact_attachment redaction att =
  { att with data = Keeper_secret_redaction.redact_text redaction att.data }

let persisted_attachment ~base_dir (att : attachment) =
  (* Measure dimensions before replacing inline data with a durable reference.
     History pages then carry metadata without fetching image payloads. Gate connectors send
     [data:<mime>;base64,<payload>] URIs and the TUI sends bare base64;
     both decode here, and a payload that decodes to nothing parseable just
     leaves the size unset. *)
  let decoded_dimensions data =
    let data = String.trim data in
    let payload =
      match String.index_opt data ',' with
      | Some comma when String_util.starts_with_ci ~prefix:"data:" data ->
          String.sub data (comma + 1) (String.length data - comma - 1)
      | _ -> data
    in
    match Base64.decode payload with
    | Error _ -> None
    | Ok bytes -> Keeper_image_dimensions.image_dimensions bytes
  in
  let width, height =
    match decoded_dimensions att.data with
    | Some (width, height) -> (Some width, Some height)
    | None -> (att.width, att.height)
  in
  let reference =
    Tool_blob_store.put_durable (Tool_blob_store.create ~base_path:base_dir)
      ~bytes:att.data ~mime:"text/plain"
    |> fun reference -> Tool_output.with_preview reference "attachment payload"
  in
  let data = Tool_output.encode_for_agent_core (Tool_output.Stored reference) in
  { att with data; width; height }

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
  | Keeper_chat_blocks.Image { src; cap } ->
    Keeper_chat_blocks.Image
      { src = redact_string redaction src
      ; cap = redact_string_opt redaction cap
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
  { msg with
    content = Keeper_secret_redaction.redact_text redaction msg.content;
    attachments;
    blocks;
    audio;
    approval_lifecycle;
  }
