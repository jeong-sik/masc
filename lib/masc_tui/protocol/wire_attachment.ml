open Json_decode_fields
open Wire_common

let ( let* ) = Result.bind

type kind =
  | Kind_image
  | Kind_audio
  | Kind_video
  | Kind_document

type t = {
  id : string;
  attachment_id : string;
  sha256 : string option;
  url : string;
  mime_type : string;
  kind : kind;
  bytes : int;
  width : int option;
  height : int option;
  filename : string option;
  origin : string option;
  retention : string option;
}

let equal_kind a b =
  match a, b with
  | Kind_image, Kind_image
  | Kind_audio, Kind_audio
  | Kind_video, Kind_video
  | Kind_document, Kind_document ->
      true
  | Kind_image, (Kind_audio | Kind_video | Kind_document)
  | Kind_audio, (Kind_image | Kind_video | Kind_document)
  | Kind_video, (Kind_image | Kind_audio | Kind_document)
  | Kind_document, (Kind_image | Kind_audio | Kind_video) ->
      false

let equal a b =
  String.equal a.id b.id
  && String.equal a.attachment_id b.attachment_id
  && Option.equal String.equal a.sha256 b.sha256
  && String.equal a.url b.url
  && String.equal a.mime_type b.mime_type
  && equal_kind a.kind b.kind
  && Int.equal a.bytes b.bytes
  && Option.equal Int.equal a.width b.width
  && Option.equal Int.equal a.height b.height
  && Option.equal String.equal a.filename b.filename
  && Option.equal String.equal a.origin b.origin
  && Option.equal String.equal a.retention b.retention

let kind_to_string = function
  | Kind_image -> "image"
  | Kind_audio -> "audio"
  | Kind_video -> "video"
  | Kind_document -> "document"

let kind_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "image" -> Some Kind_image
  | "audio" -> Some Kind_audio
  | "video" -> Some Kind_video
  | "document" | "pdf" | "file" -> Some Kind_document
  | _ -> None

let kind_of_mime mime =
  let low = String.lowercase_ascii (String.trim mime) in
  if String.starts_with ~prefix:"image/" low then Kind_image
  else if String.starts_with ~prefix:"audio/" low then Kind_audio
  else if String.starts_with ~prefix:"video/" low then Kind_video
  else Kind_document

let attachments_upload_path = "/api/v1/attachments"
let attachment_path_prefix = "/api/v1/attachments/"
let media_path_prefix = "/api/v1/media/"

let is_attachment_path path =
  String.starts_with ~prefix:attachment_path_prefix path
  || String.starts_with ~prefix:media_path_prefix path

let attachment_path id = attachment_path_prefix ^ percent_encode (String.trim id)

let attachment_meta_path id = attachment_path id ^ "/meta"

let encode_filename_header raw =
  let trimmed = String.trim raw in
  if String.equal trimmed "" then ""
  else
    let base = Filename.basename trimmed in
    let clean = Buffer.create (String.length base) in
    String.iter
      (fun c ->
        let code = Char.code c in
        if code >= 0x20 && code <> 0x7F then Buffer.add_char clean c)
      base;
    percent_encode (String.trim (Buffer.contents clean))

let strip_query path =
  match String.index_opt path '?' with
  | Some idx -> String.sub path 0 idx
  | None -> path

let attachment_render_path ?format ?max_px ?(download = false) path =
  if not (is_attachment_path path) then path
  else
    let base = strip_query path in
    let params =
      (match format with
       | Some f when not (String.equal (String.trim f) "") ->
           [ "format=" ^ percent_encode (String.trim f) ]
       | Some _ | None -> [])
      @ (match max_px with
         | Some n when n > 0 -> [ Printf.sprintf "max_px=%d" n ]
         | Some _ | None -> [])
      @ if download then [ "download=1" ] else []
    in
    match params with
    | [] -> path
    | _ -> base ^ "?" ^ String.concat "&" params

