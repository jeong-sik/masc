module String_set = Set_util.StringSet

let dirname = "attachments"
let legacy_media_dirname = "media"
let id_prefix = "att_"
let url_prefix = "/api/v1/attachments/"
let default_max_bytes = 20 * 1024 * 1024
let default_ephemeral_max_entries = 500
let default_ephemeral_max_bytes = 20 * 1024 * 1024
let min_thumb_px = 32
let max_thumb_px = 2048
let transform_timeout_sec = 10.0

let max_bytes () =
  match Sys.getenv_opt "MASC_ATTACHMENT_MAX_BYTES" with
  | None -> default_max_bytes
  | Some raw ->
    (match int_of_string_opt (String.trim raw) with
     | Some n when n > 0 -> n
     | Some _ | None -> default_max_bytes)
;;

type origin =
  | User_upload
  | Tool_capture
  | Model_generated
  | Connector_inbound

let origin_to_string = function
  | User_upload -> "user_upload"
  | Tool_capture -> "tool_capture"
  | Model_generated -> "model_generated"
  | Connector_inbound -> "connector_inbound"
;;

let origin_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "user_upload" -> Some User_upload
  | "tool_capture" -> Some Tool_capture
  | "model_generated" -> Some Model_generated
  | "connector_inbound" -> Some Connector_inbound
  | _ -> None
;;

type retention =
  | Durable
  | Ephemeral of { keeper : string }

let retention_to_wire_string = function
  | Durable -> "durable"
  | Ephemeral _ -> "ephemeral"
;;

type media_kind =
  | Image
  | Audio
  | Document

let media_kind_to_string = function
  | Image -> "image"
  | Audio -> "audio"
  | Document -> "document"
;;

let media_kind_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "image" -> Some Image
  | "audio" -> Some Audio
  | "document" -> Some Document
  | _ -> None
;;

type supported_mime =
  | Image_png
  | Image_jpeg
  | Image_webp
  | Image_gif
  | Application_pdf
  | Audio_mpeg
  | Audio_wav
  | Audio_ogg
  | Audio_midi

let mime_to_string = function
  | Image_png -> "image/png"
  | Image_jpeg -> "image/jpeg"
  | Image_webp -> "image/webp"
  | Image_gif -> "image/gif"
  | Application_pdf -> "application/pdf"
  | Audio_mpeg -> "audio/mpeg"
  | Audio_wav -> "audio/wav"
  | Audio_ogg -> "audio/ogg"
  | Audio_midi -> "audio/midi"
;;

let media_kind_of_mime = function
  | Image_png | Image_jpeg | Image_webp | Image_gif -> Image
  | Audio_mpeg | Audio_wav | Audio_ogg | Audio_midi -> Audio
  | Application_pdf -> Document
;;

let extension_of_mime = function
  | Image_png -> ".png"
  | Image_jpeg -> ".jpg"
  | Image_webp -> ".webp"
  | Image_gif -> ".gif"
  | Application_pdf -> ".pdf"
  | Audio_mpeg -> ".mp3"
  | Audio_wav -> ".wav"
  | Audio_ogg -> ".ogg"
  | Audio_midi -> ".mid"
;;

let supported_mime_of_normalized = function
  | "image/png" -> Some Image_png
  | "image/jpeg" | "image/jpg" -> Some Image_jpeg
  | "image/webp" -> Some Image_webp
  | "image/gif" -> Some Image_gif
  | "application/pdf" -> Some Application_pdf
  | "audio/mpeg" | "audio/mp3" -> Some Audio_mpeg
  | "audio/wav" | "audio/x-wav" | "audio/wave" -> Some Audio_wav
  | "audio/ogg" -> Some Audio_ogg
  | "audio/midi" | "audio/x-midi" | "audio/mid" -> Some Audio_midi
  | _ -> None
;;

let normalize_mime_header raw =
  let base =
    match String.index_opt raw ';' with
    | Some i -> String.sub raw 0 i
    | None -> raw
  in
  String.lowercase_ascii (String.trim base)
;;

let is_forbidden_declared_mime normalized =
  match normalized with
  | "image/svg+xml"
  | "text/html"
  | "application/xhtml+xml"
  | "text/javascript"
  | "application/javascript"
  | "application/x-javascript" -> true
  | _ -> false
;;

let looks_like_forbidden_active_content bytes =
  let len = String.length bytes in
  let prefix_len = min len 512 in
  let slice =
    String.sub bytes 0 prefix_len |> String.trim |> String.lowercase_ascii
  in
  if String.starts_with ~prefix:"<svg" slice
  then Some "image/svg+xml"
  else if String.starts_with ~prefix:"<!doctype html" slice
          || String.starts_with ~prefix:"<html" slice
          || String.starts_with ~prefix:"<script" slice
  then Some "text/html"
  else if String.starts_with ~prefix:"<?xml" slice
  then (
    let has_svg =
      let rec scan i =
        if i + 4 > String.length slice
        then false
        else if String.sub slice i 4 = "<svg"
        then true
        else scan (i + 1)
      in
      scan 0
    in
    if has_svg then Some "image/svg+xml" else None)
  else None
;;

let is_mpeg_audio_frame_sync bytes =
  let len = String.length bytes in
  if len < 4
  then false
  else (
    let b0 = Char.code bytes.[0] in
    let b1 = Char.code bytes.[1] in
    let b2 = Char.code bytes.[2] in
    let sync = b0 = 0xff && b1 land 0xe0 = 0xe0 in
    let version_bits = (b1 lsr 3) land 0x03 in
    let layer_bits = (b1 lsr 1) land 0x03 in
    let bitrate_idx = (b2 lsr 4) land 0x0f in
    let sample_rate_idx = (b2 lsr 2) land 0x03 in
    (* Require MPEG Layer III (layer_bits = 0x01, i.e. MP3) and a non-free,
       non-bad bitrate index. Rejecting Layer I/II also rejects UTF-16LE BOM
       (\xff\xfe, where layer_bits = 0x03) followed by ASCII spaces. *)
    sync
    && version_bits <> 0x01
    && layer_bits = 0x01
    && bitrate_idx <> 0x00
    && bitrate_idx <> 0x0f
    && sample_rate_idx <> 0x03)
;;

