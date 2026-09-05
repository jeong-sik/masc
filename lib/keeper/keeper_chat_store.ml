(** Keeper_chat_store — JSONL-based persistence for keeper direct messages.

    Each keeper gets a file: [<base_dir>/.masc/keeper_chat/<name>.jsonl]
    Lines are append-only with timestamps.

    Line format:
    {v {"id":"msg-...","role":"user","content":"hello","ts":1774000000.0} v}

    Tool-call lines (persisted between the user and assistant lines of a
    turn) carry the executed tool name and accumulated arguments:
    {v {"id":"msg-...","role":"tool","content":"{\"path\":\"x\"}","ts":...,
        "tool_call_id":"toolu_1","tool_call_name":"Read",
        "surface":{"kind":"dashboard"}} v}

    Connector rows may additionally carry opaque route coordinates:
    [conversation_id] for channel/thread grouping and [external_message_id]
    for the inbound platform message. The store does not interpret these
    values.

    @since 2.145.0 *)

let sanitize_name name =
  Workspace_utils_backend_setup.sanitize_namespace_segment name

let chat_dir base_dir =
  Filename.concat (Common.masc_dir_from_base_path ~base_path:base_dir) "keeper_chat"

let chat_path ~base_dir ~keeper_name =
  Filename.concat (chat_dir base_dir) (sanitize_name keeper_name ^ ".jsonl")

let persistence_surface = "keeper_chat_store"

let record_persistence_read_drop ~reason () =
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_persistence_read_drops
    ~labels:[("surface", persistence_surface); ("reason", reason)]
    ()

let report_persistence_read_drop ~reason ~path ~detail =
  let reason_wire = Read_drop_reason.to_wire reason in
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () -> record_persistence_read_drop ~reason:reason_wire ())
    ~surface:persistence_surface
    ~reason
    ~path
    ~detail

let ensure_dir_once ~base_dir =
  ignore (Keeper_fs.ensure_dir (chat_dir base_dir))

