type kind =
  | Audio
  | Document

type reader =
  deadline:Monotonic_deadline.t ->
  kind:kind ->
  media_type:string ->
  bytes:string ->
  (string, string) result

let reader_version = "1"

let kind_to_string = function
  | Audio -> "audio"
  | Document -> "document"
;;

let source_sha256 bytes = Digestif.SHA256.to_hex (Digestif.SHA256.digest_string bytes)

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
let transcribe_bytes ~deadline ~media_type ~bytes =
  match Filename.temp_file "keeper-media-" (audio_extension media_type) with
  | exception Sys_error detail -> Error ("temp_file_failed: " ^ detail)
  | path ->
    Fun.protect
      ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
      (fun () ->
        match
          Out_channel.with_open_bin path (fun channel ->
            Out_channel.output_string channel bytes)
        with
        | exception Sys_error detail -> Error ("temp_write_failed: " ^ detail)
        | () ->
          (match Voice_bridge.transcribe_audio ~audio_file:path ~deadline () with
           | Error detail ->
             (* A chain stopped by the shared deadline says so in its first
                word; anything else is an endpoint failure. *)
             if Monotonic_deadline.passed deadline
             then Error "budget_spent"
             else Error ("stt_failed: " ^ detail)
           | Ok json ->
             (match Json_util.get_string json "status", Json_util.get_string json "text" with
              | Some "transcribed", Some text when String.trim text <> "" -> Ok text
              | Some "transcribed", _ -> Error "empty_transcript"
              | Some status, _ -> Error ("stt_status_" ^ status)
              | None, _ -> Error "stt_status_missing")))
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

let extract_pdf ~base_path ~budget_sec ~deadline ~bytes =
  match
    Verification_pdf_inspection.extract_text ~deadline ~budget_sec ~base_path ~bytes ()
  with
  | Error error -> Error (pdf_reason error)
  | Ok pages ->
    let numbered =
      List.mapi (fun index text -> Printf.sprintf "[page %d]\n%s" (index + 1) text) pages
    in
    let joined = String.concat "\n" numbered in
    if List.for_all (fun text -> String.trim text = "") pages
    then Error "empty_extraction"
    else Ok joined
;;

let production_reader ~base_path ~budget_sec ~deadline ~kind ~media_type ~bytes =
  match kind with
  | Audio ->
    if Monotonic_deadline.passed deadline
    then Error "budget_spent"
    else transcribe_bytes ~deadline ~media_type ~bytes
  | Document ->
    if String.lowercase_ascii media_type = "application/pdf"
    then extract_pdf ~base_path ~budget_sec ~deadline ~bytes
    else Error "no_document_reader"
;;

(* --- durable store ------------------------------------------------------- *)

let safe_segment value =
  String.map (fun c -> if c = '/' || c = '\\' || c = '\000' then '_' else c) value
;;

let rec mkdir_p dir =
  if dir <> "" && dir <> "/" && not (Sys.file_exists dir)
  then (
    mkdir_p (Filename.dirname dir);
    try Sys.mkdir dir 0o755 with Sys_error _ when Sys.file_exists dir -> ())
;;

let record_path ~base_path ~keeper_name ~kind ~sha =
  Filename.concat
    (Filename.concat
       (Filename.concat base_path "media-readings")
       (safe_segment keeper_name))
    (Printf.sprintf "%s-%s.json" (kind_to_string kind) sha)
;;

let load_reading ~base_path ~keeper_name ~kind ~media_type ~sha =
  match base_path with
  | None -> None
  | Some base_path ->
    let path = record_path ~base_path ~keeper_name ~kind ~sha in
    (match In_channel.with_open_bin path In_channel.input_all with
     | exception Sys_error _ -> None
     | content ->
       (match Yojson.Safe.from_string content with
        | exception Yojson.Json_error _ -> None
        | json ->
          let str key = Json_util.get_string json key in
          (match
             str "status", str "reader_version", str "source_sha256", str "media_type", str "text"
           with
           | Some "read", Some version, Some stored_sha, Some stored_type, Some text
             when String.equal version reader_version
                  && String.equal stored_sha sha
                  && String.equal stored_type media_type
                  && String.trim text <> "" -> Some text
           | _ -> None)))
