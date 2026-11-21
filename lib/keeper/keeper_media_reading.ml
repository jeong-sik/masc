type kind = Media_reading_kind.t =
  | Audio
  | Document

type reader_identity = { id : string; revision : string }
type identity_error = Empty_id | Empty_revision

let reader_identity ~id ~revision =
  if String.trim id = "" then Error Empty_id
  else if String.trim revision = "" then Error Empty_revision
  else Ok { id; revision }
;;

type reader_failure =
  | Temporary_file_failed
  | Temporary_write_failed
  | Stt_failed of Voice_bridge.transcription_error
  | Empty_transcript
  | Pdf_failed of Verification_pdf_inspection.error
  | Empty_extraction
  | Empty_reading

type reader =
  { identity : reader_identity
  ; read : bytes:string -> (string, reader_failure) result
  }

let reader ~identity ~read = { identity; read }

type resolution_failure =
  | No_matching_reader
  | Stt_unavailable of Voice_bridge.transcription_error

type resolver =
  kind:kind -> media_type:string -> (reader, resolution_failure) result

type original_reference =
  { request_id : string; original_digest : string; execution_id : string }

let original_reference original =
  { request_id = Keeper_media_reading_original.request_id original
  ; original_digest = Keeper_media_reading_original.original_digest original
  ; execution_id = Keeper_media_reading_original.execution_id original }
;;

type reading =
  { reader : reader_identity; text : string; original : original_reference option }

let reading_of_original ~original ~text =
  if String.trim text = "" then Error Empty_reading
  else
    let declaration = Keeper_media_reading_original.declaration original in
    Ok { reader = { id = declaration.id; revision = declaration.revision }
       ; text; original = Some (original_reference original) }
;;

type dispatch_failure =
  | Dispatch_owner_failed of Keeper_media_reading_owner.error
  | Dispatch_progress_failed of Lane_addon_tool_request_owner.update_error
  | Dispatch_unconfirmed of string
type external_failure =
  | Declarations_unavailable
  | Declaration_ambiguous of string list
  | Declaration_changed of string
  | Reader_not_started
  | Original_failed of Keeper_media_reading_original.error
  | Owner_failed of Keeper_media_reading_owner.error
  | Queue_failed of Keeper_approval_queue_result.storage_error
  | Gate_failed of Keeper_gate.unavailable_reason
  | Approval_mismatch of Keeper_approval_queue_result.exact_request_lookup
  | Invalid_approval of string
  | Approval_rejected of string
  | Progress_failed of Lane_addon_tool_request_owner.update_error
  | Progress_unconfirmed of string
  | Endpoint_unavailable of string
  | Request_refused of Keeper_sandbox_remote.Stdio_request.refusal
  | Binding_refused of Keeper_sandbox_remote.Stdio_request.binding_error
  | Binding_changed
  | Transport_failed of dispatch_failure Keeper_sandbox_remote_stdio.failure
  | Mcp_failed of Agent_core.Error.t
  | Channel_unavailable of string
  | Catalog_failed of Keeper_media_markitdown.catalog_error
  | Conversion_failed of Keeper_media_markitdown.reply_error
  | Reply_capture_failed of string

type failure =
  | Resolution_failed of resolution_failure
  | Invalid_source_reference of Agent_core.History.stored_error
  | Source_unavailable of Agent_core.History.media_error
  | Reader_failed of { reader : reader_identity; reason : reader_failure }
  | External_failed of external_failure

type pending_disposition =
  | Awaiting_approval of string
  | Awaiting_host_replay of string
  | Approval_consumed of string
  | Rejected_approval of { approval_id : string; reason : string }
  | Execution_pending
  | Request_not_sent
  | Outcome_unknown
  | Reconciliation_required
  | Ambiguous_approvals of string list
  | Known_approval_missing of
      { approval_id : string; matching_approval_ids : string list }
  | Known_approval_mismatch of
      { approval_id : string; matching_approval_ids : string list }
type pending_observation =
  { original : original_reference; disposition : pending_disposition }
type outcome =
  | Read of reading
  | Unavailable of failure
  | Pending of pending_observation * pending_observation list