type attachment = {
  id : string;
  att_type : string;
  name : string;
  size : int;
  mime_type : string;
  data : string;
  (* Pixel size, set once at the moment the bytes are swapped out for their
     [masc://] reference: after [persisted_attachment] the bytes are gone and
     the size is no longer derivable, so this field is the only memory of
     them. [None] is a normal value -- WebP, documents, and rows written
     before the field existed all read as None and the note shows without a
     size. *)
  width : int option;
  height : int option;
}

type tool_call = {
  call_id : string;
  execution_id : Ids.Execution_id.t option;
  call_name : string;
  args : string;
}

(* RFC-0232 P1: the lane role is a closed sum parsed once at the read
   boundary; consumers match exhaustively instead of comparing role
   strings. On-disk labels are unchanged ("user"/"assistant"/"tool"). *)
module Role = struct
  type t =
    | User
    | Assistant
    | System
    | Tool

  let to_label = function
    | User -> "user"
    | Assistant -> "assistant"
    | System -> "system"
    | Tool -> "tool"

  let of_label = function
    | "user" -> Some User
    | "assistant" -> Some Assistant
    | "system" -> Some System
    | "tool" -> Some Tool
    | _ -> None

  let equal a b =
    match a, b with
    | User, User | Assistant, Assistant | System, System | Tool, Tool -> true
    | (User | Assistant | System | Tool), _ -> false
end

(* What an assistant line *is*, declared by the writer at append time.
   [Utterance] is something the keeper actually said; [Transport_failure]
   is the server persisting a failed request terminal ("Keeper request
   failed: ...") so the operator still sees the failure after a reload.
   Readers branch on the type: a transport failure is not a self reply —
   it does not advance the lane watermark, so the user line it failed to
   answer stays pending until the keeper's next real utterance — and it
   is never quoted back as the keeper's own words. On disk the field is
   ["kind"], absent for utterances so pre-existing rows read unchanged. *)
module Row_kind = struct
  type t =
    | Utterance
    | Transport_failure

  let to_label = function
    | Utterance -> "utterance"
    | Transport_failure -> "transport_failure"

  let of_label = function
    | "utterance" -> Some Utterance
    | "transport_failure" -> Some Transport_failure
    | _ -> None

  let equal a b =
    match a, b with
    | Utterance, Utterance | Transport_failure, Transport_failure -> true
    | (Utterance | Transport_failure), _ -> false
end

type stream_lifecycle_event =
  | Run_started
  | Text_message_start
  | Text_message_end
  | Run_finished
  | Run_error

type approval_lifecycle_phase =
  | Approval_requested
  | Approval_resolved_approved
  | Approval_resolved_rejected
  | Approval_replay_applied
  | Approval_replay_applied_with_warning
  | Approval_replay_failed
  | Approval_replay_indeterminate
  | Approval_continuation_recorded

type approval_lifecycle =
  { approval_id : string
  ; tool_name : string option
  ; phase : approval_lifecycle_phase
  ; artifact_ref : Tool_output.artifact_ref option
  ; call_summary : string option
  }

type append_once_result =
  | Appended of { row_id : string }
  | Already_present of { row_id : string }

type user_row_origin =
  | Needs_append
  | Already_persisted of { row_id : string }
  | Already_persisted_upstream

let stream_lifecycle_event_to_label = function
  | Run_started -> "RUN_STARTED"
  | Text_message_start -> "TEXT_MESSAGE_START"
  | Text_message_end -> "TEXT_MESSAGE_END"
  | Run_finished -> "RUN_FINISHED"
  | Run_error -> "RUN_ERROR"

let stream_lifecycle_event_of_label = function
  | "RUN_STARTED" -> Some Run_started
  | "TEXT_MESSAGE_START" -> Some Text_message_start
  | "TEXT_MESSAGE_END" -> Some Text_message_end
  | "RUN_FINISHED" -> Some Run_finished
  | "RUN_ERROR" -> Some Run_error
  | _ -> None

let approval_lifecycle_phase_to_label = function
  | Approval_requested -> "requested"
  | Approval_resolved_approved -> "resolved_approved"
  | Approval_resolved_rejected -> "resolved_rejected"
  | Approval_replay_applied -> "replay_applied"
  | Approval_replay_applied_with_warning -> "replay_applied_with_warning"
  | Approval_replay_failed -> "replay_failed"
  | Approval_replay_indeterminate -> "replay_indeterminate"
  | Approval_continuation_recorded -> "continuation_recorded"
;;

let approval_lifecycle_phase_of_label = function
  | "requested" -> Some Approval_requested
  | "resolved_approved" -> Some Approval_resolved_approved
  | "resolved_rejected" -> Some Approval_resolved_rejected
  | "replay_applied" -> Some Approval_replay_applied
  | "replay_applied_with_warning" -> Some Approval_replay_applied_with_warning
  | "replay_failed" -> Some Approval_replay_failed
  | "replay_indeterminate" -> Some Approval_replay_indeterminate
  | "continuation_recorded" -> Some Approval_continuation_recorded
  | _ -> None
;;

type speaker_authority =
  | Owner
  | External

let authority_label = function
  | Owner -> "owner"
  | External -> "external"

let authority_of_label = function
  | "owner" -> Some Owner
  | "external" -> Some External
  | _ -> None

type chat_block = Keeper_chat_blocks.chat_block

type audio_clip = {
  token : string;
  audio_url : string option;
  mime : string;
  duration_sec : float option;
  message_text : string;
  device_id : string option;
  expired : bool;
}

type speaker = {
  speaker_id : string option;
  speaker_name : string option;
  speaker_authority : speaker_authority;
}

type chat_message = {
  id : string;
      (* R3: producer-assigned stable message id.  Minted once at append
         by [encode_line] (the sole writer) and read back verbatim, so the
         dashboard keys off a server identity instead of synthesising an
         index-derived id at render. Rows without a nonblank persisted id
         are rejected at the read boundary. *)
  role : Role.t;
  content : string;
  ts : float;
  attachments : attachment list option;
  tool_call_id : string option;
  execution_id : Ids.Execution_id.t option;
  tool_call_name : string option;
  surface : Surface_ref.t option;
      (* RFC-0232 P5: the typed surface, persisted as a structured
         [surface] field.  [None] on rows written before P5. *)
  conversation_id : string option;
  external_message_id : string option;
  workspace_id : string option;
  speaker : speaker option;
  audio : audio_clip option;
  blocks : Keeper_chat_blocks.chat_block list option;
      (* RFC-0235 P3: rich chat blocks parsed from assistant reply text.
         Persisted server-side so the dashboard can prefer backend blocks
         over its local parser. [None] on rows written before this field
         and on non-assistant rows. *)
  mentions : Keeper_identity.Keeper_id.t list;
      (* RFC-0232 §3.3: parsed once at append from the persisted content
         (plus connector-provided explicit mentions); [] = none.  Rows
         written before P4 lack the field and read as []; the offline
         backfill tool stamps them. *)
  kind : Row_kind.t;
      (* Declared by the writer at append.  Absent field (every row
         written before this field existed) reads as [Utterance]; an
         unknown label is reported as a persistence read drop and the
         row reads as [Utterance] (the conservative arm: it renders and
         advances the watermark like any reply). *)
  turn_ref : Ids.Turn_ref.t option;
      (* RFC-0233 §7: "<trace_id>#<absolute_turn>" join key for the turn
         that produced this row.  Stamped by [append_turn] /
         [append_assistant_message] when the caller supplies it; [None] on
         inbound user lines (no turn yet) and rows written before §7.  A
         malformed persisted value is reported as a persistence read drop
         and reads as [None]; the row stays valid. *)
  stream_lifecycle : stream_lifecycle_event list option;
      (* K1f: closed list of server lifecycle events for the direct chat
         stream response represented by this row. [None] means pre-K1f row or
         no lifecycle proof. Malformed persisted values are reported and read
         as [None], keeping the row valid. *)
  approval_lifecycle : approval_lifecycle option;
  delivery_provenance :
    Keeper_chat_delivery_identity.delivery_provenance option;
      (* The exact delivery identity and transcript slot persisted atomically
         by the idempotent append-once paths.  [None] on rows written by the
         plain append paths and on rows written before this pair existed.  A
         malformed persisted value is reported as a persistence read drop and
         reads as [None]; the row stays valid. *)
}

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

let persisted_attachment_ref (att : attachment) =
  (* SHA-256, not Stdlib.Digest (MD5): this is attachment content identity,
     not a display checksum (#26720). Nothing reads the digest back out of the
     URI — [att.id] is the locator — so rows written before this keep working. *)
  let digest = Digestif.SHA256.(digest_string att.data |> to_hex) in
  Printf.sprintf "masc://attachment/%s/%s" att.id digest

let persisted_attachment (att : attachment) =
  (* The last place the bytes exist: the reference that replaces them cannot
     answer "how big was it", so the pixel size is read here, once, from the
     same payload the provider request was built from. Gate connectors send
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
  { att with data = persisted_attachment_ref att; width; height }

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

let speaker_fields = function
  | None -> []
  | Some sp ->
      Json_util.string_field_if_present "speaker_id" sp.speaker_id
      @ Json_util.string_field_if_present "speaker_name" sp.speaker_name
      @ [ ("speaker_authority", `String (authority_label sp.speaker_authority)) ]

(* RFC-0235 P1: nested ["audio"] assoc so the clip stays one unit on the
   JSONL row. Absent on rows written before voice transport; reads as
   [None] (the dashboard renders text-only, matching any non-voice turn).
   [expired] is written only when true so fresh clips stay byte-identical
   to rows written before this field existed; the history endpoint stamps
   it when the underlying MP3 has been reaped. *)
let audio_to_json a =
  let base =
    [ ("token", `String a.token)
    ; ("mime", `String a.mime)
    ; ("message_text", `String a.message_text)
    ]
  in
  let with_optional =
    base
    |> fun fs ->
    (match a.audio_url with
     | None -> fs
     | Some url -> fs @ [ ("audio_url", `String url) ])
    |> fun fs ->
    (match a.duration_sec with
     | None -> fs
     | Some d -> fs @ [ ("duration_sec", `Float d) ])
    |> fun fs ->
    (match a.device_id with
     | None -> fs
     | Some id -> fs @ [ ("device_id", `String id) ])
  in
  if a.expired then with_optional @ [ ("expired", `Bool true) ] else with_optional

let audio_fields = function
  | None -> []
  | Some a -> [ ("audio", `Assoc (audio_to_json a)) ]

let blocks_fields = function
  | None | Some [] -> []
  | Some blocks -> [ ("blocks", Keeper_chat_blocks.blocks_to_yojson blocks) ]
;;

let stream_lifecycle_fields = function
  | None | Some [] -> []
  | Some events ->
      [
        ( "stream_lifecycle",
          `List
            (List.map
               (fun event -> `String (stream_lifecycle_event_to_label event))
               events) );
      ]

let approval_lifecycle_to_json lifecycle =
  `Assoc
    ([ "approval_id", `String lifecycle.approval_id
     ; "phase", `String (approval_lifecycle_phase_to_label lifecycle.phase)
     ]
     @ Json_util.string_field_if_present "tool_name" lifecycle.tool_name
     @ Json_util.string_field_if_present "call_summary" lifecycle.call_summary
     @ (match lifecycle.artifact_ref with
        | None -> []
        | Some artifact_ref ->
          [ "artifact_ref", Tool_output.normalized_artifact_ref_to_json artifact_ref ]))
;;

let approval_lifecycle_fields = function
  | None -> []
  | Some lifecycle -> [ "approval_lifecycle", approval_lifecycle_to_json lifecycle ]
;;

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
               | Approval_continuation_recorded -> false
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

let encode_line ~(role : Role.t) ~content ~ts ?message_id ?attachments ?tool_call_id
    ?execution_id ?tool_call_name ?surface ?conversation_id ?external_message_id ?workspace_id
    ?speaker
    ?audio ?blocks ?(mentions = []) ?(kind = Row_kind.Utterance) ?turn_ref
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
  (* Backend-driven chat blocks: assistant rows get a default parse unless
     the caller already supplied blocks (e.g., a future rich-content path).
     Tool and user rows carry no blocks. *)
  let blocks =
    match blocks with
    | Some _ -> blocks
    | None ->
      if Role.equal role Role.Assistant && String.trim content <> ""
      then Some (Keeper_chat_blocks.parse_text_to_blocks content)
      else None
  in
  let mention_fields =
    match mentions with
    | [] -> []
    | ids ->
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
  (* Utterance is the absent-field default so rows written before the
     [kind] field existed and ordinary rows stay byte-identical. *)
  let kind_field =
    match kind with
    | Row_kind.Utterance -> []
    | Row_kind.Transport_failure ->
        [ ("kind", `String (Row_kind.to_label kind)) ]
  in
  let all_fields =
    base_fields
    @ attachment_fields
    @ mention_fields
    @ kind_field
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

(* The append-once reader answers "does this exact delivery already have a
   row?". A structurally decodable provenance whose execution identity is
   inconsistent is quarantined by its exact delivery key: a replay of that
   delivery fails closed, while unrelated future operations in the same JSONL
   remain writable. Fully undecodable provenance still fails the scan because
   no key can prove its blast radius. The rendering reader below can instead
   drop an invalid row because it never authorizes an append. *)
let execution_id_of_fields fields =
  match List.assoc_opt "execution_id" fields with
  | None -> Ok None
  | Some (`String raw) when String.trim raw <> "" ->
    Ok (Some (Ids.Execution_id.of_string raw))
  | Some (`String _) -> Error "row execution_id must not be blank"
  | Some _ -> Error "row execution_id must be a string"
;;

let validate_delivery_execution_identity ~execution_id
    (provenance : Keeper_chat_delivery_identity.delivery_provenance option) =
  match provenance with
  | None -> Ok ()
  | Some { transcript_slot; _ } -> (
      match transcript_slot, execution_id with
      | Keeper_chat_delivery_identity.Tool_call { execution_id = slot_id; _ },
        Some row_id
        when Ids.Execution_id.equal slot_id row_id ->
          Ok ()
      | Keeper_chat_delivery_identity.Tool_call _, Some _ ->
          Error "tool_call transcript slot conflicts with row execution_id"
      | Keeper_chat_delivery_identity.Tool_call _, None ->
          Error "tool_call transcript slot requires the same row execution_id"
      | Keeper_chat_delivery_identity.Tool_delivery _, None -> Ok ()
      | Keeper_chat_delivery_identity.Tool_delivery _, Some _ ->
          Error "tool_delivery transcript slot forbids row execution_id"
      | ( Keeper_chat_delivery_identity.Accepted_user
        | Keeper_chat_delivery_identity.Terminal_assistant
        | Keeper_chat_delivery_identity.Approval_request
        | Keeper_chat_delivery_identity.Approval_resolution
        | Keeper_chat_delivery_identity.Approval_replay
        | Keeper_chat_delivery_identity.Approval_replay_correction
        | Keeper_chat_delivery_identity.Approval_continuation ),
        None ->
          Ok ()
      | ( Keeper_chat_delivery_identity.Accepted_user
        | Keeper_chat_delivery_identity.Terminal_assistant
        | Keeper_chat_delivery_identity.Approval_request
        | Keeper_chat_delivery_identity.Approval_resolution
        | Keeper_chat_delivery_identity.Approval_replay
        | Keeper_chat_delivery_identity.Approval_replay_correction
        | Keeper_chat_delivery_identity.Approval_continuation ),
        Some _ ->
          Error "non-tool transcript slot forbids row execution_id")
;;

let validate_delivery_role ~role_label
    (provenance : Keeper_chat_delivery_identity.delivery_provenance) =
  match provenance.transcript_slot, role_label with
  | Keeper_chat_delivery_identity.Accepted_user, "user"
  | Keeper_chat_delivery_identity.Terminal_assistant, "assistant"
  | ( Keeper_chat_delivery_identity.Approval_request
    | Keeper_chat_delivery_identity.Approval_resolution
    | Keeper_chat_delivery_identity.Approval_replay
    | Keeper_chat_delivery_identity.Approval_replay_correction
    | Keeper_chat_delivery_identity.Approval_continuation ),
    "system"
  | ( Keeper_chat_delivery_identity.Tool_call _
    | Keeper_chat_delivery_identity.Tool_delivery _ ),
    "tool" ->
    Ok ()
  | Keeper_chat_delivery_identity.Accepted_user, _ ->
    Error "accepted_user transcript slot requires a user row"
  | Keeper_chat_delivery_identity.Terminal_assistant, _ ->
    Error "terminal_assistant transcript slot requires an assistant row"
  | ( Keeper_chat_delivery_identity.Approval_request
    | Keeper_chat_delivery_identity.Approval_resolution
    | Keeper_chat_delivery_identity.Approval_replay
    | Keeper_chat_delivery_identity.Approval_replay_correction
    | Keeper_chat_delivery_identity.Approval_continuation ),
    _ ->
    Error "approval lifecycle transcript slot requires a system row"
  | ( Keeper_chat_delivery_identity.Tool_call _
    | Keeper_chat_delivery_identity.Tool_delivery _ ),
    _ ->
    Error "tool transcript slot requires a tool row"
;;

type scanned_provenance =
  | No_provenance
  | Valid_provenance of
      Keeper_chat_delivery_identity.delivery_provenance * string
  | Poisoned_delivery_key of
      Keeper_chat_delivery_identity.delivery_key * string

let provenance_of_line ~line_number line =
  let fail detail =
    Error
      (Printf.sprintf
         "keeper chat provenance decode failed at line %d: %s"
         line_number
         detail)
  in
  try
    match Yojson.Safe.from_string line with
    | `Assoc fields ->
      (match
         Keeper_chat_delivery_identity.delivery_provenance_of_fields fields
       with
       | Error detail -> fail detail
       | Ok None -> Ok No_provenance
       | Ok (Some provenance) ->
         let role_label =
           match List.assoc_opt "role" fields with
           | Some (`String value) -> value
           | Some _ | None -> ""
         in
         (match validate_delivery_role ~role_label provenance with
          | Error detail ->
            Ok
              (Poisoned_delivery_key
                 (provenance.delivery_key, detail))
          | Ok () ->
            (match execution_id_of_fields fields with
             | Error detail ->
               Ok
                 (Poisoned_delivery_key
                    (provenance.delivery_key, detail))
             | Ok execution_id ->
               (match
                  validate_delivery_execution_identity
                    ~execution_id
                    (Some provenance)
                with
                | Error detail ->
                  Ok
                    (Poisoned_delivery_key
                       (provenance.delivery_key, detail))
                | Ok () ->
                  (match List.assoc_opt "id" fields with
                   | Some (`String row_id)
                     when not (String.equal (String.trim row_id) "") ->
                     Ok (Valid_provenance (provenance, row_id))
                   | _ -> fail "provenance row requires a nonblank id")))))
    | _ -> fail "row must be a JSON object"
  with
  | Yojson.Json_error detail -> fail detail
;;

module Provenance_key = struct
  type t = Keeper_chat_delivery_identity.delivery_provenance

  let equal = Keeper_chat_delivery_identity.delivery_provenance_equal
  let hash = Hashtbl.hash
end

module Provenance_index = Hashtbl.Make (Provenance_key)

module Delivery_key = struct
  type t = Keeper_chat_delivery_identity.delivery_key

  let equal = Keeper_chat_delivery_identity.delivery_key_equal
  let hash = Hashtbl.hash
end

module Poisoned_delivery_keys = Hashtbl.Make (Delivery_key)

module Tool_ordinal = struct
  type t = Keeper_chat_delivery_identity.delivery_key * int

  let equal (left_key, left_ordinal) (right_key, right_ordinal) =
    Keeper_chat_delivery_identity.delivery_key_equal left_key right_key
    && Int.equal left_ordinal right_ordinal
  ;;

  let hash = Hashtbl.hash
end

module Tool_ordinal_index = Hashtbl.Make (Tool_ordinal)

module Execution_id_key = struct
  type t = Ids.Execution_id.t

  let equal = Ids.Execution_id.equal
  let hash = Hashtbl.hash
end

module Execution_index = Hashtbl.Make (Execution_id_key)

type indexed_provenance =
  | Unique_provenance of string
  | Duplicate_provenance

type indexed_tool_ordinal =
  | Unique_tool_ordinal of
      Keeper_chat_delivery_identity.transcript_slot * string
  | Duplicate_tool_ordinal

type execution_owner =
  { delivery_key : Keeper_chat_delivery_identity.delivery_key
  ; ordinal : int
  }

type indexed_execution =
  | Unique_execution of execution_owner
  | Reused_execution

type provenance_index =
  { valid : indexed_provenance Provenance_index.t
  ; poisoned_delivery_keys : string Poisoned_delivery_keys.t
  ; tool_ordinals : indexed_tool_ordinal Tool_ordinal_index.t
  ; executions : indexed_execution Execution_index.t
  }

let poison_delivery_key index delivery_key detail =
  Poisoned_delivery_keys.replace index.poisoned_delivery_keys delivery_key detail
;;

let execution_owner_matches owner ~delivery_key ~ordinal =
  Keeper_chat_delivery_identity.delivery_key_equal owner.delivery_key delivery_key
  && Int.equal owner.ordinal ordinal
;;

let register_execution_identity index ~delivery_key ~ordinal execution_id =
  match Execution_index.find_opt index.executions execution_id with
  | None ->
    Execution_index.add index.executions execution_id
      (Unique_execution { delivery_key; ordinal })
  | Some (Unique_execution owner)
    when execution_owner_matches owner ~delivery_key ~ordinal ->
    ()
  | Some (Unique_execution owner) ->
    let detail =
      "canonical Keeper execution_id is reused by a different delivery or tool ordinal"
    in
    poison_delivery_key index owner.delivery_key detail;
    poison_delivery_key index delivery_key detail;
    Execution_index.replace index.executions execution_id Reused_execution
  | Some Reused_execution ->
    poison_delivery_key index delivery_key
      "canonical Keeper execution_id is already reused by multiple deliveries or tool ordinals"
;;

let provenance_index_of_existing existing =
  let index =
    { valid = Provenance_index.create 16
    ; poisoned_delivery_keys = Poisoned_delivery_keys.create 16
    ; tool_ordinals = Tool_ordinal_index.create 16
    ; executions = Execution_index.create 16
    }
  in
  let add_provenance (provenance, row_id) =
    (match Provenance_index.find_opt index.valid provenance with
     | None ->
       Provenance_index.add index.valid provenance (Unique_provenance row_id)
     | Some (Unique_provenance _ | Duplicate_provenance) ->
       Provenance_index.replace index.valid provenance Duplicate_provenance;
       poison_delivery_key index provenance.delivery_key
         "duplicate Keeper chat delivery provenance rows");
    let ordinal =
      match provenance.Keeper_chat_delivery_identity.transcript_slot with
      | Keeper_chat_delivery_identity.Tool_call { ordinal; _ }
      | Keeper_chat_delivery_identity.Tool_delivery { ordinal } -> Some ordinal
      | Keeper_chat_delivery_identity.Accepted_user
      | Keeper_chat_delivery_identity.Terminal_assistant
      | Keeper_chat_delivery_identity.Approval_request
      | Keeper_chat_delivery_identity.Approval_resolution
      | Keeper_chat_delivery_identity.Approval_replay
      | Keeper_chat_delivery_identity.Approval_replay_correction
      | Keeper_chat_delivery_identity.Approval_continuation -> None
    in
    Option.iter
      (fun ordinal ->
         let key = provenance.delivery_key, ordinal in
         match Tool_ordinal_index.find_opt index.tool_ordinals key with
         | None ->
           Tool_ordinal_index.add
             index.tool_ordinals
             key
             (Unique_tool_ordinal (provenance.transcript_slot, row_id))
         | Some (Unique_tool_ordinal _ | Duplicate_tool_ordinal) ->
           Tool_ordinal_index.replace
             index.tool_ordinals
             key
             Duplicate_tool_ordinal;
           poison_delivery_key index provenance.delivery_key
             "duplicate Keeper chat tool ordinal rows")
      ordinal;
    match provenance.transcript_slot with
    | Keeper_chat_delivery_identity.Tool_call { execution_id; ordinal } ->
      register_execution_identity index ~delivery_key:provenance.delivery_key
        ~ordinal execution_id
    | Keeper_chat_delivery_identity.Accepted_user
    | Keeper_chat_delivery_identity.Tool_delivery _
    | Keeper_chat_delivery_identity.Terminal_assistant
    | Keeper_chat_delivery_identity.Approval_request
    | Keeper_chat_delivery_identity.Approval_resolution
    | Keeper_chat_delivery_identity.Approval_replay
    | Keeper_chat_delivery_identity.Approval_replay_correction
    | Keeper_chat_delivery_identity.Approval_continuation -> ()
  in
  existing
  |> String.split_on_char '\n'
  |> List.mapi (fun offset line -> offset + 1, line)
  |> List.fold_left
       (fun result (line_number, line) ->
          let ( let* ) = Result.bind in
          let* () = result in
          if String.equal line ""
          then Ok ()
          else
            let* provenance = provenance_of_line ~line_number line in
            (match provenance with
             | No_provenance -> ()
             | Valid_provenance (provenance, row_id) ->
               add_provenance (provenance, row_id)
             | Poisoned_delivery_key (delivery_key, detail) ->
               Poisoned_delivery_keys.replace
                 index.poisoned_delivery_keys
                 delivery_key
                 detail);
            Ok ())
       (Ok ())
  |> Result.map (fun () -> index)
;;

let find_indexed_provenance index ~provenance =
  match
    Poisoned_delivery_keys.find_opt
      index.poisoned_delivery_keys
      provenance.Keeper_chat_delivery_identity.delivery_key
  with
  | Some detail ->
    Error
      (Printf.sprintf
         "Keeper chat delivery key has quarantined invalid provenance: %s"
         detail)
  | None ->
    let execution_identity_available =
      match provenance.Keeper_chat_delivery_identity.transcript_slot with
      | Keeper_chat_delivery_identity.Tool_call { execution_id; ordinal } ->
        (match Execution_index.find_opt index.executions execution_id with
         | None -> Ok ()
         | Some (Unique_execution owner)
           when execution_owner_matches owner
                  ~delivery_key:provenance.delivery_key
                  ~ordinal ->
           Ok ()
         | Some (Unique_execution _) ->
           Error
             "canonical Keeper execution_id belongs to a different delivery or tool ordinal"
         | Some Reused_execution ->
           Error
             "canonical Keeper execution_id is reused by multiple deliveries or tool ordinals")
      | Keeper_chat_delivery_identity.Accepted_user
      | Keeper_chat_delivery_identity.Tool_delivery _
      | Keeper_chat_delivery_identity.Terminal_assistant
      | Keeper_chat_delivery_identity.Approval_request
      | Keeper_chat_delivery_identity.Approval_resolution
      | Keeper_chat_delivery_identity.Approval_replay
      | Keeper_chat_delivery_identity.Approval_replay_correction
      | Keeper_chat_delivery_identity.Approval_continuation -> Ok ()
    in
    let ( let* ) = Result.bind in
    let* () = execution_identity_available in
    let ordinal =
      match provenance.Keeper_chat_delivery_identity.transcript_slot with
      | Keeper_chat_delivery_identity.Tool_call { ordinal; _ }
      | Keeper_chat_delivery_identity.Tool_delivery { ordinal } -> Some ordinal
      | Keeper_chat_delivery_identity.Accepted_user
      | Keeper_chat_delivery_identity.Terminal_assistant
      | Keeper_chat_delivery_identity.Approval_request
      | Keeper_chat_delivery_identity.Approval_resolution
      | Keeper_chat_delivery_identity.Approval_replay
      | Keeper_chat_delivery_identity.Approval_replay_correction
      | Keeper_chat_delivery_identity.Approval_continuation -> None
    in
    (match
       Option.bind ordinal (fun ordinal ->
         Tool_ordinal_index.find_opt
           index.tool_ordinals
           (provenance.delivery_key, ordinal))
     with
     | Some (Unique_tool_ordinal (existing_slot, row_id)) ->
       if
         Keeper_chat_delivery_identity.transcript_slot_equal
           existing_slot
           provenance.transcript_slot
       then Ok (Some row_id)
       else
         Error
           "Keeper chat tool ordinal is occupied by a conflicting execution identity"
     | Some Duplicate_tool_ordinal ->
       Error "duplicate Keeper chat tool ordinal rows"
     | None ->
       (match Provenance_index.find_opt index.valid provenance with
        | None -> Ok None
        | Some (Unique_provenance row_id) -> Ok (Some row_id)
        | Some Duplicate_provenance ->
          Error "duplicate Keeper chat delivery provenance rows"))
;;

let find_provenance existing ~provenance =
  let ( let* ) = Result.bind in
  let* index = provenance_index_of_existing existing in
  find_indexed_provenance index ~provenance
;;

let append_line_once path ~provenance ~row_id line =
  match
    Fs_compat.update_private_file_durable_locked_result path (fun existing ->
      match find_provenance existing ~provenance with
      | Error detail -> None, Error detail
      | Ok (Some existing_row_id) ->
        None, Ok (Already_present { row_id = existing_row_id })
      | Ok None -> Some (line ^ "\n"), Ok (Appended { row_id }))
  with
  | Private_file_succeeded result -> result
  | Private_file_succeeded_with_cleanup_failure
      { value = result; cleanup_failure } ->
    Log.Keeper.error
      "keeper_chat_store: provenance update succeeded with descriptor settlement failure path=%s: %s"
      path
      (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure);
    result
  | Private_file_failed error ->
    Error (Fs_compat.durable_append_error_to_string error)
  | Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
    Error
      (Printf.sprintf
         "%s; descriptor settlement failed: %s"
         (Fs_compat.durable_append_error_to_string error)
         (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))
;;

let append_chat_payload_durable path payload =
  match Fs_compat.append_private_jsonl_durable_locked_result path payload with
  | Private_file_succeeded () -> ()
  | Private_file_succeeded_with_cleanup_failure
      { value = (); cleanup_failure } ->
    Log.Keeper.error
      "keeper_chat_store: payload append succeeded with descriptor settlement failure path=%s: %s"
      path
      (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)
  | Private_file_failed error ->
    raise
      (Sys_error
         (Printf.sprintf
            "%s: %s"
            path
            (Fs_compat.private_jsonl_append_error_to_string error)))
  | Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
    raise
      (Sys_error
         (Printf.sprintf
            "%s: %s; descriptor settlement failed: %s"
            path
            (Fs_compat.private_jsonl_append_error_to_string error)
            (Fs_compat.private_jsonl_operation_failure_to_string
               cleanup_failure)))
;;

(* Tool calls with empty accumulated arguments are normalised to "{}" so
   every persisted line keeps a non-empty [content] (the read-side
   validity check and the dashboard history mapping both require it). *)
let normalize_tool_args args =
  if String.trim args = "" then "{}" else args

(* Two questions were sharing one answer.

   "What did the provider call this?" is a record. It can be unanswered, and
   the log writer already answers an empty call_id by omitting the field
   ([keeper_event_bridge.ml:199]). Synthesising "tc-<position>" here made the
   two writers disagree about the same execution, and the dashboard join
   matches on that id alone, so the step stayed pending forever (#21894).
   {!Tool_invocation_ref} states the rule directly: correlation identity is
   never inferred from names, arguments, timestamps, or hashes.

   "Where does this turn's reply go?" is a delivery address. Its position is
   total because the slot is this store's own, but it must not masquerade as
   an execution identity. *)
let provider_tool_call_id call_id =
  if String.trim call_id = "" then None else Some call_id

let tool_transcript_slot ~ordinal (call : tool_call) =
  match call.execution_id with
  | Some execution_id ->
    Keeper_chat_delivery_identity.Tool_call { execution_id; ordinal }
  | None -> Keeper_chat_delivery_identity.Tool_delivery { ordinal }

(* RFC-0232 §3.3: the append IS the parse boundary.  Mentions are
   derived from the content that is actually persisted (post-redaction),
   so an offline re-parse of the stored line reproduces the field;
   connectors with structured mention data add [extra_mentions]. *)
let user_line_mentions ~extra_mentions content =
  Keeper_lane_mentions.mention_ids_of_content content @ extra_mentions
  |> List.sort_uniq Keeper_identity.Keeper_id.compare

let append_turn_result ~base_dir ~keeper_name ~(user_content : string)
    ~(user_attachments : attachment list) ?(tool_calls = []) ?surface
    ?conversation_id ?external_message_id ?speaker ?(extra_mentions = [])
    ?(assistant_kind = Row_kind.Utterance)
    ?blocks
    ?turn_ref
    ?stream_lifecycle
    ~(assistant_content : string)
    () =
  try
    ensure_dir_once ~base_dir;
    let redaction = redaction_for ~base_dir ~keeper_name in
    let user_content =
      Keeper_secret_redaction.redact_text redaction user_content
    in
    let user_attachments =
      List.map (redact_attachment redaction) user_attachments
    in
    let persisted_user_attachments =
      List.map persisted_attachment user_attachments
    in
    let tool_calls = List.map (redact_tool_call redaction) tool_calls in
    let assistant_content =
      Keeper_secret_redaction.redact_text redaction assistant_content
    in
    let blocks = redact_blocks redaction blocks in
    let path = chat_path ~base_dir ~keeper_name in
    let ts = Time_compat.now () in
    (* Speaker identity belongs to the user line only: tool and
       assistant lines are the keeper's own output. *)
    let user_line =
      encode_line ~role:Role.User ~content:user_content ~ts
        ~attachments:persisted_user_attachments ?surface ?conversation_id
        ?external_message_id ?speaker ?turn_ref
        ~mentions:(user_line_mentions ~extra_mentions user_content) ()
    in
    let tool_lines =
      List.mapi
        (fun position tc ->
          encode_line ~role:Role.Tool
            ~content:(normalize_tool_args tc.args)
            ~ts
            ?tool_call_id:(provider_tool_call_id tc.call_id)
            ?execution_id:tc.execution_id
            ~tool_call_name:tc.call_name
            ?surface ?conversation_id ?turn_ref ())
        tool_calls
    in
    let asst_line =
      encode_line ~role:Role.Assistant ~content:assistant_content ~ts ?surface
        ?conversation_id ~kind:assistant_kind ?blocks ?turn_ref
        ?stream_lifecycle ()
    in
    let payload =
      String.concat "\n" ((user_line :: tool_lines) @ [ asst_line ]) ^ "\n"
    in
    append_chat_payload_durable path payload;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ChatStoreFailures)
      ~labels:[("operation", Keeper_chat_store_operation.(to_label Append))]
      ();
    let message = Printexc.to_string exn in
    Log.Keeper.warn "keeper_chat_store: append failed for %s: %s"
      (sanitize_name keeper_name) message;
    Error message

let append_turn ~base_dir ~keeper_name ~(user_content : string)
    ~(user_attachments : attachment list) ?(tool_calls = []) ?surface
    ?conversation_id ?external_message_id ?speaker ?(extra_mentions = [])
    ?(assistant_kind = Row_kind.Utterance) ?blocks ?turn_ref ?stream_lifecycle
    ~(assistant_content : string) () =
  ignore
    (append_turn_result ~base_dir ~keeper_name ~user_content ~user_attachments
       ~tool_calls ?surface ?conversation_id ?external_message_id ?speaker
       ~extra_mentions ~assistant_kind ?blocks ?turn_ref ?stream_lifecycle
       ~assistant_content ()
      : (unit, string) result)

(* A turn that executed tools but reached no assistant terminal still has a
   durable user/tool timeline.  Do not fabricate an assistant utterance (or a
   transport failure) merely to reuse [append_turn_result]. *)
let append_user_and_tool_calls_result ~base_dir ~keeper_name ~(user_content : string)
    ~(user_attachments : attachment list) ~(tool_calls : tool_call list) ?surface
    ?conversation_id ?external_message_id ?speaker ?(extra_mentions = [])
    ?turn_ref () : (unit, string) result =
  if tool_calls = [] then Error "tool-only continuation requires at least one tool call"
  else try
    ensure_dir_once ~base_dir;
    let redaction = redaction_for ~base_dir ~keeper_name in
    let user_content = Keeper_secret_redaction.redact_text redaction user_content in
    let user_attachments = List.map (redact_attachment redaction) user_attachments in
    let persisted_user_attachments = List.map persisted_attachment user_attachments in
    let tool_calls = List.map (redact_tool_call redaction) tool_calls in
    let path = chat_path ~base_dir ~keeper_name in
    let ts = Time_compat.now () in
    let user_line =
      encode_line ~role:Role.User ~content:user_content ~ts
        ~attachments:persisted_user_attachments ?surface ?conversation_id
        ?external_message_id ?speaker ?turn_ref
        ~mentions:(user_line_mentions ~extra_mentions user_content) ()
    in
    let tool_lines =
      List.mapi
        (fun position tc ->
           encode_line ~role:Role.Tool
             ~content:(normalize_tool_args tc.args)
             ~ts
             ?tool_call_id:(provider_tool_call_id tc.call_id)
             ?execution_id:tc.execution_id
             ~tool_call_name:tc.call_name
             ?surface ?conversation_id ?turn_ref ())
        tool_calls
    in
    append_chat_payload_durable path (String.concat "\n" (user_line :: tool_lines) ^ "\n");
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ChatStoreFailures)
      ~labels:[("operation", Keeper_chat_store_operation.(to_label Append))]
      ();
    let message = Printexc.to_string exn in
    Log.Keeper.warn "keeper_chat_store: user/tool append failed for %s: %s"
      (sanitize_name keeper_name) message;
    Error message

let append_tool_calls_result ~base_dir ~keeper_name ~(tool_calls : tool_call list)
    ?surface ?conversation_id ?turn_ref () : (unit, string) result =
  if tool_calls = [] then Error "tool-only continuation requires at least one tool call"
  else try
    ensure_dir_once ~base_dir;
    let redaction = redaction_for ~base_dir ~keeper_name in
    let tool_calls = List.map (redact_tool_call redaction) tool_calls in
    let path = chat_path ~base_dir ~keeper_name in
    let ts = Time_compat.now () in
    let tool_lines =
      List.mapi
        (fun position tc ->
           encode_line ~role:Role.Tool
             ~content:(normalize_tool_args tc.args)
             ~ts
             ?tool_call_id:(provider_tool_call_id tc.call_id)
             ?execution_id:tc.execution_id
             ~tool_call_name:tc.call_name
             ?surface ?conversation_id ?turn_ref ())
        tool_calls
    in
    append_chat_payload_durable path (String.concat "\n" tool_lines ^ "\n");
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ChatStoreFailures)
      ~labels:[("operation", Keeper_chat_store_operation.(to_label Append))]
      ();
    let message = Printexc.to_string exn in
    Log.Keeper.warn "keeper_chat_store: tool-only append failed for %s: %s"
      (sanitize_name keeper_name) message;
    Error message

(* RFC-0223 P4: keeper-initiated message on one lane. A single
   assistant line — there is no user turn to pair it with.

   [append_assistant_message_result] surfaces a write failure as [Error msg] so
   a caller bound by a no-silent-loss contract (e.g. {!Fusion_sink.emit}) can
   propagate it. The failure is still counted + warn-logged here so callers that
   use the unit wrapper below keep the existing swallow-and-count telemetry. *)
let append_assistant_message_result ~base_dir ~keeper_name ~(content : string)
    ?(tool_calls = []) ?surface ?conversation_id ?audio
    ?(assistant_kind = Row_kind.Utterance) ?blocks ?turn_ref ?stream_lifecycle
    () : (unit, string) result =
  try
    ensure_dir_once ~base_dir;
    let redaction = redaction_for ~base_dir ~keeper_name in
    let content = Keeper_secret_redaction.redact_text redaction content in
    let tool_calls = List.map (redact_tool_call redaction) tool_calls in
    let blocks = redact_blocks redaction blocks in
    let audio = Option.map (redact_audio redaction) audio in
    let path = chat_path ~base_dir ~keeper_name in
    let ts = Time_compat.now () in
    let tool_lines =
      List.mapi
        (fun position tc ->
          encode_line ~role:Role.Tool
            ~content:(normalize_tool_args tc.args)
            ~ts
            ?tool_call_id:(provider_tool_call_id tc.call_id)
            ?execution_id:tc.execution_id
            ~tool_call_name:tc.call_name
            ?surface ?conversation_id ?turn_ref ())
        tool_calls
    in
    let line =
      encode_line ~role:Role.Assistant ~content ~ts ?surface ?conversation_id
        ?audio ~kind:assistant_kind ?blocks ?turn_ref ?stream_lifecycle ()
    in
    let payload =
      String.concat "\n" (tool_lines @ [ line ]) ^ "\n"
    in
    append_chat_payload_durable path payload;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ChatStoreFailures)
      ~labels:[("operation", Keeper_chat_store_operation.(to_label Append))]
      ();
    Log.Keeper.warn "keeper_chat_store: assistant append failed for %s: %s"
      (sanitize_name keeper_name) (Printexc.to_string exn);
    Error (Printexc.to_string exn)

type append_once_line =
  { transcript_slot : Keeper_chat_delivery_identity.transcript_slot
  ; row_id : string
  ; line : string
  }

let transcript_slot_ordinal = function
  | Keeper_chat_delivery_identity.Tool_call { ordinal; _ }
  | Keeper_chat_delivery_identity.Tool_delivery { ordinal } -> Some ordinal
  | Keeper_chat_delivery_identity.Accepted_user
  | Keeper_chat_delivery_identity.Terminal_assistant
  | Keeper_chat_delivery_identity.Approval_request
  | Keeper_chat_delivery_identity.Approval_resolution
  | Keeper_chat_delivery_identity.Approval_replay
  | Keeper_chat_delivery_identity.Approval_replay_correction
  | Keeper_chat_delivery_identity.Approval_continuation -> None
;;

let validate_append_once_lines lines =
  let rec loop seen_slots seen_ordinals seen_executions = function
    | [] -> Ok ()
    | { transcript_slot; _ } :: rest ->
      let ( let* ) = Result.bind in
      let* () =
        if
          List.exists
            (Keeper_chat_delivery_identity.transcript_slot_equal transcript_slot)
            seen_slots
        then Error "append-once batch repeats a delivery provenance slot"
        else Ok ()
      in
      let ordinal = transcript_slot_ordinal transcript_slot in
      let* () =
        match ordinal with
        | Some ordinal when List.mem ordinal seen_ordinals ->
          Error "append-once batch repeats a tool ordinal"
        | Some _ | None -> Ok ()
      in
      let execution_id =
        match transcript_slot with
        | Keeper_chat_delivery_identity.Tool_call { execution_id; _ } ->
          Some execution_id
        | Keeper_chat_delivery_identity.Accepted_user
        | Keeper_chat_delivery_identity.Tool_delivery _
        | Keeper_chat_delivery_identity.Terminal_assistant
        | Keeper_chat_delivery_identity.Approval_request
        | Keeper_chat_delivery_identity.Approval_resolution
        | Keeper_chat_delivery_identity.Approval_replay
        | Keeper_chat_delivery_identity.Approval_replay_correction
        | Keeper_chat_delivery_identity.Approval_continuation -> None
      in
      let* () =
        match execution_id with
        | Some execution_id
          when String.equal
                 (String.trim (Ids.Execution_id.to_string execution_id))
                 "" ->
          Error "append-once batch contains a blank canonical execution_id"
        | Some execution_id
          when List.exists (Ids.Execution_id.equal execution_id) seen_executions ->
          Error
            "append-once batch reuses a canonical execution_id for multiple tool ordinals"
        | Some _ | None -> Ok ()
      in
      loop
        (transcript_slot :: seen_slots)
        (Option.fold ~none:seen_ordinals
           ~some:(fun ordinal -> ordinal :: seen_ordinals)
           ordinal)
        (Option.fold ~none:seen_executions
           ~some:(fun execution_id -> execution_id :: seen_executions)
           execution_id)
        rest
  in
  loop [] [] [] lines
;;

let append_lines_once ?(reject_partial_after_result = false) path ~delivery_key
      ~result_slot lines =
  match validate_append_once_lines lines with
  | Error detail -> Error detail
  | Ok () ->
    (match
       Fs_compat.update_private_file_durable_locked_result path (fun existing ->
      let inspect index =
        let rec loop found additions = function
          | [] -> Ok (found, List.rev additions)
          | ({ transcript_slot; row_id; line = _ } as candidate) :: rest ->
            (match
               find_indexed_provenance
                 index
                 ~provenance:
                   { Keeper_chat_delivery_identity.delivery_key
                   ; transcript_slot
                   }
             with
             | Error detail -> Error detail
             | Ok (Some existing_row_id) ->
               loop
                 ((transcript_slot, existing_row_id, true) :: found)
                 additions
                 rest
             | Ok None ->
               loop
                 ((transcript_slot, row_id, false) :: found)
                 (candidate :: additions)
                 rest)
        in
        loop [] [] lines
      in
      let inspected =
        Result.bind (provenance_index_of_existing existing) inspect
      in
      match inspected with
      | Error detail -> None, Error detail
      | Ok (rows, additions) ->
        let result_row =
          List.find_map
            (fun (slot, row_id, was_present) ->
               if Keeper_chat_delivery_identity.transcript_slot_equal slot result_slot
               then Some (row_id, was_present)
               else None)
            rows
        in
        (match result_row with
         | None -> None, Error "idempotent chat append is missing its result slot"
         | Some (row_id, result_was_present)
           when reject_partial_after_result && result_was_present && additions <> [] ->
           None,
           Error
             "assistant transcript already exists without its tool-call payload"
         | Some (row_id, _) ->
           let result =
             if additions = []
             then Already_present { row_id }
             else Appended { row_id }
           in
           let payload =
             additions
             |> List.map (fun candidate -> candidate.line ^ "\n")
             |> String.concat ""
           in
           (if additions = [] then None else Some payload), Ok result))
     with
     | Private_file_succeeded result -> result
     | Private_file_succeeded_with_cleanup_failure
      { value = result; cleanup_failure } ->
       Log.Keeper.error
         "keeper_chat_store: provenance batch update succeeded with descriptor settlement failure path=%s: %s"
         path
         (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure);
       result
     | Private_file_failed error ->
       Error (Fs_compat.durable_append_error_to_string error)
     | Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
       Error
         (Printf.sprintf
            "%s; descriptor settlement failed: %s"
            (Fs_compat.durable_append_error_to_string error)
            (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)))
;;

let tool_call_append_lines ~ts ~surface ~conversation_id ~turn_ref ~delivery_key
      tool_calls =
  List.mapi
    (fun ordinal tc ->
       let transcript_slot = tool_transcript_slot ~ordinal tc in
       let row_id = mint_message_id ~ts in
       { transcript_slot
       ; row_id
       ; line =
           encode_line
             ~role:Role.Tool
             ~content:(normalize_tool_args tc.args)
             ~ts
             ~message_id:row_id
             ?tool_call_id:(provider_tool_call_id tc.call_id)
             ?execution_id:tc.execution_id
             ~tool_call_name:tc.call_name
             ?surface
             ?conversation_id
             ?turn_ref
             ~provenance:
               { Keeper_chat_delivery_identity.delivery_key; transcript_slot }
             ()
       })
    tool_calls
;;

let append_tool_calls_once
      ~base_dir
      ~keeper_name
      ~delivery_key
      ~(tool_calls : tool_call list)
      ?surface
      ?conversation_id
      ?turn_ref
      ()
  =
  match tool_calls with
  | [] -> Error "idempotent tool-call append requires at least one tool call"
  | _ ->
    try
      ensure_dir_once ~base_dir;
      let redaction = redaction_for ~base_dir ~keeper_name in
      let tool_calls = List.map (redact_tool_call redaction) tool_calls in
      let path = chat_path ~base_dir ~keeper_name in
      let ts = Time_compat.now () in
      let lines =
        tool_call_append_lines ~ts ~surface ~conversation_id ~turn_ref ~delivery_key
          tool_calls
      in
      let ordinal = List.length tool_calls - 1 in
      let result_slot = tool_transcript_slot ~ordinal (List.nth tool_calls ordinal) in
      append_lines_once path ~delivery_key ~result_slot lines
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ChatStoreFailures)
        ~labels:[ "operation", Keeper_chat_store_operation.(to_label Append) ]
        ();
      let detail = Printexc.to_string exn in
      Log.Keeper.warn
        "keeper_chat_store: tool-call append-once failed for %s: %s"
        (sanitize_name keeper_name)
        detail;
      Error detail
;;

let append_assistant_message_once
      ~base_dir
      ~keeper_name
      ~delivery_key
      ~(content : string)
      ?surface
      ?conversation_id
      ?(assistant_kind = Row_kind.Utterance)
      ?(tool_calls = [])
      ?blocks
      ?turn_ref
      ?stream_lifecycle
      ()
  =
  try
    ensure_dir_once ~base_dir;
    let redaction = redaction_for ~base_dir ~keeper_name in
    let content = Keeper_secret_redaction.redact_text redaction content in
    let tool_calls = List.map (redact_tool_call redaction) tool_calls in
    let blocks = redact_blocks redaction blocks in
    let path = chat_path ~base_dir ~keeper_name in
    let ts = Time_compat.now () in
    let row_id = mint_message_id ~ts in
    let transcript_slot =
      Keeper_chat_delivery_identity.Terminal_assistant
    in
    let line =
      encode_line
        ~role:Role.Assistant
        ~content
        ~ts
        ~message_id:row_id
        ?surface
        ?conversation_id
        ~kind:assistant_kind
        ?blocks
        ?turn_ref
        ?stream_lifecycle
        ~provenance:
          { Keeper_chat_delivery_identity.delivery_key; transcript_slot }
        ()
    in
    let tool_lines =
      tool_call_append_lines ~ts ~surface ~conversation_id ~turn_ref ~delivery_key
        tool_calls
    in
    let assistant_line = { transcript_slot; row_id; line } in
    append_lines_once
      ~reject_partial_after_result:(tool_lines <> [])
      path
      ~delivery_key
      ~result_slot:transcript_slot
      (tool_lines @ [ assistant_line ])
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ChatStoreFailures)
      ~labels:[ "operation", Keeper_chat_store_operation.(to_label Append) ]
      ();
    let detail = Printexc.to_string exn in
    Log.Keeper.warn
      "keeper_chat_store: assistant append-once failed for %s: %s"
      (sanitize_name keeper_name)
      detail;
    Error detail
;;

(* Unit wrapper: existing callers keep the prior swallow-and-count behavior (the
   failure is already counted + logged inside the [_result] variant). New callers
   that must surface the failure call [append_assistant_message_result] directly. *)
let append_assistant_message ~base_dir ~keeper_name ~(content : string)
    ?tool_calls ?surface ?conversation_id ?audio ?blocks ?turn_ref
    ?stream_lifecycle () =
  ignore
    (append_assistant_message_result ~base_dir ~keeper_name ~content ?tool_calls
       ?surface ?conversation_id ?audio ?blocks ?turn_ref ?stream_lifecycle ()
      : (unit, string) result)

(* RFC-0226: inbound user line recorded at delivery time, before (and
   independent of) any turn. A single user line — the assistant reply,
   if one ever comes, is appended separately by the reply path. *)
let append_user_message ~base_dir ~keeper_name ~(content : string)
    ?(attachments = []) ?surface ?conversation_id ?external_message_id ?speaker
    ?(extra_mentions = []) () =
  try
    ensure_dir_once ~base_dir;
    let redaction = redaction_for ~base_dir ~keeper_name in
    let content = Keeper_secret_redaction.redact_text redaction content in
    let attachments = List.map (redact_attachment redaction) attachments in
    let persisted_attachments = List.map persisted_attachment attachments in
    let path = chat_path ~base_dir ~keeper_name in
    let ts = Time_compat.now () in
    let line =
      encode_line ~role:Role.User ~content ~ts ?surface ?conversation_id
        ~attachments:persisted_attachments
        ?external_message_id ?speaker
        ~mentions:(user_line_mentions ~extra_mentions content) ()
    in
    append_chat_payload_durable path (line ^ "\n")
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ChatStoreFailures)
      ~labels:[("operation", Keeper_chat_store_operation.(to_label Append))]
      ();
    Log.Keeper.warn "keeper_chat_store: user append failed for %s: %s"
      (sanitize_name keeper_name) (Printexc.to_string exn)

let append_user_message_once
      ~base_dir
      ~keeper_name
      ~delivery_key
      ~(content : string)
      ?(attachments = [])
      ?surface
      ?conversation_id
      ?external_message_id
      ?workspace_id
      ?speaker
      ?(extra_mentions = [])
      ()
  =
  try
    ensure_dir_once ~base_dir;
    let redaction = redaction_for ~base_dir ~keeper_name in
    let content = Keeper_secret_redaction.redact_text redaction content in
    let attachments = List.map (redact_attachment redaction) attachments in
    let persisted_attachments = List.map persisted_attachment attachments in
    let path = chat_path ~base_dir ~keeper_name in
    let ts = Time_compat.now () in
    let row_id = mint_message_id ~ts in
    let provenance =
      { Keeper_chat_delivery_identity.delivery_key
      ; transcript_slot = Keeper_chat_delivery_identity.Accepted_user
      }
    in
    let line =
      encode_line
        ~role:Role.User
        ~content
        ~ts
        ~message_id:row_id
        ~attachments:persisted_attachments
        ?surface
        ?conversation_id
        ?external_message_id
        ?workspace_id
        ?speaker
        ~mentions:(user_line_mentions ~extra_mentions content)
        ~provenance
        ()
    in
    append_line_once path ~provenance ~row_id line
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ChatStoreFailures)
      ~labels:[ "operation", Keeper_chat_store_operation.(to_label Append) ]
      ();
    let detail = Printexc.to_string exn in
    Log.Keeper.warn
      "keeper_chat_store: user append-once failed for %s: %s"
      (sanitize_name keeper_name)
      detail;
    Error detail
;;

let parse_line ~file_path (line : string) : chat_message option =
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
    let surface =
      match Json_util.assoc_member_opt "surface" json with
      | None -> None
      | Some surface_json -> (
          match Surface_ref.of_json surface_json with
          | Ok s -> Some s
          | Error detail ->
              (* Unknown/invalid surface payload: surface it and keep the
                 row as unscoped chat content. *)
              report_persistence_read_drop
                ~reason:Read_drop_reason.Invalid_payload
                ~path:file_path
                ~detail:(Printf.sprintf "invalid surface field: %s" detail);
              None)
    in
    let conversation_id = opt_string "conversation_id" in
    let external_message_id = opt_string "external_message_id" in
    let workspace_id = opt_string "workspace_id" in
    let speaker =
      let speaker_id = opt_string "speaker_id" in
      let speaker_name = opt_string "speaker_name" in
      match opt_string "speaker_authority" with
      | Some label -> (
          match authority_of_label label with
          | Some speaker_authority ->
              Some { speaker_id; speaker_name; speaker_authority }
          | None ->
              (* Unknown authority label: surface it instead of guessing
                 a class; the row itself stays valid. *)
              report_persistence_read_drop
                ~reason:Read_drop_reason.Invalid_payload
                ~path:file_path
                ~detail:
                  (Printf.sprintf "unknown speaker_authority %S" label);
              None)
      | None ->
          (match speaker_id, speaker_name with
           | None, None -> ()
           | _ ->
               (* id/name without an authority class never comes from our
                  writer; report so the producer gets fixed. *)
               report_persistence_read_drop
                 ~reason:Read_drop_reason.Invalid_payload
                 ~path:file_path
                 ~detail:"speaker_id/speaker_name without speaker_authority");
          None
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
    let kind =
      (* Absent field = every row written before [kind] existed; all of
         those are utterances. Unknown labels are surfaced and read as
         [Utterance] — the conservative arm (renders and advances the
         watermark like any reply) rather than silently resurrecting a
         pending user line. *)
      match opt_string "kind" with
      | None -> Row_kind.Utterance
      | Some label -> (
          match Row_kind.of_label label with
          | Some kind -> kind
          | None ->
              report_persistence_read_drop
                ~reason:Read_drop_reason.Invalid_payload
                ~path:file_path
                ~detail:(Printf.sprintf "unknown chat row kind %S" label);
              Row_kind.Utterance)
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
        (match validate_delivery_role ~role_label provenance with
         | Error detail ->
           report_persistence_read_drop
             ~reason:Read_drop_reason.Invalid_payload
             ~path:file_path
             ~detail:(Printf.sprintf "invalid delivery row role: %s" detail);
           false
         | Ok () ->
           (match execution_id_result with
            | Error detail ->
              report_persistence_read_drop
                ~reason:Read_drop_reason.Invalid_payload
                ~path:file_path
                ~detail:(Printf.sprintf "invalid execution identity: %s" detail);
              false
            | Ok execution_id ->
              (match
                 validate_delivery_execution_identity
                   ~execution_id
                   delivery_provenance
               with
               | Ok () -> true
               | Error detail ->
                 report_persistence_read_drop
                   ~reason:Read_drop_reason.Invalid_payload
                   ~path:file_path
                   ~detail:
                     (Printf.sprintf
                        "invalid delivery execution identity: %s"
                        detail);
                 false)))
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
    in
    if not delivery_execution_identity_valid then None
    else if role_label = "" || (content = "" && not has_structured_payload) then (
      report_persistence_read_drop
        ~reason:Read_drop_reason.Invalid_payload
        ~path:file_path
        ~detail:"chat row missing role and readable text/structured payload";
      None)
    else
      match Role.of_label role_label with
      | None ->
          (* RFC-0232 P1: an unknown role cannot participate in any lane
             semantics (watermark, pending, rendering); surface it
             instead of carrying an untyped row. *)
          report_persistence_read_drop
            ~reason:Read_drop_reason.Invalid_payload
            ~path:file_path
            ~detail:(Printf.sprintf "unknown chat row role %S" role_label);
          None
      | Some Role.Tool when tool_call_name = None ->
          report_persistence_read_drop
            ~reason:Read_drop_reason.Invalid_payload
            ~path:file_path
            ~detail:"tool chat row missing non-empty tool_call_name";
          None
      | Some role ->
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
                   mentions; kind; turn_ref; stream_lifecycle; approval_lifecycle;
                   delivery_provenance })
  with Yojson.Json_error detail ->
    report_persistence_read_drop
      ~reason:Read_drop_reason.Json_syntax_error
      ~path:file_path
      ~detail;
    None