let normalize_mime mime =
  match String.lowercase_ascii (String.trim mime) with
  | "image/jpg" -> "image/jpeg"
  | "audio/x-midi" | "audio/mid" -> "audio/midi"
  | "audio/x-wav" | "audio/wave" -> "audio/wav"
  | "audio/x-m4a" -> "audio/mp4"
  | "video/x-m4v" -> "video/mp4"
  | other -> other

let is_raster_image_mime mime =
  match normalize_mime mime with
  | "image/png" | "image/jpeg" | "image/webp" | "image/gif" -> true
  | _ -> false

let is_video_mime mime =
  match normalize_mime mime with
  | "video/mp4" | "video/webm" | "video/quicktime" -> true
  | _ -> false

let is_playable_media_mime mime =
  let norm = normalize_mime mime in
  is_video_mime norm || String.starts_with ~prefix:"audio/" norm

let max_non_video_upload_bytes = 20 * 1024 * 1024
let max_video_upload_bytes = 50 * 1024 * 1024

let max_upload_bytes_for_mime mime =
  if is_video_mime mime then max_video_upload_bytes
  else max_non_video_upload_bytes

let extension_of_mime mime =
  match normalize_mime mime with
  | "image/png" -> ".png"
  | "image/jpeg" -> ".jpg"
  | "image/webp" -> ".webp"
  | "image/gif" -> ".gif"
  | "application/pdf" -> ".pdf"
  | "audio/mpeg" -> ".mp3"
  | "audio/wav" -> ".wav"
  | "audio/ogg" -> ".ogg"
  | "audio/midi" -> ".mid"
  | "audio/mp4" -> ".m4a"
  | "audio/webm" -> ".webm"
  | "video/mp4" -> ".mp4"
  | "video/webm" -> ".webm"
  | "video/quicktime" -> ".mov"
  | _ -> ".bin"

let extension_mime_opt filename =
  let ext = String.lowercase_ascii (Filename.extension filename) in
  match ext with
  | ".png" -> Some "image/png"
  | ".jpg" | ".jpeg" -> Some "image/jpeg"
  | ".webp" -> Some "image/webp"
  | ".gif" -> Some "image/gif"
  | ".pdf" -> Some "application/pdf"
  | ".mp3" -> Some "audio/mpeg"
  | ".wav" -> Some "audio/wav"
  | ".ogg" | ".oga" -> Some "audio/ogg"
  | ".mid" | ".midi" -> Some "audio/midi"
  | ".m4a" -> Some "audio/mp4"
  | ".weba" -> Some "audio/webm"
  | ".mp4" | ".m4v" -> Some "video/mp4"
  | ".mov" -> Some "video/quicktime"
  | ".webm" -> Some "video/webm"
  | _ -> None

let has_supported_media_extension path =
  Option.is_some (extension_mime_opt path)

let starts_with_at ~offset ~prefix s =
  let plen = String.length prefix in
  offset >= 0 && offset + plen <= String.length s
  && String.sub s offset plen = prefix

let contains_sub_in_range ~needle ~haystack ~start ~stop =
  let nlen = String.length needle in
  let limit = Int.min stop (String.length haystack) in
  if nlen = 0 || start < 0 || start + nlen > limit then false
  else
    let rec loop i =
      if i + nlen > limit then false
      else
        let rec eq j =
          if j >= nlen then true
          else if Char.equal haystack.[i + j] needle.[j] then eq (j + 1)
          else false
        in
        if eq 0 then true else loop (i + 1)
    in
    loop start

let mp4_has_video_handler_in_range bytes ~start ~stop =
  let limit = Int.min stop (String.length bytes) in
  let rec loop i =
    if i + 16 > limit then false
    else if
      bytes.[i] = 'h'
      && bytes.[i + 1] = 'd'
      && bytes.[i + 2] = 'l'
      && bytes.[i + 3] = 'r'
      && bytes.[i + 12] = 'v'
      && bytes.[i + 13] = 'i'
      && bytes.[i + 14] = 'd'
      && bytes.[i + 15] = 'e'
    then true
    else loop (i + 1)
  in
  loop (Int.max 0 start)