let sniff_mime bytes =
  let len = String.length bytes in
  let starts prefix = String.starts_with ~prefix bytes in
  if len >= 8 && starts Rgb_png.signature
  then Some Image_png
  else if len >= 3 && starts "\xff\xd8\xff"
  then Some Image_jpeg
  else if len >= 6 && (starts "GIF87a" || starts "GIF89a")
  then Some Image_gif
  else if len >= 12 && starts "RIFF" && String.sub bytes 8 4 = "WEBP"
  then Some Image_webp
  else if len >= 5 && starts "%PDF-"
  then Some Application_pdf
  else if len >= 12 && starts "RIFF" && String.sub bytes 8 4 = "WAVE"
  then Some Audio_wav
  else if len >= 4 && starts "OggS"
  then Some Audio_ogg
  else if len >= 4 && starts "MThd"
  then Some Audio_midi
  else if (len >= 3 && starts "ID3") || is_mpeg_audio_frame_sync bytes
  then Some Audio_mpeg
  else None
;;

let be16 bytes offset =
  (Char.code bytes.[offset] lsl 8) lor Char.code bytes.[offset + 1]
;;

let le16 bytes offset =
  Char.code bytes.[offset] lor (Char.code bytes.[offset + 1] lsl 8)
;;

let le24 bytes offset =
  Char.code bytes.[offset]
  lor (Char.code bytes.[offset + 1] lsl 8)
  lor (Char.code bytes.[offset + 2] lsl 16)
;;

let le32 bytes offset =
  Char.code bytes.[offset]
  lor (Char.code bytes.[offset + 1] lsl 8)
  lor (Char.code bytes.[offset + 2] lsl 16)
  lor (Char.code bytes.[offset + 3] lsl 24)
;;

let sof_marker code =
  code >= 0xc0 && code <= 0xcf && code <> 0xc4 && code <> 0xc8 && code <> 0xcc
;;

let rec jpeg_walk bytes offset =
  let length = String.length bytes in
  if offset + 4 > length || Char.code bytes.[offset] <> 0xff
  then None
  else (
    let code = Char.code bytes.[offset + 1] in
    if code = 0x01 || (code >= 0xd0 && code <= 0xd7)
    then jpeg_walk bytes (offset + 2)
    else if sof_marker code
    then
      if offset + 9 > length
      then None
      else (
        let w = be16 bytes (offset + 7) in
        let h = be16 bytes (offset + 5) in
        if w > 0 && h > 0 then Some (w, h) else None)
    else if code = 0xda
    then None
    else (
      let segment = be16 bytes (offset + 2) in
      if segment <= 1 then None else jpeg_walk bytes (offset + 2 + segment)))
;;

let gif_dimensions bytes =
  if String.length bytes >= 10
  then (
    let w = le16 bytes 6 in
    let h = le16 bytes 8 in
    if w > 0 && h > 0 then Some (w, h) else None)
  else None
;;

let webp_dimensions bytes =
  let len = String.length bytes in
  if len >= 20
     && String.sub bytes 0 4 = "RIFF"
     && String.sub bytes 8 4 = "WEBP"
  then (
    let fourcc = String.sub bytes 12 4 in
    if String.equal fourcc "VP8 "
    then
      if len >= 30
         && Char.code bytes.[23] = 0x9d
         && Char.code bytes.[24] = 0x01
         && Char.code bytes.[25] = 0x2a
      then (
        let w = le16 bytes 26 land 0x3fff in
        let h = le16 bytes 28 land 0x3fff in
        if w > 0 && h > 0 then Some (w, h) else None)
      else None
    else if String.equal fourcc "VP8L"
    then
      if len >= 25 && Char.code bytes.[20] = 0x2f
      then (
        let b = le32 bytes 21 in
        let w = 1 + (b land 0x3fff) in
        let h = 1 + ((b lsr 14) land 0x3fff) in
        if w > 0 && h > 0 then Some (w, h) else None)
      else None
    else if String.equal fourcc "VP8X"
    then
      if len >= 30
      then (
        let w = 1 + le24 bytes 24 in
        let h = 1 + le24 bytes 27 in
        if w > 0 && h > 0 then Some (w, h) else None)
      else None
    else None)
  else None
;;

let detect_image_dimensions bytes =
  match sniff_mime bytes with
  | Some Image_png -> Rgb_png.header_dimensions bytes
  | Some Image_jpeg -> jpeg_walk bytes 2
  | Some Image_gif -> gif_dimensions bytes
  | Some Image_webp -> webp_dimensions bytes
  | Some (Application_pdf | Audio_mpeg | Audio_wav | Audio_ogg | Audio_midi) | None ->
    None
;;

type meta =
  { id : string
  ; sha256 : string
  ; mime_type : string
  ; kind : media_kind
  ; bytes : int
  ; width : int option
  ; height : int option
  ; filename : string option
  ; origin : origin
  ; created_at_unix : float
  ; created_by : string
  ; retention : retention
  }

type put_error =
  | Empty_payload
  | Payload_too_large of
      { actual : int
      ; maximum : int
      }
  | Unsupported_or_unknown_format of { declared_mime : string option }
  | Forbidden_mime of string
  | Mime_mismatch of
      { declared : string
      ; sniffed : string
      }
  | Invalid_keeper_name of string
  | Store_io_failed of string

let put_error_to_string = function
  | Empty_payload -> "attachment payload is empty"
  | Payload_too_large { actual; maximum } ->
    Printf.sprintf "attachment payload too large (%d bytes > max %d bytes)" actual maximum
  | Unsupported_or_unknown_format { declared_mime = Some m } ->
    Printf.sprintf "unsupported or unrecognized attachment format (declared %S)" m
  | Unsupported_or_unknown_format { declared_mime = None } ->
    "unsupported or unrecognized attachment format"
  | Forbidden_mime m ->
    Printf.sprintf "forbidden active attachment MIME type: %s" m
  | Mime_mismatch { declared; sniffed } ->
    Printf.sprintf
      "declared Content-Type %S does not match sniffed format %S"
      declared
      sniffed
  | Invalid_keeper_name name ->
    Printf.sprintf "invalid keeper name for ephemeral attachment: %S" name
  | Store_io_failed detail -> "attachment store I/O failed: " ^ detail
;;

type get_error =
  | Invalid_id of string
  | Integrity_mismatch of
      { id : string
      ; expected : string
      ; actual : string
      }
  | Corrupt_metadata of
      { id : string
      ; detail : string
      }
  | Read_failed of string