(* Window bounds for [load]. [max_history] counts user/assistant
   messages only, so tool lines never shrink the visible conversation
   depth. [max_total_lines] is the absolute guard (tool lines included)
   against a pathological tool-spam turn blowing up the payload. *)
let max_history = 100
let max_total_lines = 400

let is_tool_message (msg : chat_message) = Role.equal msg.role Role.Tool

let is_history_primary (msg : chat_message) =
  Role.equal msg.role Role.User || Role.equal msg.role Role.Assistant
;;

(* Old rows without either causal identity can become unrenderable when a
   window evicts their owning user row. Current tool-only continuations carry
   [turn_ref] or idempotent [delivery_provenance] and remain valid even when they
   are the first retained row. *)
let drop_leading_orphan_tool_messages messages =
  let rec split anonymous_tools = function
    | ({ turn_ref = None; delivery_provenance = None; _ } as msg) :: rest
      when is_tool_message msg ->
      split (msg :: anonymous_tools) rest
    | rest -> List.rev anonymous_tools, rest
  in
  match split [] messages with
  | [], _ -> messages
  | anonymous_tools,
    ({ role = Role.Assistant; kind = Row_kind.Transport_failure; _ } :: _ as rest) ->
    (* Failure persistence is one ordered batch: tool rows followed by its
       typed terminal assistant row. The user row may already have been
       persisted upstream or may fall just outside this page, so the terminal
       marker—not a guessed missing parent—proves these leading rows belong. *)
    anonymous_tools @ rest
  | _, rest -> rest