let is_ftyp_container bytes =
  String.length bytes >= 12 && starts_with_at ~offset:4 ~prefix:"ftyp" bytes

let sniff_ftyp_mime bytes =
  let len = String.length bytes in
  if not (is_ftyp_container bytes) then None
  else
    let box_size =
      (Char.code bytes.[0] lsl 24)
      lor (Char.code bytes.[1] lsl 16)
      lor (Char.code bytes.[2] lsl 8)
      lor Char.code bytes.[3]
    in
    if box_size < 12 || box_size > len || box_size mod 4 <> 0 then None
    else
      let is_qt_brand b = String.equal b "qt  " in
      let is_audio_brand = function
        | "M4A " | "M4B " | "mp42" | "isom" | "dash" -> true
        | _ -> false
      in
      let is_iso_mp4_brand = function
        | "M4A " | "M4B " | "mp41" | "mp42" | "isom" | "iso2" | "dash" -> true
        | _ -> false
      in
      let is_video_brand = function
        | "M4V " | "m4v " | "3gp4" | "3gp5" | "3gp6" | "3g2a"
        | "avc1" | "hev1" | "hvc1" ->
            true
        | _ -> false
      in
      let major = String.sub bytes 8 4 in
      let compat_limit = Int.min box_size 128 in
      let rec scan_brands off has_qt has_audio has_iso has_video =
        if off + 4 > compat_limit then (has_qt, has_audio, has_iso, has_video)
        else
          let brand = String.sub bytes off 4 in
          scan_brands (off + 4)
            (has_qt || is_qt_brand brand)
            (has_audio || is_audio_brand brand)
            (has_iso || is_iso_mp4_brand brand)
            (has_video || is_video_brand brand)
      in
      let has_qt, has_audio, has_iso, has_video =
        scan_brands 16 (is_qt_brand major) (is_audio_brand major)
          (is_iso_mp4_brand major) (is_video_brand major)
      in
      if has_qt then Some "video/quicktime"
      else if has_video then Some "video/mp4"
      else if not has_iso then None
      else
        let has_vide_track =
          if len <= 512 * 1024 then
            mp4_has_video_handler_in_range bytes ~start:0 ~stop:len
          else
            mp4_has_video_handler_in_range bytes ~start:0 ~stop:(256 * 1024)
            || mp4_has_video_handler_in_range bytes
                 ~start:(len - (256 * 1024))
                 ~stop:len
        in
        if has_vide_track then Some "video/mp4"
        else if has_audio then Some "audio/mp4"
        else None

let is_ebml_webm_container bytes =
  let len = String.length bytes in
  len >= 16
  && starts_with_at ~offset:0 ~prefix:"\x1a\x45\xdf\xa3" bytes
  && contains_sub_in_range ~needle:"\x42\x82\x84webm" ~haystack:bytes ~start:4
       ~stop:(Int.min len 128)

let sniff_webm_mime bytes =
  if not (is_ebml_webm_container bytes) then None
  else
    let scan_stop = Int.min (String.length bytes) 65536 in
    let has_video =
      contains_sub_in_range ~needle:"V_VP8" ~haystack:bytes ~start:4
        ~stop:scan_stop
      || contains_sub_in_range ~needle:"V_VP9" ~haystack:bytes ~start:4
           ~stop:scan_stop
      || contains_sub_in_range ~needle:"V_AV1" ~haystack:bytes ~start:4
           ~stop:scan_stop
      || contains_sub_in_range ~needle:"\x83\x81\x01" ~haystack:bytes ~start:4
           ~stop:scan_stop
    in
    if has_video then Some "video/webm" else Some "audio/webm"