let get_error_to_string = function
  | Invalid_id raw -> Printf.sprintf "invalid attachment id: %S" raw
  | Integrity_mismatch { id; expected; actual } ->
    Printf.sprintf
      "attachment integrity mismatch for %s (expected %s, got %s)"
      id
      expected
      actual
  | Corrupt_metadata { id; detail } ->
    Printf.sprintf "corrupt attachment metadata for %s: %s" id detail
  | Read_failed detail -> "attachment read failed: " ^ detail
;;

type derivative_error =
  | Not_an_image of string
  | Invalid_max_px of int
  | Transform_failed of string

let derivative_error_to_string = function
  | Not_an_image mime ->
    Printf.sprintf "image transform requested for non-image attachment (%s)" mime
  | Invalid_max_px px ->
    Printf.sprintf "invalid max_px=%d (must be positive)" px
  | Transform_failed detail -> "image derivative transform failed: " ^ detail
;;

type target_format =
  | Native_format
  | Force_png

type t =
  { base_path : string
  ; root : string
  }

let create ~base_path =
  let root = Filename.concat (Common.masc_dir_from_base_path ~base_path) dirname in
  { base_path; root }
;;

let root_dir t = t.root
let base_path t = t.base_path

let is_lower_hex_char = function
  | '0' .. '9' | 'a' .. 'f' -> true
  | _ -> false
;;

let is_hex_char = function
  | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
  | _ -> false
;;

let is_valid_sha256 s =
  String.length s = 64 && String.for_all is_lower_hex_char s
;;

let id_of_sha256 sha256 =
  if is_valid_sha256 sha256
  then Ok (id_prefix ^ sha256)
  else Error (Printf.sprintf "expected 64-char lowercase hex sha256, got %S" sha256)
;;

let parse_id raw =
  let prefix_len = String.length id_prefix in
  if String.starts_with ~prefix:id_prefix raw
  then (
    let sha = String.sub raw prefix_len (String.length raw - prefix_len) in
    if is_valid_sha256 sha
    then Ok sha
    else Error "attachment id must be att_<64 lowercase hex chars>")
  else Error "attachment id must start with att_"
;;

let parse_id_or_sha256 raw =
  if String.starts_with ~prefix:id_prefix raw
  then parse_id raw
  else if is_valid_sha256 raw
  then Ok raw
  else Error "expected att_<64hex> or <64hex>"
;;

let url_of_id id = url_prefix ^ id

let sanitize_filename raw =
  let trimmed = String.trim raw in
  if String.equal trimmed ""
  then None
  else (
    (* Take basename across both POSIX and Windows separators first. *)
    let last_sep =
      let len = String.length trimmed in
      let rec scan i found =
        if i >= len
        then found
        else (
          let c = trimmed.[i] in
          let found = if c = '/' || c = '\\' then i else found in
          scan (i + 1) found)
      in
      scan 0 (-1)
    in
    let base =
      if last_sep >= 0
      then String.sub trimmed (last_sep + 1) (String.length trimmed - last_sep - 1)
      else trimmed
    in
    let buf = Buffer.create (min 180 (String.length base)) in
    String.iter
      (fun c ->
         if Buffer.length buf < 180
         then (
           let code = Char.code c in
           if code >= 0x20
              && code <> 0x7f
              && c <> '"'
              && c <> '\''
              && c <> ';'
              && c <> '/'
              && c <> '\\'
           then Buffer.add_char buf c))
      base;
    let cleaned = String.trim (Buffer.contents buf) in
    if String.equal cleaned "" || String.equal cleaned "." || String.equal cleaned ".."
    then None
    else Some cleaned)
;;

let is_valid_keeper_name name =
  let trimmed = String.trim name in
  String.equal trimmed name
  && not (String.equal trimmed "")
  && not (String.equal trimmed ".")
  && not (String.equal trimmed "..")
  && not (String.contains trimmed '/')
  && not (String.contains trimmed '\\')
  && not (String.contains trimmed '\000')
;;

let shard_of_sha256 sha256 = String.sub sha256 0 2
let blobs_root t = Filename.concat t.root "blobs"
let meta_root t = Filename.concat t.root "meta"
let ephemeral_root t = Filename.concat t.root "ephemeral"
let thumbs_root t = Filename.concat t.root "thumbs"

let blob_path t sha256 =
  Filename.concat (Filename.concat (blobs_root t) (shard_of_sha256 sha256)) sha256
;;

let meta_path t sha256 =
  Filename.concat
    (Filename.concat (meta_root t) (shard_of_sha256 sha256))
    (sha256 ^ ".json")
;;

let ephemeral_keeper_dir t keeper = Filename.concat (ephemeral_root t) keeper

let ephemeral_pin_path t ~keeper sha256 =
  Filename.concat (ephemeral_keeper_dir t keeper) sha256
;;

let thumb_dir t sha256 = Filename.concat (thumbs_root t) (shard_of_sha256 sha256)

let thumb_path t ~sha256 ~variant_key ~ext =
  Filename.concat (thumb_dir t sha256) (Printf.sprintf "%s_%s%s" sha256 variant_key ext)
;;

let ensure_owned_dir t dir =
  let inspect () =
    match Fs_compat.inspect_owned_directory_chain ~ownership_root:t.base_path dir with
    | Ok obs -> Ok obs
    | Error rej -> Error (Fs_compat.owned_directory_chain_rejection_to_string rej)
  in
  match inspect () with
  | Error _ as err -> err
  | Ok (Fs_compat.Owned_directory _) -> Ok ()
  | Ok Fs_compat.Owned_directory_missing ->
    (match Fs_compat.mkdir_p dir with
     | () ->
       (match inspect () with
        | Ok (Fs_compat.Owned_directory _) -> Ok ()
        | Ok Fs_compat.Owned_directory_missing -> Error ("directory not created: " ^ dir)
        | Error _ as err -> err)
     | exception Unix.Unix_error (code, fn, arg) ->
       Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code))
     | exception Sys_error msg -> Error msg)
;;

let int_opt_json = function
  | Some n -> `Int n
  | None -> `Null
;;

let string_opt_json = function
  | Some s -> `String s
  | None -> `Null
;;