;;

let store_reading ~base_path ~keeper_name ~kind ~media_type ~sha ~text =
  match base_path with
  | None -> ()
  | Some base_path ->
    let path = record_path ~base_path ~keeper_name ~kind ~sha in
    let json =
      `Assoc
        [ "schema_version", `Int 1
        ; "kind", `String (kind_to_string kind)
        ; "media_type", `String media_type
        ; "source_sha256", `String sha
        ; "reader_version", `String reader_version
        ; "status", `String "read"
        ; "text", `String text
        ]
    in
    (try
       mkdir_p (Filename.dirname path);
       let temp = path ^ ".tmp" in
       Out_channel.with_open_bin temp (fun channel ->
         Out_channel.output_string channel (Yojson.Safe.to_string json));
       Sys.rename temp path
     with Sys_error _ -> ())
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

let read_text ~kind ~media_type ~sha ~text =
  Printf.sprintf
    "%s\nReading of the attachment (derived by an automatic reader, original kept in the \
     conversation history):\n%s"
    (header ~kind ~media_type ~sha ~status:"read")
    text
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

let project_blocks ?base_path ~keeper_name ~needs_projection ~deadline ~read blocks =
  let memo : (kind * string, string) Hashtbl.t = Hashtbl.create 4 in
  let replaced : (string * int) list ref = ref [] in
  let project_one ~kind ~media_type ~data ~source_type block =
    if not (needs_projection kind)
    then block
    else (
      (let name = kind_to_string kind in
       let prev = Option.value ~default:0 (List.assoc_opt name !replaced) in
       replaced := (name, prev + 1) :: List.remove_assoc name !replaced);
      match (source_type : Agent_core.Types.media_source_kind) with
      | Agent_core.Types.Url -> Agent_core.Types.text_block (reference_text ~kind ~media_type ~source:"url")
      | Agent_core.Types.File_id ->
        Agent_core.Types.text_block (reference_text ~kind ~media_type ~source:"file_id")
      | Agent_core.Types.Base64 ->
        (match Base64.decode data with
         | Error _ ->
           ignore block;
           Agent_core.Types.text_block
             (unavailable_text ~kind ~media_type ~sha:"unknown" ~reason:"invalid_base64")
         | Ok bytes ->
           let sha = source_sha256 bytes in
           let text =
             match Hashtbl.find_opt memo (kind, sha) with
             | Some text -> text
             | None ->
               let text =
                 match load_reading ~base_path ~keeper_name ~kind ~media_type ~sha with
                 | Some reading -> read_text ~kind ~media_type ~sha ~text:reading
                 | None ->
                   (match
                      if Monotonic_deadline.passed deadline
                      then Error "budget_spent"
                      else read ~deadline ~kind ~media_type ~bytes
                    with
                    | Ok reading when String.trim reading <> "" ->
                      store_reading ~base_path ~keeper_name ~kind ~media_type ~sha ~text:reading;
                      read_text ~kind ~media_type ~sha ~text:reading
                    | Ok _ -> unavailable_text ~kind ~media_type ~sha ~reason:"empty_reading"
                    | Error reason -> unavailable_text ~kind ~media_type ~sha ~reason)
               in
               Hashtbl.replace memo (kind, sha) text;
               text
           in
           Agent_core.Types.text_block text))
  in
  let projected =
    List.map
      (fun (block : Agent_core.Types.content_block) ->
        match block with
        | Agent_core.Types.Audio { media_type; data; source_type } ->
          project_one ~kind:Audio ~media_type ~data ~source_type block
        | Agent_core.Types.Document { media_type; data; source_type } ->
          project_one ~kind:Document ~media_type ~data ~source_type block
        | _ -> block)
      blocks
  in
  projected, List.rev !replaced
;;