let is_mpeg_audio_frame_sync bytes =
  if String.length bytes < 4 then false
  else
    let b0 = Char.code bytes.[0] in
    let b1 = Char.code bytes.[1] in
    let b2 = Char.code bytes.[2] in
    let version = (b1 lsr 3) land 0x03 in
    let layer = (b1 lsr 1) land 0x03 in
    let bitrate_idx = (b2 lsr 4) land 0x0F in
    let sample_rate_idx = (b2 lsr 2) land 0x03 in
    b0 = 0xFF
    && (b1 land 0xE0) = 0xE0
    && version <> 0x01
    && layer <> 0x00
    && bitrate_idx <> 0x0F
    && sample_rate_idx <> 0x03

let looks_like_forbidden_markup bytes =
  let len = Int.min 512 (String.length bytes) in
  let prefix = String.lowercase_ascii (String.trim (String.sub bytes 0 len)) in
  String.starts_with ~prefix:"<svg" prefix
  || String.starts_with ~prefix:"<?xml" prefix
  || String.starts_with ~prefix:"<!doctype html" prefix
  || String.starts_with ~prefix:"<html" prefix

let sniff_magic bytes =
  let len = String.length bytes in
  if len = 0 || looks_like_forbidden_markup bytes then None
  else if len >= 8 && starts_with_at ~offset:0 ~prefix:"\137PNG\r\n\026\n" bytes then
    Some "image/png"
  else if
    len >= 3
    && Char.code bytes.[0] = 0xFF
    && Char.code bytes.[1] = 0xD8
    && Char.code bytes.[2] = 0xFF
  then Some "image/jpeg"
  else if
    len >= 6
    && (starts_with_at ~offset:0 ~prefix:"GIF87a" bytes
       || starts_with_at ~offset:0 ~prefix:"GIF89a" bytes)
  then Some "image/gif"
  else if
    len >= 12
    && starts_with_at ~offset:0 ~prefix:"RIFF" bytes
    && starts_with_at ~offset:8 ~prefix:"WEBP" bytes
  then Some "image/webp"
  else if len >= 5 && starts_with_at ~offset:0 ~prefix:"%PDF-" bytes then
    Some "application/pdf"
  else if
    len >= 12
    && starts_with_at ~offset:0 ~prefix:"RIFF" bytes
    && starts_with_at ~offset:8 ~prefix:"WAVE" bytes
  then Some "audio/wav"
  else if len >= 4 && starts_with_at ~offset:0 ~prefix:"OggS" bytes then
    Some "audio/ogg"
  else if len >= 4 && starts_with_at ~offset:0 ~prefix:"MThd" bytes then
    Some "audio/midi"
  else
    match sniff_ftyp_mime bytes with
    | Some _ as m -> m
    | None -> (
        match sniff_webm_mime bytes with
        | Some _ as m -> m
        | None ->
            if
              (len >= 3 && starts_with_at ~offset:0 ~prefix:"ID3" bytes)
              || is_mpeg_audio_frame_sync bytes
            then Some "audio/mpeg"
            else None)

let sniff_mime ?filename bytes =
  if String.length bytes = 0 || looks_like_forbidden_markup bytes then None
  else
    match sniff_magic bytes with
    | Some _ as m -> m
    | None -> Option.bind filename extension_mime_opt

let hex_digit_val c =
  match c with
  | '0' .. '9' -> Some (Char.code c - Char.code '0')
  | 'a' .. 'f' -> Some (10 + Char.code c - Char.code 'a')
  | 'A' .. 'F' -> Some (10 + Char.code c - Char.code 'A')
  | _ -> None

let percent_decode s =
  let len = String.length s in
  let buf = Buffer.create len in
  let rec loop i =
    if i >= len then Buffer.contents buf
    else if s.[i] = '%' && i + 2 < len then
      match hex_digit_val s.[i + 1], hex_digit_val s.[i + 2] with
      | Some hi, Some lo ->
          Buffer.add_char buf (Char.chr ((hi lsl 4) lor lo));
          loop (i + 3)
      | _ ->
          Buffer.add_char buf s.[i];
          loop (i + 1)
    else begin
      Buffer.add_char buf s.[i];
      loop (i + 1)
    end
  in
  loop 0