(* RFC-0226 P2: [load] serves a fixed window ([max_total_lines]) but
   used to read and JSON-parse the whole file to build it, so its cost
   scaled with lane size — the same pathology family as the
   2026-06-09 telemetry-JSONL incident (multi-MB files starving the
   Eio domain). Read a bounded tail instead: [max_total_lines] lines
   at ~10 KiB each leaves wide slack over the gate's 4 KB content
   bound. A tail whose recent lines are larger (attachment payloads)
   degrades to a shorter window, never to an error or a full scan. *)
let tail_read_bytes = 4 * 1024 * 1024

(* RFC-0228 P1: binary-search probes for [before]-paging are tiny
   bounded reads; a probe only needs to span a handful of lines. A
   probe landing inside an oversized line degrades the cut estimate
   (shorter window), never correctness — the final ts filter discards
   overshoot rows. *)
let probe_bytes = 256 * 1024

type page = { messages : chat_message list; has_more : bool }

(* Lines of the byte slice [[from, upto)). When [from > 0] the first
   element is a (potentially partial) line fragment — dropped, same
   rationale as the RFC-0226 P2 tail read. A final element without a
   terminating '\n' (mid-line [upto], or a writer-in-flight tail) is
   dropped the same way; split yields [""] there for boundary cuts, so
   only true fragments are removed. *)