let meta_to_wire_json (m : meta) : Yojson.Safe.t =
  `Assoc
    [ "id", `String m.id
    ; "attachment_id", `String m.id
    ; "sha256", `String m.sha256
    ; "url", `String (url_of_id m.id)
    ; "mime_type", `String m.mime_type
    ; "kind", `String (media_kind_to_string m.kind)
    ; "bytes", `Int m.bytes
    ; "width", int_opt_json m.width
    ; "height", int_opt_json m.height
    ; "filename", string_opt_json m.filename
    ; "origin", `String (origin_to_string m.origin)
    ; "created_at_unix", `Float m.created_at_unix
    ; "retention", `String (retention_to_wire_string m.retention)
    ]
;;

let meta_to_sidecar_json (m : meta) : Yojson.Safe.t =
  let keeper_field =
    match m.retention with
    | Durable -> []
    | Ephemeral { keeper } -> [ "ephemeral_keeper", `String keeper ]
  in
  match meta_to_wire_json m with
  | `Assoc fields ->
    `Assoc (fields @ [ "created_by", `String m.created_by ] @ keeper_field)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    (* unreachable: meta_to_wire_json always builds `Assoc *)
    `Assoc []
;;

let assoc_string fields key =
  match List.assoc_opt key fields with
  | Some (`String s) -> Ok s
  | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _) ->
    Error (Printf.sprintf "field %S must be a string" key)
  | None -> Error (Printf.sprintf "missing required field %S" key)
;;

let assoc_string_opt fields key =
  match List.assoc_opt key fields with
  | None | Some `Null -> Ok None
  | Some (`String s) -> Ok (Some s)
  | Some (`Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _) ->
    Error (Printf.sprintf "field %S must be a string or null" key)
;;

let assoc_int fields key =
  match List.assoc_opt key fields with
  | Some (`Int n) -> Ok n
  | Some (`Null | `Bool _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _) ->
    Error (Printf.sprintf "field %S must be an integer" key)
  | None -> Error (Printf.sprintf "missing required field %S" key)
;;

let assoc_int_opt fields key =
  match List.assoc_opt key fields with
  | None | Some `Null -> Ok None
  | Some (`Int n) -> Ok (Some n)
  | Some (`Bool _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _) ->
    Error (Printf.sprintf "field %S must be an integer or null" key)
;;

let assoc_float fields key =
  match List.assoc_opt key fields with
  | Some (`Float f) -> Ok f
  | Some (`Int n) -> Ok (float_of_int n)
  | Some (`Null | `Bool _ | `Intlit _ | `String _ | `Assoc _ | `List _) ->
    Error (Printf.sprintf "field %S must be a number" key)
  | None -> Error (Printf.sprintf "missing required field %S" key)
;;

let meta_of_sidecar_json ~expected_sha256 json =
  let open Result.Syntax in
  match json with
  | `Assoc fields ->
    let* id = assoc_string fields "id" in
    let* sha256 = assoc_string fields "sha256" in
    let* () =
      if String.equal sha256 expected_sha256 && String.equal id (id_prefix ^ expected_sha256)
      then Ok ()
      else Error "sidecar id/sha256 does not match digest path"
    in
    let* mime_type = assoc_string fields "mime_type" in
    let* kind_s = assoc_string fields "kind" in
    let* kind =
      match media_kind_of_string kind_s with
      | Some k -> Ok k
      | None -> Error (Printf.sprintf "unknown media kind %S" kind_s)
    in
    let* bytes = assoc_int fields "bytes" in
    let* width = assoc_int_opt fields "width" in
    let* height = assoc_int_opt fields "height" in
    let* filename = assoc_string_opt fields "filename" in
    let* origin_s = assoc_string fields "origin" in
    let* origin =
      match origin_of_string origin_s with
      | Some o -> Ok o
      | None -> Error (Printf.sprintf "unknown origin %S" origin_s)
    in
    let* created_at_unix = assoc_float fields "created_at_unix" in
    let* created_by_opt = assoc_string_opt fields "created_by" in
    let created_by = Option.value created_by_opt ~default:"unknown" in
    let* retention_s = assoc_string fields "retention" in
    let* retention =
      match retention_s with
      | "durable" -> Ok Durable
      | "ephemeral" ->
        let* keeper_opt = assoc_string_opt fields "ephemeral_keeper" in
        let keeper = Option.value keeper_opt ~default:"unknown" in
        Ok (Ephemeral { keeper })
      | other -> Error (Printf.sprintf "unknown retention %S" other)
    in
    Ok
      { id
      ; sha256
      ; mime_type
      ; kind
      ; bytes
      ; width
      ; height
      ; filename
      ; origin
      ; created_at_unix
      ; created_by
      ; retention
      }
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "sidecar JSON must be an object"
;;

let read_meta_by_validated_sha256 t ~id sha256 =
  let path = meta_path t sha256 in
  match Fs_compat.load_owned_regular_file ~ownership_root:t.base_path path with
  | Ok None -> Ok None
  | Error err ->
    Error (Read_failed (Fs_compat.owned_regular_file_read_error_to_string err))
  | Ok (Some payload) ->
    (match Yojson.Safe.from_string payload with
     | exception Yojson.Json_error msg ->
       Error (Corrupt_metadata { id; detail = msg })
     | json ->
       (match meta_of_sidecar_json ~expected_sha256:sha256 json with
        | Ok m -> Ok (Some m)
        | Error detail -> Error (Corrupt_metadata { id; detail })))
;;

let get_meta_by_sha256 t ~sha256 =
  if not (is_valid_sha256 sha256)
  then Error (Invalid_id sha256)
  else read_meta_by_validated_sha256 t ~id:(id_prefix ^ sha256) sha256
;;

let get_meta t ~id =
  match parse_id id with
  | Error _ -> Error (Invalid_id id)
  | Ok sha256 -> read_meta_by_validated_sha256 t ~id sha256
;;

let read_bytes_by_validated_sha256 t ~id sha256 =
  let path = blob_path t sha256 in
  match Fs_compat.load_owned_regular_file ~ownership_root:t.base_path path with
  | Ok None -> Ok None
  | Error err ->
    Error (Read_failed (Fs_compat.owned_regular_file_read_error_to_string err))
  | Ok (Some raw) ->
    let actual = Agent_core_sha256.to_hex (Agent_core_sha256.digest_string raw) in
    if String.equal actual sha256
    then Ok (Some raw)
    else Error (Integrity_mismatch { id; expected = sha256; actual })
;;

let get_bytes_by_sha256 t ~sha256 =
  if not (is_valid_sha256 sha256)
  then Error (Invalid_id sha256)
  else read_bytes_by_validated_sha256 t ~id:(id_prefix ^ sha256) sha256
;;

let get_bytes t ~id =
  match parse_id id with
  | Error _ -> Error (Invalid_id id)
  | Ok sha256 -> read_bytes_by_validated_sha256 t ~id sha256
;;

let remove_file_if_exists path =
  try Unix.unlink path with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let remove_thumbs_for_sha256 t sha256 =
  let dir = thumb_dir t sha256 in
  let prefix = sha256 ^ "_" in
  if Sys.file_exists dir && Sys.is_directory dir
  then (
    try
      Array.iter
        (fun entry ->
           if String.starts_with ~prefix entry
           then remove_file_if_exists (Filename.concat dir entry))
        (Sys.readdir dir)
    with
    | Sys_error _ | Unix.Unix_error _ -> ())
;;

let delete_unreferenced t ~sha256 =
  if not (is_valid_sha256 sha256)
  then Error (Printf.sprintf "invalid sha256: %S" sha256)
  else (
    let bpath = blob_path t sha256 in
    let mpath = meta_path t sha256 in
    let existed = Sys.file_exists bpath || Sys.file_exists mpath in
    try
      remove_thumbs_for_sha256 t sha256;
      remove_file_if_exists mpath;
      remove_file_if_exists bpath;
      Ok existed
    with
    | Unix.Unix_error (code, fn, arg) ->
      Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code))
    | Sys_error msg -> Error msg)