type source_route = Use_builtin | Owned of outcome
type source_reader =
  kind:kind -> media_type:string -> Agent_core.History.stored -> source_route
type source_readers = { observe : source_reader; read : source_reader }

let external_failure_to_string = function
  | Declarations_unavailable -> "reader_declarations_unavailable"
  | Declaration_ambiguous _ -> "reader_declaration_ambiguous"
  | Declaration_changed _ -> "reader_declaration_changed"
  | Reader_not_started -> "reader_not_started"
  | Original_failed _ -> "reader_original_unavailable"
  | Owner_failed _ -> "reader_owner_unavailable"
  | Queue_failed _ -> "reader_approval_queue_unavailable"
  | Gate_failed _ -> "reader_gate_unavailable"
  | Approval_mismatch _ -> "reader_approval_mismatch"
  | Invalid_approval _ -> "reader_approval_invalid"
  | Approval_rejected _ -> "reader_approval_rejected"
  | Progress_failed _ -> "reader_progress_unavailable"
  | Progress_unconfirmed _ -> "reader_progress_unconfirmed"
  | Endpoint_unavailable _ -> "reader_endpoint_unavailable"
  | Request_refused _ -> "reader_request_refused"
  | Binding_refused _ -> "reader_binding_refused"
  | Binding_changed -> "reader_binding_changed"
  | Transport_failed _ -> "reader_transport_failed"
  | Mcp_failed _ -> "reader_mcp_failed"
  | Channel_unavailable _ -> "reader_channel_unavailable"
  | Catalog_failed _ -> "reader_catalog_invalid"
  | Conversion_failed _ -> "reader_conversion_failed"
  | Reply_capture_failed _ -> "reader_reply_capture_failed"
;;


let kind_to_string = function
  | Audio -> "audio"
  | Document -> "document"
;;


let audio_extension media_type =
  match String.lowercase_ascii media_type with
  | "audio/wav" | "audio/x-wav" | "audio/wave" -> ".wav"
  | "audio/mpeg" | "audio/mp3" -> ".mp3"
  | "audio/ogg" -> ".ogg"
  | "audio/flac" -> ".flac"
  | "audio/mp4" | "audio/m4a" | "audio/x-m4a" -> ".m4a"
  | "audio/webm" -> ".webm"
  | _ -> ".bin"
;;

(* The configured STT chain reads a file, so the decoded bytes take a short
   trip through a temporary file that is removed whether the call answers or
   not. Cancellation is not caught: [Fun.protect] removes the file and the
   exception continues. *)
let transcribe_bytes prepared ~media_type ~bytes =
  match Filename.temp_file "keeper-media-" (audio_extension media_type) with
  | exception Sys_error detail ->
    Log.Keeper.warn "media reading: temp file failed: %s" detail;
    Error Temporary_file_failed
  | path ->
    Fun.protect
      ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
      (fun () ->
        match
          Out_channel.with_open_bin path (fun channel ->
            Out_channel.output_string channel bytes)
        with
        | exception Sys_error detail ->
          Log.Keeper.warn "media reading: temp write failed: %s" detail;
          Error Temporary_write_failed
        | () ->
          (match Voice_bridge.transcribe_prepared prepared ~audio_file:path () with
           | Error detail ->
             Log.Keeper.warn "media reading: STT failed: %s"
               (Voice_bridge.transcription_error_to_string detail);
             Error (Stt_failed detail)
           | Ok transcript ->
             if String.trim transcript.Voice_bridge.text = ""
             then Error Empty_transcript
             else Ok transcript.text))
;;

let pdf_reason = function
  | Verification_pdf_inspection.Dependency_unavailable _ -> "dependency_unavailable"
  | Verification_pdf_inspection.Poppler_budget_spent _ -> "budget_spent"
  | Verification_pdf_inspection.Payload_budget_exceeded _ -> "payload_too_large"
  | Verification_pdf_inspection.Too_many_pages _ -> "too_many_pages"
  | Verification_pdf_inspection.Command_failed _
  | Verification_pdf_inspection.Invalid_output _
  | Verification_pdf_inspection.Image_policy_rejected _
  | Verification_pdf_inspection.Rendered_bytes_exceeded _
  | Verification_pdf_inspection.Storage_failed _ -> "extraction_failed"