let unescape_shell_path s =
  let len = String.length s in
  let buf = Buffer.create len in
  let rec loop i =
    if i >= len then Buffer.contents buf
    else if s.[i] = '\\' && i + 1 < len then begin
      let next = s.[i + 1] in
      match next with
      | ' ' | '\'' | '"' | '(' | ')' | '[' | ']' | '&' | ';' | '!' | '#' | '$'
      | '~' | '\\' ->
          Buffer.add_char buf next;
          loop (i + 2)
      | _ ->
          Buffer.add_char buf '\\';
          loop (i + 1)
    end
    else begin
      Buffer.add_char buf s.[i];
      loop (i + 1)
    end
  in
  loop 0

let expand_tilde path =
  if String.starts_with ~prefix:"~/" path then
    match Sys.getenv_opt "HOME" with
    | Some home when not (String.equal (String.trim home) "") ->
        Filename.concat home (String.sub path 2 (String.length path - 2))
    | Some _ | None -> path
  else path

let normalize_pasted_path raw =
  let trimmed = String.trim raw in
  if
    String.equal trimmed ""
    || String.contains trimmed '\n'
    || String.contains trimmed '\r'
  then None
  else
    let unquoted, was_quoted =
      let len = String.length trimmed in
      if
        len >= 2
        && ((trimmed.[0] = '\'' && trimmed.[len - 1] = '\'')
            || (trimmed.[0] = '"' && trimmed.[len - 1] = '"'))
      then (String.sub trimmed 1 (len - 2), true)
      else (trimmed, false)
    in
    let decoded =
      if String.starts_with ~prefix:"file://localhost/" unquoted then
        percent_decode
          (String.sub unquoted 16 (String.length unquoted - 16))
      else if String.starts_with ~prefix:"file:///" unquoted then
        percent_decode (String.sub unquoted 7 (String.length unquoted - 7))
      else if was_quoted then unquoted
      else unescape_shell_path unquoted
    in
    let cleaned = expand_tilde (String.trim decoded) in
    if String.equal cleaned "" then None
    else if
      String.starts_with ~prefix:"/" cleaned
      || String.starts_with ~prefix:"./" cleaned
      || String.starts_with ~prefix:"../" cleaned
    then Some cleaned
    else None

let sniff_file_header path =
  match open_in_bin path with
  | exception Sys_error _ -> None
  | ch ->
      Fun.protect
        ~finally:(fun () -> close_in_noerr ch)
        (fun () ->
          let buf = Bytes.create 512 in
          let n =
            try input ch buf 0 512 with Sys_error _ -> 0
          in
          if n <= 0 then None
          else sniff_magic (Bytes.sub_string buf 0 n))

let resolve_local_media_file raw =
  match normalize_pasted_path raw with
  | None -> None
  | Some path -> (
      let is_non_empty_file =
        try
          Sys.file_exists path
          && (not (Sys.is_directory path))
          && In_channel.with_open_bin path (fun ch ->
                 Int64.compare (In_channel.length ch) 0L > 0)
        with Sys_error _ -> false
      in
      if not is_non_empty_file then None
      else if has_supported_media_extension path then Some path
      else
        match sniff_file_header path with
        | Some _ -> Some path
        | None -> None)