;;

let pin_payload ~bytes ~pinned_at =
  Yojson.Safe.to_string (`Assoc [ "bytes", `Int bytes; "pinned_at", `Float pinned_at ])
;;

let read_pin_info t path =
  match Fs_compat.load_owned_regular_file ~ownership_root:t.base_path path with
  | Ok (Some payload) ->
    (match Yojson.Safe.from_string payload with
     | `Assoc fields ->
       let bytes =
         match assoc_int fields "bytes" with
         | Ok n when n >= 0 -> n
         | Ok _ | Error _ -> 0
       in
       let pinned_at =
         match assoc_float fields "pinned_at" with
         | Ok f -> f
         | Error _ -> 0.0
       in
       Some (bytes, pinned_at)
     | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
     | exception Yojson.Json_error _ -> None)
  | Ok None | Error _ -> None
;;

let is_pinned_elsewhere t ~excluding_keeper sha256 =
  let root = ephemeral_root t in
  if not (Sys.file_exists root)
  then false
  else (
    try
      let entries = Sys.readdir root in
      Array.exists
        (fun keeper ->
           (not (String.equal keeper excluding_keeper))
           && is_valid_keeper_name keeper
           && Sys.file_exists (ephemeral_pin_path t ~keeper sha256))
        entries
    with
    | Sys_error _ | Unix.Unix_error _ -> false)
;;

let prune_ephemeral_keeper
      t
      ~keeper
      ~max_entries
      ~max_total_bytes
      ~just_pinned_sha256
  =
  let dir = ephemeral_keeper_dir t keeper in
  if not (Sys.file_exists dir)
  then ()
  else (
    let entries =
      try Sys.readdir dir |> Array.to_list with
      | Sys_error _ | Unix.Unix_error _ -> []
    in
    let pins =
      List.filter_map
        (fun name ->
           if not (is_valid_sha256 name)
           then None
           else (
             let path = Filename.concat dir name in
             match read_pin_info t path with
             | Some (bytes, pinned_at) -> Some (name, bytes, pinned_at, path)
             | None ->
               let mtime =
                 match Unix.lstat path with
                 | st -> st.Unix.st_mtime
                 | exception Unix.Unix_error _ -> 0.0
               in
               Some (name, 0, mtime, path)))
        entries
    in
    (* Sort oldest first so we evict LRU pins first. *)
    let sorted =
      List.sort
        (fun (sha_a, _, ts_a, _) (sha_b, _, ts_b, _) ->
           match Float.compare ts_a ts_b with
           | 0 -> String.compare sha_a sha_b
           | c -> c)
        pins
    in
    let total_count = ref (List.length sorted) in
    let total_bytes =
      ref (List.fold_left (fun acc (_, b, _, _) -> acc + b) 0 sorted)
    in
    List.iter
      (fun (sha256, bytes, _, path) ->
         let over_limit =
           !total_count > max_entries || !total_bytes > max_total_bytes
         in
         if over_limit && not (String.equal sha256 just_pinned_sha256)
         then (
           (try remove_file_if_exists path with Unix.Unix_error _ -> ());
           decr total_count;
           total_bytes := max 0 (!total_bytes - bytes);
           (* Only remove underlying blob/meta if retention is NOT Durable and
              no other keeper pins it. *)
           let is_durable =
             match get_meta_by_sha256 t ~sha256 with
             | Ok (Some { retention = Durable; _ }) -> true
             | Ok (Some { retention = Ephemeral _; _ }) | Ok None | Error _ -> false
           in
           if (not is_durable) && not (is_pinned_elsewhere t ~excluding_keeper:keeper sha256)
           then ignore (delete_unreferenced t ~sha256)))
      sorted)
;;

let validate_mime ~declared_mime ~bytes =
  let normalized_declared =
    Option.bind declared_mime (fun raw ->
      let n = normalize_mime_header raw in
      if String.equal n "" then None else Some n)
  in
  match normalized_declared with
  | Some d when is_forbidden_declared_mime d -> Error (Forbidden_mime d)
  | Some _ | None ->
    (match sniff_mime bytes with
     | None ->
       (match looks_like_forbidden_active_content bytes with
        | Some forbidden -> Error (Forbidden_mime forbidden)
        | None ->
          Error (Unsupported_or_unknown_format { declared_mime = normalized_declared }))
     | Some sniffed ->
       (match normalized_declared with
        | None | Some "application/octet-stream" -> Ok sniffed
        | Some declared ->
          (match supported_mime_of_normalized declared with
           | Some declared_supported when declared_supported = sniffed -> Ok sniffed
           | Some _ | None ->
             Error (Mime_mismatch { declared; sniffed = mime_to_string sniffed }))))
;;