let slice_lines ~path ~from ~upto : string list =
  if upto <= from then []
  else
    let slice = Fs_compat.read_slice ~path ~from ~len:(upto - from) in
    let lines = String.split_on_char '\n' slice in
    let lines = match lines with _ :: rest when from > 0 -> rest | l -> l in
    match List.rev lines with
    | last :: rev_rest when last <> "" -> List.rev rev_rest
    | _ -> lines

(* Metric-quiet ts extractor for probes: probed lines are re-read by
   the real parse later, so a malformed row must not double-count in
   the read-drop metrics. *)
let quiet_line_ts line : float option =
  try
    match Json_util.assoc_member_opt "ts" (Yojson.Safe.from_string line) with
    | Some (`Float f) -> Some f
    | _ -> None
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> None

let probe_ts ~path ~size pos : float option =
  let upto = min size (pos + probe_bytes) in
  List.find_map
    (fun line ->
      let trimmed = String.trim line in
      if trimmed = "" then None else quiet_line_ts trimmed)
    (slice_lines ~path ~from:pos ~upto)

(* Largest prefix [[0, cut)) holding only lines with ts < [before].
   Append-only wall-clock stamps make line ts monotone in byte offset,
   so this is a plain byte-offset binary search: ~log2(size/probe)
   probes, each bounded. The returned cut overshoots by at most one
   probe window; callers filter by ts. *)
let find_cut ~path ~size ~before : int =
  let lo = ref 0 and hi = ref size in
  while !hi - !lo > probe_bytes do
    let mid = !lo + ((!hi - !lo) / 2) in
    match probe_ts ~path ~size mid with
    | Some t when t < before -> lo := mid
    | Some _ | None -> hi := mid
  done;
  !hi

let load_page ~base_dir ~keeper_name ?before () : page =
  let path = chat_path ~base_dir ~keeper_name in
  if not (Sys.file_exists path) then { messages = []; has_more = false }
  else
  try
    let size = Option.value (Fs_compat.file_size path) ~default:0 in
    let upto, keep =
      match before with
      | None -> (size, fun (_ : chat_message) -> true)
      | Some b ->
          (find_cut ~path ~size ~before:b, fun (m : chat_message) -> m.ts < b)
    in
    let from = if upto > tail_read_bytes then upto - tail_read_bytes else 0 in
    (* Single pass: keep a running window of the last [max_history]
       user/assistant messages plus their tool lines. *)
    let q = Queue.create () in
    let primary_count = ref 0 in
    let evicted = ref false in
    let pop_front () =
      evicted := true;
      let popped = Queue.pop q in
      if is_history_primary popped then decr primary_count
    in
    List.iter
      (fun line ->
        let trimmed = String.trim line in
        if trimmed <> "" then
          match parse_line ~file_path:path trimmed with
          | Some msg when keep msg ->
              Queue.push msg q;
              if is_history_primary msg then incr primary_count;
              while
                !primary_count > max_history
                || Queue.length q > max_total_lines
              do
                pop_front ()
              done
          | Some _ | None -> ())
      (slice_lines ~path ~from ~upto);
    let messages =
      let redaction = redaction_for ~base_dir ~keeper_name in
      Queue.fold (fun acc msg -> msg :: acc) [] q
      |> List.rev
      |> drop_leading_orphan_tool_messages
      |> List.map (redact_message redaction)
    in
    { messages; has_more = from > 0 || !evicted }
  with
  | Sys_error detail ->
      report_persistence_read_drop
        ~reason:Read_drop_reason.Entry_load_error
        ~path
        ~detail;
      { messages = []; has_more = false }
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ChatStoreFailures)
        ~labels:[("operation", Keeper_chat_store_operation.(to_label Load))]
        ();
      Log.Keeper.warn "keeper_chat_store: load failed for %s: %s"
        (sanitize_name keeper_name) (Printexc.to_string exn);
      { messages = []; has_more = false }

let load ~base_dir ~keeper_name : chat_message list =
  (load_page ~base_dir ~keeper_name ()).messages

let load_all ~base_dir ~keeper_name : chat_message list =
  let path = chat_path ~base_dir ~keeper_name in
  if not (Sys.file_exists path) then []
  else
    match Safe_ops.read_file_safe path with
    | Error detail ->
      report_persistence_read_drop
        ~reason:Read_drop_reason.Entry_load_error
        ~path
        ~detail;
      []
    | Ok contents ->
      let redaction = redaction_for ~base_dir ~keeper_name in
      contents
      |> String.split_on_char '\n'
      |> List.filter_map (fun line ->
        let trimmed = String.trim line in
        if trimmed = "" then None else parse_line ~file_path:path trimmed)
      |> List.map (redact_message redaction)

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
  | Approval_continuation_recorded -> false
;;

let append_approval_lifecycle_at_slot_once
      ~base_dir
      ~keeper_name
      ~lifecycle
      ~transcript_slot
  =
  let open Keeper_chat_delivery_identity in
  match Request_id.of_string lifecycle.approval_id with
  | Error detail -> Error detail
  | Ok approval_id ->
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
       | Ok (Appended _ as result) -> Ok (Approval_lifecycle_exact result)
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
    | Approval_continuation_recorded -> Approval_continuation
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
  | Ok (Approval_lifecycle_conflict _) ->
    Error "approval lifecycle provenance exists with conflicting content"
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
    | _ -> None)
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
          | Ok (Approval_lifecycle_exact result) -> Ok result
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

(* The request row is written by the queue with the producer's statement in
   hand ([Keeper_gate.request.call_summary]); no later writer has the
   producer, so every later phase row copies the line from here. Read from the
   stored row, so the copy carries the redaction the store applied. *)
let approval_request_call_summary ~base_dir ~keeper_name ~approval_id =
  existing_approval_lifecycle_at_slot
    ~base_dir
    ~keeper_name
    ~approval_id
    ~transcript_slot:Keeper_chat_delivery_identity.Approval_request
  |> Option.bind (fun (_row_id, lifecycle) -> lifecycle.call_summary)
;;

(* RFC-0235 P3: the history endpoint can tell the dashboard that a clip
   has been reaped by checking the same audio directory the synthesis side
   writes to. This keeps the TTL reaper simple while avoiding a broken
   native player on reload. *)
let audio_clip_file_path ~base_dir token =
  Filename.concat
    (Filename.concat (Common.masc_dir_from_base_path ~base_path:base_dir) "audio")
    (token ^ ".mp3")

let valid_audio_token token =
  Re.execp (Re.compile (Re.Pcre.re "^[A-Za-z0-9_-]+$")) token

let file_exists_safe path =
  try Sys.file_exists path with
  | Sys_error _ | Unix.Unix_error _ -> false

let audio_fields_with_expired ~base_dir audio =
  match audio with
  | None -> []
  | Some a ->
      let expired =
        if not (valid_audio_token a.token) then true
        else
          match base_dir with
          | None -> a.expired
          | Some base_dir ->
              a.expired
              || not (file_exists_safe (audio_clip_file_path ~base_dir a.token))
      in
      [ ("audio", `Assoc (audio_to_json { a with expired })) ]