let decode_attachment_ref json =
  let* id_opt = optional_nonblank_string json "id" in
  let* att_id_opt = optional_nonblank_string json "attachment_id" in
  let* id, attachment_id =
    match id_opt, att_id_opt with
    | Some i, Some a -> Ok (i, a)
    | Some i, None -> Ok (i, i)
    | None, Some a -> Ok (a, a)
    | None, None ->
        Error "attachment ref requires non-blank 'id' or 'attachment_id'"
  in
  let* sha256 = optional_nonblank_string json "sha256" in
  let* url_opt = optional_nonblank_string json "url" in
  let url =
    match url_opt with
    | Some u -> u
    | None -> attachment_path attachment_id
  in
  let* mime_opt =
    match optional_nonblank_string json "mime_type" with
    | Ok (Some _ as m) -> Ok m
    | Ok None -> optional_nonblank_string json "mimeType"
    | Error _ as err -> err
  in
  let mime_type = Option.value mime_opt ~default:"application/octet-stream" in
  let* kind_str = optional_nonblank_string json "kind" in
  let kind =
    match Option.bind kind_str kind_of_string with
    | Some k -> k
    | None -> kind_of_mime mime_type
  in
  let* bytes_opt =
    match optional_int_field json "bytes" with
    | Ok (Some _ as b) -> Ok b
    | Ok None -> optional_int_field json "size"
    | Error _ as err -> err
  in
  let bytes = Int.max 0 (Option.value bytes_opt ~default:0) in
  let* width = optional_int_field json "width" in
  let* height = optional_int_field json "height" in
  let* filename =
    match optional_nonblank_string json "filename" with
    | Ok (Some _ as f) -> Ok f
    | Ok None -> optional_nonblank_string json "name"
    | Error _ as err -> err
  in
  let* origin = optional_nonblank_string json "origin" in
  let* retention = optional_nonblank_string json "retention" in
  Ok
    {
      id;
      attachment_id;
      sha256;
      url;
      mime_type;
      kind;
      bytes;
      width;
      height;
      filename;
      origin;
      retention;
    }

let decode_upload_response json =
  let* _, body = unwrap_v2_or_raw json in
  match optional_object_field body "data" with
  | Ok (Some data_obj) -> decode_attachment_ref data_obj
  | Ok None -> decode_attachment_ref body
  | Error _ as err -> err

let encode_attachment_ref (a : t) =
  let opt_field k f = function None -> [] | Some v -> [ (k, f v) ] in
  `Assoc
    ([
       ("attachment_id", `String a.attachment_id);
       ("id", `String a.id);
       ("url", `String a.url);
       ("mime_type", `String a.mime_type);
       ("kind", `String (kind_to_string a.kind));
       ("bytes", `Int a.bytes);
     ]
    @ opt_field "width" (fun n -> `Int n) a.width
    @ opt_field "height" (fun n -> `Int n) a.height
    @ opt_field "filename" (fun s -> `String s) a.filename)

let encode_user_block (a : t) =
  `Assoc
    [
      ("type", `String "attachment");
      ("attachment_id", `String a.attachment_id);
    ]

let format_bytes_short n =
  if n <= 0 then ""
  else if n < 1024 then Printf.sprintf "%dB" n
  else if n < 1024 * 1024 then Printf.sprintf "%dKB" ((n + 511) / 1024)
  else Printf.sprintf "%.1fMB" (float_of_int n /. (1024.0 *. 1024.0))

let format_chip (a : t) =
  let prefix =
    match a.kind with
    | Kind_image -> "img"
    | Kind_audio -> "audio"
    | Kind_video -> "video"
    | Kind_document ->
        if String.equal (String.lowercase_ascii a.mime_type) "application/pdf"
        then "pdf"
        else "file"
  in
  let name =
    match a.filename with
    | Some f when not (String.equal (String.trim f) "") -> Filename.basename f
    | Some _ | None ->
        let short =
          if String.length a.attachment_id > 12 then
            String.sub a.attachment_id 0 12
          else a.attachment_id
        in
        short ^ extension_of_mime a.mime_type
  in
  let detail =
    match a.width, a.height with
    | Some w, Some h when w > 0 && h > 0 -> Printf.sprintf " %dx%d" w h
    | _ ->
        let sz = format_bytes_short a.bytes in
        if String.equal sz "" then "" else " " ^ sz
  in
  Printf.sprintf "[%s: %s%s]" prefix name detail