let put
      ?max_bytes:max_bytes_opt
      ?(ephemeral_max_entries = default_ephemeral_max_entries)
      ?(ephemeral_max_bytes = default_ephemeral_max_bytes)
      ?(now = Unix.gettimeofday ())
      ?declared_mime
      ?filename
      ~origin
      ~created_by
      ~retention
      t
      ~bytes
  =
  let open Result.Syntax in
  let limit = Option.value max_bytes_opt ~default:(max_bytes ()) in
  let actual = String.length bytes in
  if actual = 0
  then Error Empty_payload
  else if actual > limit
  then Error (Payload_too_large { actual; maximum = limit })
  else
    let* () =
      match retention with
      | Durable -> Ok ()
      | Ephemeral { keeper } ->
        if is_valid_keeper_name keeper
        then Ok ()
        else Error (Invalid_keeper_name keeper)
    in
    let* sniffed = validate_mime ~declared_mime ~bytes in
    let sha256 = Agent_core_sha256.to_hex (Agent_core_sha256.digest_string bytes) in
    let id = id_prefix ^ sha256 in
    let bpath = blob_path t sha256 in
    let mpath = meta_path t sha256 in
    let* () =
      ensure_owned_dir t (Filename.dirname bpath)
      |> Result.map_error (fun e -> Store_io_failed e)
    in
    let* () =
      ensure_owned_dir t (Filename.dirname mpath)
      |> Result.map_error (fun e -> Store_io_failed e)
    in
    (* Write raw blob first so metadata never points to an absent blob.
       Verify ownership and content digest on any pre-existing blob: reuse only
       when an owned regular file already matches [sha256], atomically repair
       an owned regular file whose bytes are corrupt/truncated, and fail closed
       on symlink/ownership/I/O errors. *)
    let* () =
      match Fs_compat.sha256_owned_regular_file ~ownership_root:t.base_path bpath with
      | Ok (Some actual_sha) when String.equal actual_sha sha256 -> Ok ()
      | Ok (Some _) ->
        remove_thumbs_for_sha256 t sha256;
        Fs_compat.save_file_atomic_strict bpath bytes
        |> Result.map_error (fun e -> Store_io_failed e)
      | Ok None ->
        Fs_compat.save_file_atomic_strict bpath bytes
        |> Result.map_error (fun e -> Store_io_failed e)
      | Error err ->
        Error (Store_io_failed (Fs_compat.owned_regular_file_read_error_to_string err))
    in
    let width, height =
      match detect_image_dimensions bytes with
      | Some (w, h) -> Some w, Some h
      | None -> None, None
    in
    let clean_filename = Option.bind filename sanitize_filename in
    let clean_created_by =
      let s = String.trim created_by in
      if String.equal s "" then "unknown" else s
    in
    let* existing_meta =
      match read_meta_by_validated_sha256 t ~id sha256 with
      | Ok existing -> Ok existing
      | Error (Read_failed detail) -> Error (Store_io_failed detail)
      | Error ((Corrupt_metadata _ | Invalid_id _ | Integrity_mismatch _) as err) ->
        Error (Store_io_failed (get_error_to_string err))
    in
    let final_meta, needs_meta_write =
      match existing_meta with
      | None ->
        ( { id
          ; sha256
          ; mime_type = mime_to_string sniffed
          ; kind = media_kind_of_mime sniffed
          ; bytes = actual
          ; width
          ; height
          ; filename = clean_filename
          ; origin
          ; created_at_unix = now
          ; created_by = clean_created_by
          ; retention
          }
        , true )
      | Some prev ->
        (* Never downgrade Durable to Ephemeral; promote Ephemeral -> Durable. *)
        let next_retention, upgraded =
          match prev.retention, retention with
          | Durable, (Durable | Ephemeral _) -> Durable, false
          | Ephemeral _, Durable -> Durable, true
          | (Ephemeral _ as r), Ephemeral _ -> r, false
        in
        let next_filename =
          match prev.filename, clean_filename with
          | (Some _ as existing), _ -> existing
          | None, (Some _ as newly) -> newly
          | None, None -> None
        in
        let filename_changed = prev.filename <> next_filename in
        ( { prev with retention = next_retention; filename = next_filename }
        , upgraded || filename_changed )
    in
    let* () =
      if not needs_meta_write
      then Ok ()
      else (
        let payload = Yojson.Safe.to_string (meta_to_sidecar_json final_meta) in
        Fs_compat.save_file_atomic_strict mpath payload
        |> Result.map_error (fun e -> Store_io_failed e))
    in
    let* () =
      match retention with
      | Durable -> Ok ()
      | Ephemeral { keeper } ->
        let pin_path = ephemeral_pin_path t ~keeper sha256 in
        let* () =
          ensure_owned_dir t (Filename.dirname pin_path)
          |> Result.map_error (fun e -> Store_io_failed e)
        in
        let* () =
          Fs_compat.save_file_atomic_strict pin_path (pin_payload ~bytes:actual ~pinned_at:now)
          |> Result.map_error (fun e -> Store_io_failed e)
        in
        prune_ephemeral_keeper
          t
          ~keeper
          ~max_entries:ephemeral_max_entries
          ~max_total_bytes:ephemeral_max_bytes
          ~just_pinned_sha256:sha256;
        Ok ()
    in
    Ok final_meta
;;

let promote_to_durable t ~id =
  let open Result.Syntax in
  let* sha256 =
    match parse_id id with
    | Ok s -> Ok s
    | Error _ -> Error (Invalid_id id)
  in
  let* meta_opt = read_meta_by_validated_sha256 t ~id sha256 in
  match meta_opt with
  | None -> Ok None
  | Some m ->
    (match m.retention with
     | Durable -> Ok (Some m)
     | Ephemeral _ ->
       let promoted = { m with retention = Durable } in
       let mpath = meta_path t sha256 in
       let payload = Yojson.Safe.to_string (meta_to_sidecar_json promoted) in
       (match Fs_compat.save_file_atomic_strict mpath payload with
        | Ok () -> Ok (Some promoted)
        | Error detail -> Error (Read_failed ("promote write failed: " ^ detail))))
;;