;;

let extract_pdf ~base_path ~bytes =
  match
    Verification_pdf_inspection.extract_text ~base_path ~bytes ()
  with
  | Error error -> Error (Pdf_failed error)
  | Ok pages ->
    let numbered =
      List.mapi (fun index text -> Printf.sprintf "[page %d]\n%s" (index + 1) text) pages
    in
    let joined = String.concat "\n" numbered in
    if List.for_all (fun text -> String.trim text = "") pages
    then Error Empty_extraction
    else Ok joined
;;

let production_readers ~base_path ~kind ~media_type =
  match kind with
  | Audio ->
    (match Voice_bridge.prepare_transcription () with
     | Error error -> Error (Stt_unavailable error)
     | Ok prepared ->
       let identity =
         { id = "builtin.stt"
         ; revision = Voice_bridge.transcription_identity prepared
         }
       in
       Ok (reader ~identity ~read:(transcribe_bytes prepared ~media_type)))
  | Document ->
    if String.lowercase_ascii media_type = "application/pdf"
    then
      Ok (reader ~identity:{ id = "builtin.pdf_text"; revision = "1" }
        ~read:(extract_pdf ~base_path))
    else Error No_matching_reader
;;

let media_error_reason : Agent_core.History.media_error -> string = function
  | Store_failed _ -> "store_failed"
  | Missing_bytes _ -> "missing_bytes"
  | Invalid_base64 _ -> "invalid_base64"
  | Digest_mismatch _ -> "digest_mismatch"
;;

let stt_unavailable_reason : Voice_bridge.transcription_error -> string = function
  | Configuration_invalid _ -> "stt_configuration_invalid"
  | Not_configured | Stt_not_configured | No_enabled_endpoints -> "stt_not_configured"
  | Endpoints_failed _ -> "stt_failed"
;;

let failure_to_string = function
  | External_failed reason -> external_failure_to_string reason
  | Resolution_failed No_matching_reader -> "no_matching_reader"
  | Resolution_failed (Stt_unavailable error) -> stt_unavailable_reason error
  | Invalid_source_reference _ -> "invalid_source_reference"
  | Source_unavailable error -> media_error_reason error
  | Reader_failed { reason; _ } ->
    (match reason with
     | Temporary_file_failed -> "temp_file_failed"
     | Temporary_write_failed -> "temp_write_failed"
     | Stt_failed _ -> "stt_failed"
     | Empty_transcript -> "empty_transcript"
     | Pdf_failed error -> pdf_reason error
     | Empty_extraction -> "empty_extraction"
     | Empty_reading -> "empty_reading")
;;

(* --- durable store ------------------------------------------------------- *)

let safe_segment value =
  String.map (fun c -> if c = '/' || c = '\\' || c = '\000' then '_' else c) value
;;