let trace_block_for_turn ~trace_block_by_turn_ref (m : chat_message) =
  match m.turn_ref, trace_block_by_turn_ref with
  | Some turn_ref, Some trace_block_by_turn_ref -> trace_block_by_turn_ref turn_ref
  | None, _ | Some _, None -> None

let blocks_with_trace_block ~trace_block (m : chat_message) =
  let base =
    match m.blocks with
    | Some blocks -> blocks
    | None -> []
  in
  match m.role, trace_block with
  | Role.Assistant, Some trace_block -> base @ [ trace_block ]
  | _ -> base

let blocks_fields_of_list = function
  | [] -> []
  | blocks -> [ ("blocks", Keeper_chat_blocks.blocks_to_yojson blocks) ]
;;

let rec last_opt = function
  | [] -> None
  | [ x ] -> Some x
  | _ :: rest -> last_opt rest

let stream_delivery_receipt_field value =
  [ ("delivery_receipt", `String value) ]

let chat_stream_contract_json ~trace_lookup_available ~trace_block
    (m : chat_message) =
  let field key value = (key, value) in
  let string_field key value = field key (`String value) in
  let base_fields =
    Json_util.string_field_if_present "turn_ref" (Option.map Ids.Turn_ref.to_string m.turn_ref)
  in
  match m.stream_lifecycle with
  | Some (_ :: _ as events) ->
      let labels = List.map stream_lifecycle_event_to_label events in
      `Assoc
        ([ string_field "source" "backend_stream_lifecycle"
         ; string_field "status" "backend_lifecycle_replay"
         ; string_field "reason"
             "history row records durable server stream lifecycle replay"
         ; field "lifecycle_events"
             (`List (List.map (fun label -> `String label) labels))
         ]
        @ stream_delivery_receipt_field "server_lifecycle_replay_only"
        @ Json_util.string_field_if_present "event_name" (last_opt labels)
        @ base_fields)
  | None | Some [] -> (
      match m.turn_ref with
      | None ->
          `Assoc
            ([ string_field "source" "keeper_chat_store"
             ; string_field "status" "history_without_turn_ref"
             ; string_field "reason"
                 "history row has no persisted turn_ref; no causal stream join is possible"
             ]
            @ stream_delivery_receipt_field "no_delivery_receipt"
            @ base_fields)
      | Some _ -> (
          match trace_block with
          | Some (Keeper_chat_blocks.Trace { trace }) when trace <> [] ->
              `Assoc
                ([ string_field "source" "backend_turn_trace"
                 ; string_field "status" "backend_trace_join"
                 ; string_field "reason"
                     "turn_ref joined to retained trajectory/internal-history events"
                 ; field "trace_event_count" (`Int (List.length trace))
                 ]
                @ stream_delivery_receipt_field "no_delivery_receipt"
                @ base_fields)
          | Some _ | None ->
              let reason =
                if trace_lookup_available then
                  "turn_ref persisted but no retained trajectory/internal-history events were available"
                else "history route served without trace enrichment"
              in
              `Assoc
                ([ string_field "source" "keeper_chat_store"
                 ; string_field "status" "history_without_stream_events"
                 ; string_field "reason" reason
                 ]
                @ stream_delivery_receipt_field "no_delivery_receipt"
                @ base_fields)))

let to_json_array ?base_dir ?trace_block_by_turn_ref
    (messages : chat_message list) : Yojson.Safe.t =
  `List
    (List.map
       (fun m ->
         let trace_block = trace_block_for_turn ~trace_block_by_turn_ref m in
         `Assoc
           ([ ("id", `String m.id);
              ("role", `String (Role.to_label m.role));
              ("content", `String m.content);
              ("ts", `Float m.ts);
            ]
              (* Dashboard history: surface the writer-declared kind for
                 non-utterance rows so a reload can tell a transport
                 failure apart from keeper speech. *)
              @ (match m.kind with
                 | Row_kind.Utterance -> []
                 | Row_kind.Transport_failure ->
                     [ ("kind", `String (Row_kind.to_label m.kind)) ])
              @ Json_util.string_field_if_present "tool_call_id" m.tool_call_id
              @ Json_util.string_field_if_present "execution_id"
                  (Option.map Ids.Execution_id.to_string m.execution_id)
              @ Json_util.string_field_if_present "tool_call_name" m.tool_call_name
              @ (match m.surface with
                 | None -> []
                 | Some s -> [ ("surface", Surface_ref.to_json s) ])
              @ Json_util.string_field_if_present "conversation_id" m.conversation_id
              @ Json_util.string_field_if_present "external_message_id" m.external_message_id
              @ Json_util.string_field_if_present "workspace_id" m.workspace_id
              @ speaker_fields m.speaker
              @ (match m.attachments with
                 | None | Some [] -> []
                 | Some atts ->
                     (* The dashboard API carries the size the row was
                        persisted with -- the [masc://] reference in [data]
                        cannot be re-measured, and rows that never went
                        through [persisted_attachment] have none to show. *)
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
                     [("attachments", `List att_json)])
              @ audio_fields_with_expired ~base_dir m.audio
              @ [ ("stream_contract",
                    chat_stream_contract_json
                      ~trace_lookup_available:(Option.is_some trace_block_by_turn_ref)
                      ~trace_block m )
                ]
              @ blocks_fields_of_list (blocks_with_trace_block ~trace_block m)
              @ Json_util.string_field_if_present "turn_ref"
                  (Option.map Ids.Turn_ref.to_string m.turn_ref)
              @ approval_lifecycle_fields m.approval_lifecycle
              (* Preserve the persisted provenance pair at the HTTP boundary.
                 Dashboard convergence uses the same atomic identity as the
                 append-once store instead of reconstructing a slot from role. *)
              @ (match m.delivery_provenance with
                 | None -> []
                 | Some provenance ->
                     Keeper_chat_delivery_identity.delivery_provenance_fields
                       provenance)))
       messages)

(* RFC-0233 §7: a turn's terminal assistant row is selected by exact persisted
   [turn_ref] ("<trace_id>#<absolute_turn>"). Direct/queued accepted-user rows
   are persisted before the turn exists, so they carry no [turn_ref]; they join
   through the same typed delivery key and the [Accepted_user] transcript slot.
   Tool rows are excluded — they carry only the call args, while the full tool
   I/O is surfaced by the tool-call store keyed on [execution_id]. *)
type turn_transcript = {
  user : chat_message list;
  assistant : chat_message list;
}

let transcript_of_messages (messages : chat_message list) ~turn_ref :
    turn_transcript =
  let matches_turn_ref (m : chat_message) =
    match m.turn_ref with
    | Some tr -> Ids.Turn_ref.equal tr turn_ref
    | None -> false
  in
  let assistant_delivery_keys =
    List.filter_map
      (fun (m : chat_message) ->
         match m.role, m.delivery_provenance with
         | ( Role.Assistant
           , Some
               { Keeper_chat_delivery_identity.delivery_key
               ; transcript_slot = Keeper_chat_delivery_identity.Terminal_assistant
               } )
           when matches_turn_ref m ->
           Some delivery_key
         | (Role.Assistant | Role.System | Role.User | Role.Tool), _ -> None)
      messages
  in
  let matches_accepted_user_delivery (m : chat_message) =
    match m.role, m.delivery_provenance with
    | ( Role.User
      , Some
          { Keeper_chat_delivery_identity.delivery_key
          ; transcript_slot = Keeper_chat_delivery_identity.Accepted_user
          } ) ->
      List.exists
        (Keeper_chat_delivery_identity.delivery_key_equal delivery_key)
        assistant_delivery_keys
    | (Role.Assistant | Role.System | Role.User | Role.Tool), _ -> false
  in
  let user, assistant =
    List.fold_left
      (fun (user, assistant) (m : chat_message) ->
         match m.role with
         | Role.User when matches_turn_ref m || matches_accepted_user_delivery m ->
           m :: user, assistant
         | Role.Assistant when matches_turn_ref m -> user, m :: assistant
         | Role.User | Role.Assistant | Role.System | Role.Tool ->
           (* Tool rows join via execution_id in the tool-call store, not
              via the transcript. *)
           user, assistant)
      ([], []) messages
  in
  { user = List.rev user; assistant = List.rev assistant }

let transcript_line_to_json (m : chat_message) : Yojson.Safe.t =
  `Assoc
    ([ ("role", `String (Role.to_label m.role));
       ("content", `String m.content);
       ("ts", `Float m.ts);
     ]
      (* Surface the writer-declared kind so the inspector can tell a
         transport failure apart from a real keeper utterance, exactly as
         the chat history endpoint does — a failure marker is never quoted
         back as the keeper's own words. *)
    @ (match m.kind with
       | Row_kind.Utterance -> []
       | Row_kind.Transport_failure ->
           [ ("kind", `String (Row_kind.to_label m.kind)) ]))

let turn_transcript_to_json ~keeper ~turn_ref (t : turn_transcript) :
    Yojson.Safe.t =
  (* [found] is false when no persisted row carries this turn_ref (old
     rows, rows outside the retained window, or a turn that produced no
     chat lines). The caller renders explicit absence, never a fabricated
     transcript. *)
  let found = t.user <> [] || t.assistant <> [] in
  `Assoc
    [ ("keeper", `String keeper);
      ("turn_ref", `String (Ids.Turn_ref.to_string turn_ref));
      ("found", `Bool found);
      ("source", `String "keeper_chat_store");
      ("user", `List (List.map transcript_line_to_json t.user));
      ("assistant", `List (List.map transcript_line_to_json t.assistant));
    ]