let list_ephemeral t ~keeper =
  if not (is_valid_keeper_name keeper)
  then Error (Printf.sprintf "invalid keeper name: %S" keeper)
  else (
    let dir = ephemeral_keeper_dir t keeper in
    if not (Sys.file_exists dir)
    then Ok []
    else (
      try
        let entries = Sys.readdir dir |> Array.to_list in
        let items =
          List.filter_map
            (fun name ->
               if not (is_valid_sha256 name)
               then None
               else (
                 let path = Filename.concat dir name in
                 let pinned_at =
                   match read_pin_info t path with
                   | Some (_, ts) -> ts
                   | None -> 0.0
                 in
                 match get_meta_by_sha256 t ~sha256:name with
                 | Ok (Some m) -> Some (pinned_at, m)
                 | Ok None | Error _ -> None))
            entries
        in
        let sorted =
          List.sort
            (fun (ts_a, (a : meta)) (ts_b, (b : meta)) ->
               match Float.compare ts_b ts_a with
               | 0 -> String.compare a.sha256 b.sha256
               | c -> c)
            items
        in
        Ok (List.map snd sorted)
      with
      | Sys_error msg -> Error msg
      | Unix.Unix_error (code, fn, arg) ->
        Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code))))
;;

let list_all_ephemeral_pins t =
  let root = ephemeral_root t in
  if not (Sys.file_exists root)
  then String_set.empty
  else (
    try
      Array.fold_left
        (fun acc keeper ->
           if not (is_valid_keeper_name keeper)
           then acc
           else (
             let dir = Filename.concat root keeper in
             match Unix.lstat dir with
             | { Unix.st_kind = Unix.S_DIR; _ } ->
               (try
                  Array.fold_left
                    (fun acc name ->
                       if is_valid_sha256 name then String_set.add name acc else acc)
                    acc
                    (Sys.readdir dir)
                with
                | Sys_error _ | Unix.Unix_error _ -> acc)
             | { Unix.st_kind =
                   Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK
               ; _
               }
             | exception Unix.Unix_error _ -> acc))
        String_set.empty
        (Sys.readdir root)
    with
    | Sys_error _ | Unix.Unix_error _ -> String_set.empty)
;;

let list_all_blobs t =
  let root = blobs_root t in
  if not (Sys.file_exists root)
  then Ok []
  else (
    try
      let shards = Sys.readdir root |> Array.to_list |> List.sort String.compare in
      let digests =
        List.fold_left
          (fun acc shard ->
             if String.length shard <> 2 || not (String.for_all is_lower_hex_char shard)
             then acc
             else (
               let sdir = Filename.concat root shard in
               match Unix.lstat sdir with
               | { Unix.st_kind = Unix.S_DIR; _ } ->
                 let names =
                   Sys.readdir sdir |> Array.to_list |> List.sort String.compare
                 in
                 List.fold_left
                   (fun acc name ->
                      if is_valid_sha256 name && String.starts_with ~prefix:shard name
                      then name :: acc
                      else acc)
                   acc
                   names
               | { Unix.st_kind =
                     Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK
                 ; _
                 }
               | exception Unix.Unix_error _ -> acc))
          []
          shards
      in
      Ok (List.rev digests)
    with
    | Sys_error msg -> Error msg
    | Unix.Unix_error (code, fn, arg) ->
      Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)))
;;

(* --- Image derivative generation (downscale / PNG transcode + thumbs cache) --- *)

let read_file_binary path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let len = in_channel_length ic in
      really_input_string ic len)
;;

let clamp_thumb_px px =
  if px < min_thumb_px
  then min_thumb_px
  else if px > max_thumb_px
  then max_thumb_px
  else px
;;

type raster_mime =
  | R_png
  | R_jpeg
  | R_gif
  | R_webp

let raster_mime_of_string = function
  | "image/png" -> Some R_png
  | "image/jpeg" -> Some R_jpeg
  | "image/gif" -> Some R_gif
  | "image/webp" -> Some R_webp
  | _ -> None
;;

let supported_mime_of_raster = function
  | R_png -> Image_png
  | R_jpeg -> Image_jpeg
  | R_gif -> Image_gif
  | R_webp -> Image_webp
;;

let sips_format_name = function
  | R_png -> "png"
  | R_jpeg -> "jpeg"
  | R_gif -> "gif"
  | R_webp -> "png" (* macOS sips cannot write WebP; emit PNG *)
;;

let run_transform_argv ~in_file ~out_file ~max_px ~src_raster ~out_raster =
  let sips_argv =
    let fmt =
      if src_raster <> out_raster || src_raster = R_webp
      then [ "-s"; "format"; sips_format_name out_raster ]
      else []
    in
    let resize =
      match max_px with
      | Some px -> [ "-Z"; string_of_int px ]
      | None -> []
    in
    ("sips" :: fmt) @ resize @ [ in_file; "--out"; out_file ]
  in
  let magick_in =
    match src_raster with
    | R_gif -> in_file ^ "[0]"
    | R_png | R_jpeg | R_webp -> in_file
  in
  let magick_plan bin =
    let resize =
      match max_px with
      | Some px -> [ "-resize"; Printf.sprintf "%dx%d>" px px ]
      | None -> []
    in
    (bin :: magick_in :: resize) @ [ out_file ]
  in
  let plans = [ sips_argv; magick_plan "magick"; magick_plan "convert" ] in
  let rec try_plans errors = function
    | [] -> Error (String.concat "; " (List.rev errors))
    | argv :: rest ->
      (try remove_file_if_exists out_file with Unix.Unix_error _ -> ());
      (match
         Process_eio.run_argv_with_status_split_or_refusal
           ~timeout_sec:transform_timeout_sec
           argv
       with
       | Error refusal ->
         let msg =
           Printf.sprintf
             "%s: %s"
             (List.hd argv)
             (Process_eio.spawn_refusal_to_string refusal)
         in
         try_plans (msg :: errors) rest
       | Ok (status, _stdout, stderr) ->
         (match Process_eio.exit_reason_of_status status with
          | Process_eio.Completed 0
            when Sys.file_exists out_file
                 &&
                 (match Fs_compat.file_size out_file with
                  | Some sz -> sz > 0
                  | None -> false) ->
            let out_bytes = read_file_binary out_file in
            let expected_mime = supported_mime_of_raster out_raster in
            (match sniff_mime out_bytes with
             | Some actual_mime when actual_mime = expected_mime ->
               let dims_ok =
                 match max_px, detect_image_dimensions out_bytes with
                 | None, _ -> true
                 | Some bound, Some (w, h) -> max w h <= bound
                 | Some _, None -> false
               in
               if dims_ok
               then Ok (mime_to_string actual_mime, out_bytes)
               else (
                 let msg =
                   Printf.sprintf
                     "%s output dimensions exceeded max_px or were unreadable"
                     (List.hd argv)
                 in
                 try_plans (msg :: errors) rest)
             | Some actual_mime ->
               let msg =
                 Printf.sprintf
                   "%s wrote %s instead of %s"
                   (List.hd argv)
                   (mime_to_string actual_mime)
                   (mime_to_string expected_mime)
               in
               try_plans (msg :: errors) rest
             | None ->
               let msg =
                 Printf.sprintf "%s wrote unrecognized image output" (List.hd argv)
               in
               try_plans (msg :: errors) rest)
          | Process_eio.Completed code ->
            let msg =
              Printf.sprintf "%s exited %d (%s)" (List.hd argv) code (String.trim stderr)
            in
            try_plans (msg :: errors) rest
          | Process_eio.Timed_out ->
            try_plans (Printf.sprintf "%s timed out" (List.hd argv) :: errors) rest
          | Process_eio.Signaled sig_n ->
            try_plans
              (Printf.sprintf "%s signaled %d" (List.hd argv) sig_n :: errors)
              rest
          | Process_eio.Stopped sig_n ->
            try_plans
              (Printf.sprintf "%s stopped %d" (List.hd argv) sig_n :: errors)
              rest))
  in
  try_plans [] plans