let identity_json (identity : reader_identity) =
  `Assoc [ "id", `String identity.id; "revision", `String identity.revision ]
;;

let original_reference_json (original : original_reference) =
  `Assoc [ "request_id", `String original.request_id
         ; "original_digest", `String original.original_digest
         ; "execution_id", `String original.execution_id ]
;;

let pending_json { original; disposition } =
  let ids values = `List (List.map (fun id -> `String id) values) in
  let state, details = match disposition with
    | Awaiting_approval id -> "awaiting_approval", ["approval_id", `String id]
    | Awaiting_host_replay id -> "awaiting_host_replay", ["approval_id", `String id]
    | Approval_consumed id -> "approval_consumed", ["approval_id", `String id]
    | Rejected_approval {approval_id;reason} ->
      "approval_rejected", ["approval_id", `String approval_id; "reason", `String reason]
    | Execution_pending -> "execution_pending", []
    | Request_not_sent -> "request_not_sent", []
    | Outcome_unknown -> "outcome_unknown", []
    | Reconciliation_required -> "reconciliation_required", []
    | Ambiguous_approvals matching_approval_ids ->
      "reconciliation_required", ["reason", `String "ambiguous_approvals";
        "matching_approval_ids", ids matching_approval_ids]
    | Known_approval_missing {approval_id; matching_approval_ids} ->
      "reconciliation_required", ["reason", `String "known_approval_missing";
        "approval_id", `String approval_id; "matching_approval_ids", ids matching_approval_ids]
    | Known_approval_mismatch {approval_id; matching_approval_ids} ->
      "reconciliation_required", ["reason", `String "known_approval_mismatch";
        "approval_id", `String approval_id; "matching_approval_ids", ids matching_approval_ids]
  in
  `Assoc ([ "original", original_reference_json original
          ; "state", `String state ] @ details)
;;

let outcome_to_json = function
  | Read reading ->
    `Assoc ([ "status", `String "read"
            ; "derived_by", `String "automatic_reader"
            ; "reader", identity_json reading.reader
            ; "text", `String reading.text ]
            @ Option.to_list (Option.map
                (fun original -> "original_request", original_reference_json original)
                reading.original))
  | Unavailable failure ->
    `Assoc [ "status", `String "unavailable"
           ; "reason", `String (failure_to_string failure) ]
  | Pending (first, rest) ->
    `Assoc [ "status", `String "pending"
           ; "observations", `List (List.map pending_json (first :: rest)) ]
;;

(* A stored reading lives while a durable consumer still holds its
   attachment's [Stored] reference. The record name carries that reference's
   sha256, and the sweep (Keeper_media_reading_maintenance) checks it against
   the blob registry's typed scan. The store sits outside every
   durable-consumer tree, so a record never counts as a reference itself. *)
let store_dirname = "media-readings"

let record_path ~base_path ~keeper_name ~kind ~media_type ~source ~reader =
  (* The original digest remains in the maintenance-owned filename prefix.
     The suffix binds the complete MIME, length and selected reader without
     making arbitrary declaration text a filesystem component. *)
  let key = Yojson.Safe.to_string
    (`Assoc [ "media_type", `String media_type
            ; "source_bytes", `Int source.Agent_core.History.bytes
            ; "reader", identity_json reader ]) in
  let key_digest = Agent_core_sha256.(to_hex (digest_string key)) in
  Filename.concat
    (Filename.concat
       (Filename.concat (Common.masc_dir_from_base_path ~base_path) store_dirname)
       (safe_segment keeper_name))
    (Printf.sprintf "%s-%s-%s.json" (kind_to_string kind)
       source.Agent_core.History.sha256 key_digest)
;;

let exact_keys expected fields =
  List.sort String.compare (List.map fst fields) = List.sort String.compare expected
;;

let same_identity_json (identity : reader_identity) = function
  | `Assoc fields when exact_keys ["id"; "revision"] fields ->
    List.assoc_opt "id" fields = Some (`String identity.id)
    && List.assoc_opt "revision" fields = Some (`String identity.revision)
  | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> false
;;

let load_reading ~base_path ~keeper_name ~kind ~media_type ~source ~reader =
  match base_path with
  | None -> None
  | Some base_path ->
    let path = record_path ~base_path ~keeper_name ~kind ~media_type ~source ~reader in
    (match In_channel.with_open_bin path In_channel.input_all with
     | exception Sys_error _ when not (Sys.file_exists path) -> None
     | exception Sys_error detail ->
       Log.Keeper.warn "media reading: stored reading unreadable at %s: %s" path detail;
       None
     | content ->
       (match Yojson.Safe.from_string content with
        | exception Yojson.Json_error detail ->
          Log.Keeper.warn "media reading: stored reading corrupt at %s: %s" path detail;
          None
        | `Assoc fields when exact_keys
            ["schema_version"; "kind"; "media_type"; "source_sha256";
             "source_bytes"; "reader"; "status"; "text"] fields ->
          let expected =
            [ "schema_version", `Int 2
            ; "kind", `String (kind_to_string kind)
            ; "media_type", `String media_type
            ; "source_sha256", `String source.Agent_core.History.sha256
            ; "source_bytes", `Int source.bytes
            ; "status", `String "read" ] in
          (match List.assoc_opt "reader" fields, List.assoc_opt "text" fields with
           | Some recorded_reader, Some (`String text)
             when same_identity_json reader recorded_reader
               && List.for_all (fun (key, value) -> List.assoc_opt key fields = Some value) expected
               && String.trim text <> "" -> Some { reader; text; original = None }
           | Some _, Some (`String _) -> None
           | None, _ | Some _, None -> None
           | Some _, Some (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null) -> None)
        | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None))
;;

let store_reading ~base_path ~keeper_name ~kind ~media_type ~source (reading : reading) =
  match base_path with
  | None -> ()
  | Some base_path ->
    let path = record_path ~base_path ~keeper_name ~kind ~media_type ~source ~reader:reading.reader in
    let json =
      `Assoc
        [ "schema_version", `Int 2
        ; "kind", `String (kind_to_string kind)
        ; "media_type", `String media_type
        ; "source_sha256", `String source.Agent_core.History.sha256
        ; "source_bytes", `Int source.bytes
        ; "reader", identity_json reading.reader
        ; "status", `String "read"
        ; "text", `String reading.text
        ]
    in
    (try
       Fs_compat.mkdir_p (Filename.dirname path);
       match Fs_compat.save_file_atomic path (Yojson.Safe.to_string json) with
       | Ok () -> ()
       | Error detail ->
         Log.Keeper.warn "media reading: store failed for %s: %s" path detail
     with
     | Sys_error detail ->
       (* A reading that cannot be stored is read again on the next attempt;
          say so instead of retrying silently. *)
       Log.Keeper.warn "media reading: store failed for %s: %s" path detail
     | Unix.Unix_error (error, operation, argument) ->
       Log.Keeper.warn "media reading: store failed for %s: %s(%s): %s"
         path operation argument (Unix.error_message error))
;;

(* --- projection ---------------------------------------------------------- *)

let header ~kind ~media_type ~sha ~status =
  Printf.sprintf
    "[attachment kind=%s media_type=%s sha256:%s status=%s]"
    (kind_to_string kind)
    media_type
    sha
    status
;;

let unavailable_text ~kind ~media_type ~sha ~reason =
  Printf.sprintf
    "%s\nThe attachment could not be read (%s). The original is kept in the conversation \
     history; nothing about its content is known here."
    (header ~kind ~media_type ~sha ~status:"unavailable")
    reason
;;

let read_text ~kind ~media_type ~sha (reading : reading) =
  let original = Option.fold ~none:""
      ~some:(fun original -> "\nOriginal request: "
        ^ Yojson.Safe.to_string (original_reference_json original)) reading.original in
  Printf.sprintf
    "%s\nReader: %s%s\nReading of the attachment (derived by an automatic reader, original kept in the \
     conversation history):\n%s"
    (header ~kind ~media_type ~sha ~status:"read")
    (Yojson.Safe.to_string (identity_json reading.reader))
    original
    reading.text
;;

let reference_text ~kind ~media_type ~source =
  Printf.sprintf
    "[attachment kind=%s media_type=%s source=%s status=unavailable]\nThe attachment is a \
     reference that is not fetched here (reference_not_fetched); nothing about its content \
     is known."
    (kind_to_string kind)
    media_type
    source
;;

(* One projector serves one lane walk: every candidate and every message of
   the walk share [memo], so an attachment is read at most once per walk,
   whether the reading succeeded or not (docs/KEEPER-MEDIA-FALLBACK-H5.md §3).
   The next turn builds a new projector, which is where an unavailable
   attachment is retried. A newly encountered attachment reaches its reader
   regardless of the time spent on earlier reads or provider attempts. *)
type projector =
  { base_path : string option
  ; media_store : Agent_core.History.media_store
  ; keeper_name : string
  ; resolve : resolver
  ; source_reader : source_reader
  ; selections : (kind * string, (reader, resolution_failure) result) Hashtbl.t
  ; memo : (kind * string * string * int * reader_identity, (reading, failure) result) Hashtbl.t
  }

let projector ?base_path ?(source_reader = fun ~kind:_ ~media_type:_ _ -> Use_builtin)
    ~media_store ~keeper_name ~resolve () =
  { base_path
  ; media_store
  ; keeper_name
  ; resolve
  ; source_reader
  ; selections = Hashtbl.create 2
  ; memo = Hashtbl.create 4
  }
;;

let selected_reader projector ~kind ~media_type =
  let key = kind, media_type in
  match Hashtbl.find_opt projector.selections key with
  | Some selected -> selected
  | None ->
    let selected = projector.resolve ~kind ~media_type in
    Hashtbl.replace projector.selections key selected;
    selected
;;

let read_builtin projector ~kind ~media_type source =
  let { base_path; media_store; keeper_name; resolve = _; source_reader = _;
        selections = _; memo } = projector in
  (* The digest names the reading, so the bytes are read from the store only
     when no reading exists. Memoize the raw result: its consumer owns the
     attribution to history, a retained receipt, or another original. *)
  match selected_reader projector ~kind ~media_type with
  | Error reason -> Error (Resolution_failed reason)
  | Ok selected ->
  let key = kind, media_type, source.Agent_core.History.sha256, source.bytes, selected.identity in
  match Hashtbl.find_opt memo key with
  | Some result -> result
  | None ->
    let result =
      match load_reading ~base_path ~keeper_name ~kind ~media_type ~source ~reader:selected.identity with
      | Some reading -> Ok reading
      | None ->
        (match
           match media_store.get source with
           | Ok bytes ->
             Result.map_error
               (fun reason -> Reader_failed {reader = selected.identity; reason})
               (selected.read ~bytes)
           | Error error -> Error (Source_unavailable error)
         with
         | Ok text when String.trim text <> "" ->
           let reading = { reader = selected.identity; text; original = None } in
           store_reading ~base_path ~keeper_name ~kind ~media_type ~source reading;
           Ok reading
         | Ok _ -> Error (Reader_failed {reader = selected.identity; reason = Empty_reading})
         | Error reason -> Error reason)
    in
    Hashtbl.replace memo key result;
    result
;;

let read_stored ?source_reader projector ~kind ~media_type source =
  let observe = match source_reader with
    | Some reader -> reader
    | None -> projector.source_reader in
  (* Even an existing built-in memo cannot hide a newly retained request,
     approval, reply, or unknown dispatch for this attachment. *)
  match observe ~kind ~media_type source with
  | Owned outcome -> outcome
  | Use_builtin ->
    match read_builtin projector ~kind ~media_type source with
    | Ok reading -> Read reading
    | Error failure -> Unavailable failure
;;

let project_with ~read_stored ~needs_projection blocks =
  let open Result.Syntax in
  let replaced : (string * int) list ref = ref [] in
  let project_one ~kind ~media_type ~source block =
    if not (needs_projection kind)
    then Ok block
    else (
      (let name = kind_to_string kind in
       let prev = Option.value ~default:0 (List.assoc_opt name !replaced) in
       replaced := (name, prev + 1) :: List.remove_assoc name !replaced);
      match (source : Agent_core.Types.media_source) with
      | Agent_core.Types.Url _ -> Ok (Agent_core.Types.text_block (reference_text ~kind ~media_type ~source:"url"))
      | Agent_core.Types.File_id _ ->
        Ok (Agent_core.Types.text_block (reference_text ~kind ~media_type ~source:"file_id"))
      | Agent_core.Types.Stored stored ->
        let+ outcome = read_stored ~kind ~media_type stored in
        let sha = stored.Agent_core.History.sha256 in
        let text =
          match outcome with
          | Read reading -> read_text ~kind ~media_type ~sha reading
          | Unavailable failure -> unavailable_text ~kind ~media_type ~sha ~reason:(failure_to_string failure)
          | Pending _ as pending ->
            header ~kind ~media_type ~sha ~status:"pending"
            ^ "\n" ^ Yojson.Safe.to_string (outcome_to_json pending)
        in
        Agent_core.Types.text_block text)
  in
  let rec project_block (block : Agent_core.Types.content_block) =
    match block with
    | Agent_core.Types.Audio { media_type; source } ->
      project_one ~kind:Audio ~media_type ~source block
    | Agent_core.Types.Document { media_type; source } ->
      project_one ~kind:Document ~media_type ~source block
    | Agent_core.Types.ToolResult
        { tool_use_id; content; outcome; json; content_blocks = Some nested } ->
      let+ nested = project_blocks [] nested in
      let content_blocks = match nested with
        | [] -> None
        | blocks -> Some blocks in
      Agent_core.Types.ToolResult { tool_use_id; content; outcome; json; content_blocks }
    | Agent_core.Types.Text _ | Agent_core.Types.Thinking _
    | Agent_core.Types.ReasoningDetails _ | Agent_core.Types.RedactedThinking _
    | Agent_core.Types.ToolUse _
    | Agent_core.Types.ToolReference _
    | Agent_core.Types.ToolResult { content_blocks = None; _ }
    | Agent_core.Types.Image _ -> Ok block
  and project_blocks acc = function
    | [] -> Ok (List.rev acc)
    | block :: rest ->
      let* projected = project_block block in
      project_blocks (projected :: acc) rest
  in
  let+ projected = project_blocks [] blocks in
  projected, List.rev !replaced
;;

type no_projection_error = |

let project projector ~needs_projection blocks =
  let read ~kind ~media_type source : (outcome, no_projection_error) result =
    Ok (read_stored projector ~kind ~media_type source) in
  match project_with ~read_stored:read ~needs_projection blocks with
  | Ok projected -> projected
  | Error _ -> .
;;

module Prepared_sources = Map.Make (struct
  type t = kind * string * string * int
  let compare = Stdlib.compare
end)

type prepared =
  { audio : bool
  ; document : bool
  ; outcomes : outcome Prepared_sources.t
  }

type preparation_error =
  | Source_not_prepared of
      { kind : kind; media_type : string; source : Agent_core.History.stored }

let preparation_error_to_string = function
  | Source_not_prepared _ -> "selected media source was not prepared for this request"
;;

let prepared_key ~kind ~media_type (source : Agent_core.History.stored) =
  kind, media_type, source.sha256, source.bytes
;;

let prepare ?source_reader projector ~needs_projection bundle =
  let audio = needs_projection Audio and document = needs_projection Document in
  let selected = function Audio -> audio | Document -> document in
  let prepare_one outcomes ~kind ~media_type ~source =
    if not (selected kind) then outcomes
    else match (source : Agent_core.Types.media_source) with
      | Url _ | File_id _ -> outcomes
      | Stored source ->
        let key = prepared_key ~kind ~media_type source in
        if Prepared_sources.mem key outcomes then outcomes
        else
          let outcome = read_stored ?source_reader projector ~kind ~media_type source in
          Prepared_sources.add key outcome outcomes
  in
  let rec prepare_block outcomes (block : Agent_core.Types.content_block) =
    match block with
    | Audio { media_type; source } -> prepare_one outcomes ~kind:Audio ~media_type ~source
    | Document { media_type; source } -> prepare_one outcomes ~kind:Document ~media_type ~source
    | ToolResult { content_blocks = Some nested; _ } ->
      List.fold_left prepare_block outcomes nested
    | Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _
    | ToolReference _ | ToolResult { content_blocks = None; _ } | Image _ -> outcomes
  in
  let outcomes = List.fold_left (List.fold_left prepare_block) Prepared_sources.empty bundle in
  { audio; document; outcomes }
;;

let project_prepared prepared blocks =
  let needs_projection = function Audio -> prepared.audio | Document -> prepared.document in
  let read ~kind ~media_type source =
    match Prepared_sources.find_opt (prepared_key ~kind ~media_type source) prepared.outcomes with
    | Some outcome -> Ok outcome
    | None -> Error (Source_not_prepared { kind; media_type; source })
  in
  project_with ~read_stored:read ~needs_projection blocks
;;

let project_blocks ?base_path ~media_store ~keeper_name ~needs_projection ~resolve blocks =
  project
    (projector ?base_path ~media_store ~keeper_name ~resolve ())
    ~needs_projection
    blocks
;;