;;

let get_image_derivative ?max_px ~target_format t ~(meta : meta) ~raw_bytes =
  match meta.kind, raster_mime_of_string meta.mime_type with
  | (Audio | Document), _ | Image, None -> Error (Not_an_image meta.mime_type)
  | Image, Some src_raster ->
    (match max_px with
     | Some px when px <= 0 -> Error (Invalid_max_px px)
     | Some _ | None ->
       let clamped_px = Option.map clamp_thumb_px max_px in
       let out_raster =
         match target_format, src_raster with
         | Force_png, _ -> R_png
         | Native_format, R_webp ->
           (* Keep WebP when no resize needed; when resized via sips, output is PNG *)
           (match clamped_px with
            | None -> R_webp
            | Some _ -> R_png)
         | Native_format, (R_png | R_jpeg | R_gif as r) -> r
       in
       let dims_within_bound =
         match clamped_px, meta.width, meta.height with
         | None, _, _ -> true
         | Some bound, Some w, Some h -> max w h <= bound
         | Some _, None, _ | Some _, _, None -> false
       in
       if dims_within_bound && src_raster = out_raster
       then Ok (meta.mime_type, raw_bytes)
       else (
         let out_mime_supported = supported_mime_of_raster out_raster in
         let out_ext = extension_of_mime out_mime_supported in
         let variant_key =
           match clamped_px with
           | Some px -> string_of_int px
           | None -> "orig"
         in
         let cache_path = thumb_path t ~sha256:meta.sha256 ~variant_key ~ext:out_ext in
         let generate () =
           let src_ext = extension_of_mime (supported_mime_of_raster src_raster) in
           let in_file, in_oc =
             Filename.open_temp_file ~mode:[ Open_binary ] "masc_att_in_" src_ext
           in
           let out_file = Filename.temp_file "masc_att_out_" out_ext in
           let res =
             Fun.protect
               ~finally:(fun () ->
                 close_out_noerr in_oc;
                 (try Sys.remove in_file with Sys_error _ | Unix.Unix_error _ -> ());
                 (try Sys.remove out_file with Sys_error _ | Unix.Unix_error _ -> ()))
               (fun () ->
                 output_string in_oc raw_bytes;
                 close_out_noerr in_oc;
                 run_transform_argv
                   ~in_file
                   ~out_file
                   ~max_px:clamped_px
                   ~src_raster
                   ~out_raster)
           in
           match res with
           | Error detail -> Error (Transform_failed detail)
           | Ok (actual_mime, out_bytes) ->
             (match ensure_owned_dir t (Filename.dirname cache_path) with
              | Ok () -> ignore (Fs_compat.save_file_atomic_strict cache_path out_bytes)
              | Error _ -> ());
             Ok (actual_mime, out_bytes)
         in
         match Fs_compat.load_owned_regular_file ~ownership_root:t.base_path cache_path with
         | Ok (Some cached) ->
           (match sniff_mime cached with
            | Some m when m = out_mime_supported ->
              let dims_ok =
                match clamped_px, detect_image_dimensions cached with
                | None, _ -> true
                | Some bound, Some (w, h) -> max w h <= bound
                | Some _, None -> false
              in
              if dims_ok
              then Ok (mime_to_string m, cached)
              else (
                (try remove_file_if_exists cache_path with Unix.Unix_error _ -> ());
                generate ())
            | Some _ | None ->
              (* Corrupt or wrong-format cache file is removed and regenerated cleanly. *)
              (try remove_file_if_exists cache_path with Unix.Unix_error _ -> ());
              generate ())
         | Ok None | Error _ -> generate ()))
;;

(* --- Reachability scanning (att_<64hex> extractor) --- *)

let extract_att_ids text =
  let len = String.length text in
  let prefix_len = String.length id_prefix in
  let id_len = prefix_len + 64 in
  let rec scan i acc =
    if i + id_len > len
    then List.rev acc
    else if text.[i] = 'a'
            && text.[i + 1] = 't'
            && text.[i + 2] = 't'
            && text.[i + 3] = '_'
    then (
      let prev_ok =
        i = 0
        ||
        let p = text.[i - 1] in
        not (is_hex_char p || (p >= 'g' && p <= 'z') || (p >= 'G' && p <= 'Z') || p = '_')
      in
      let next_ok =
        i + id_len = len || not (is_hex_char text.[i + id_len])
      in
      if prev_ok && next_ok
      then (
        let sha = String.sub text (i + prefix_len) 64 in
        if is_valid_sha256 sha
        then scan (i + id_len) ((id_prefix ^ sha) :: acc)
        else scan (i + 1) acc)
      else scan (i + 1) acc)
    else scan (i + 1) acc
  in
  scan 0 []
;;

let referenced_sha256_of_json_text text =
  let prefix_len = String.length id_prefix in
  List.fold_left
    (fun acc id ->
       let sha = String.sub id prefix_len 64 in
       String_set.add sha acc)
    String_set.empty
    (extract_att_ids text)
;;
