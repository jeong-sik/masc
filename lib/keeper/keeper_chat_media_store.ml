(** Keeper_chat_media_store — content-addressed workspace media store.

    Files live under [<masc_dir>/media/] as [<sha256>.<ext>], where [<sha256>]
    is the lowercase hex SHA-256 of the raw payload bytes and [<ext>] is derived
    from the magic-byte-verified closed {!media_mime} variant. Served by
    [GET /api/v1/media/<sha256>] behind read auth and uploaded via
    [POST /api/v1/media] behind write auth.

    Writes never perform wall-clock deletion: workspace media referenced by Wiki
    pages, Published Artifacts, Board posts, and Chat transcripts stays durable
    until reclaimed by reference-aware media GC. *)

let media_subdir = "media"

type raster_mime =
  | Image_png
  | Image_jpeg
  | Image_gif
  | Image_webp

type media_mime =
  | Raster of raster_mime
  | Audio_mpeg
  | Audio_wav
  | Audio_ogg
  | Audio_midi
  | Application_pdf

type media_category =
  | Image
  | Audio
  | Midi
  | Document

type dimensions =
  { width : int
  ; height : int
  }

type stored_media =
  { sha256 : string
  ; path : string
  ; mime : raster_mime
  ; bytes : int
  ; dimensions : dimensions option
  }

type upload_error =
  | Upload_empty
  | Upload_too_large of
      { size_bytes : int
      ; max_bytes : int
      }
  | Upload_svg_not_allowed
  | Upload_unsupported_media_type of
      { declared : string option
      ; sniffed : raster_mime option
      }
  | Upload_mime_mismatch of
      { declared : raster_mime
      ; sniffed : raster_mime
      }
  | Upload_write_failed of string

type persist_error =
  | Unsupported_source_type of Agent_core.Types.media_source_kind
  | Invalid_base64 of string
  | Media_too_large of
      { size_bytes : int
      ; max_bytes : int
      }
  | Svg_not_allowed
  | Unsupported_media_type of
      { declared : string
      ; sniffed : media_mime option
      }
  | Mime_mismatch of
      { declared : media_mime
      ; sniffed : media_mime
      }
  | Write_failed of string

let all_raster_mimes =
  [ Image_png; Image_jpeg; Image_gif; Image_webp ]
;;

let all_media_mimes =
  List.map (fun r -> Raster r) all_raster_mimes
  @ [ Audio_mpeg; Audio_wav; Audio_ogg; Audio_midi; Application_pdf ]
;;

let raster_mime_to_string = function
  | Image_png -> "image/png"
  | Image_jpeg -> "image/jpeg"
  | Image_gif -> "image/gif"
  | Image_webp -> "image/webp"
;;

let media_mime_to_string = function
  | Raster r -> raster_mime_to_string r
  | Audio_mpeg -> "audio/mpeg"
  | Audio_wav -> "audio/wav"
  | Audio_ogg -> "audio/ogg"
  | Audio_midi -> "audio/midi"
  | Application_pdf -> "application/pdf"
;;

let ext_of_raster_mime = function
  | Image_png -> "png"
  | Image_jpeg -> "jpg"
  | Image_gif -> "gif"
  | Image_webp -> "webp"
;;

let ext_of_media_mime = function
  | Raster r -> ext_of_raster_mime r
  | Audio_mpeg -> "mp3"
  | Audio_wav -> "wav"
  | Audio_ogg -> "ogg"
  | Audio_midi -> "mid"
  | Application_pdf -> "pdf"
;;

let category_of_media_mime = function
  | Raster _ -> Image
  | Audio_mpeg | Audio_wav | Audio_ogg -> Audio
  | Audio_midi -> Midi
  | Application_pdf -> Document
;;

let mime_essence raw =
  let base =
    match String.index_opt raw ';' with
    | Some idx -> String.sub raw 0 idx
    | None -> raw
  in
  String.lowercase_ascii (String.trim base)
;;

let is_svg_content_type raw =
  String.equal (mime_essence raw) "image/svg+xml"
;;

let raster_mime_of_string raw =
  match mime_essence raw with
  | "image/png" -> Some Image_png
  | "image/jpeg" | "image/jpg" -> Some Image_jpeg
  | "image/gif" -> Some Image_gif
  | "image/webp" -> Some Image_webp
  | _ -> None
;;

let media_mime_of_string raw =
  match raster_mime_of_string raw with
  | Some raster -> Some (Raster raster)
  | None ->
    (match mime_essence raw with
     | "audio/mpeg" | "audio/mp3" -> Some Audio_mpeg
     | "audio/wav" | "audio/x-wav" | "audio/wave" -> Some Audio_wav
     | "audio/ogg" | "application/ogg" -> Some Audio_ogg
     | "audio/midi" | "audio/x-midi" | "audio/mid" -> Some Audio_midi
     | "application/pdf" -> Some Application_pdf
     | _ -> None)
;;

let media_mime_of_ext ext =
  match String.lowercase_ascii (String.trim ext) with
  | "png" -> Some (Raster Image_png)
  | "jpg" -> Some (Raster Image_jpeg)
  | "gif" -> Some (Raster Image_gif)
  | "webp" -> Some (Raster Image_webp)
  | "mp3" -> Some Audio_mpeg
  | "wav" -> Some Audio_wav
  | "ogg" -> Some Audio_ogg
  | "mid" -> Some Audio_midi
  | "pdf" -> Some Application_pdf
  | _ -> None
;;

let media_mime_of_path path =
  let ext = Filename.extension path in
  let ext =
    if String.length ext > 0 && Char.equal ext.[0] '.'
    then String.sub ext 1 (String.length ext - 1)
    else ext
  in
  media_mime_of_ext ext
;;

let category_of_media_type media_type =
  Option.map category_of_media_mime (media_mime_of_string media_type)
;;

(* ---- Magic-byte sniffing & XML/SVG rejection ---- *)

let has_prefix_at ~offset ~prefix s =
  let plen = String.length prefix in
  let slen = String.length s in
  if offset < 0 || offset + plen > slen
  then false
  else
    let rec loop i =
      if i = plen
      then true
      else if Char.equal s.[offset + i] prefix.[i]
      then loop (i + 1)
      else false
    in
    loop 0
;;

let has_ascii_ci_prefix_at ~offset ~prefix s =
  let plen = String.length prefix in
  let slen = String.length s in
  if offset < 0 || offset + plen > slen
  then false
  else
    let rec loop i =
      if i = plen
      then true
      else if Char.equal (Char.lowercase_ascii s.[offset + i]) prefix.[i]
      then loop (i + 1)
      else false
    in
    loop 0
;;

let is_ascii_ws = function
  | ' ' | '\t' | '\r' | '\n' | '\x0c' -> true
  | _ -> false
;;

let svg_inspection_window_bytes = 512

let looks_like_svg_or_xml data =
  let limit = min (String.length data) svg_inspection_window_bytes in
  let start =
    if limit >= 3 && has_prefix_at ~offset:0 ~prefix:"\xef\xbb\xbf" data
    then 3
    else 0
  in
  let rec skip_ws i =
    if i < limit && is_ascii_ws data.[i] then skip_ws (i + 1) else i
  in
  let rec find_comment_end i =
    if i + 2 >= limit
    then None
    else if
      Char.equal data.[i] '-'
      && Char.equal data.[i + 1] '-'
      && Char.equal data.[i + 2] '>'
    then Some (i + 3)
    else find_comment_end (i + 1)
  in
  let rec inspect i =
    let i = skip_ws i in
    if i >= limit
    then false
    else if has_ascii_ci_prefix_at ~offset:i ~prefix:"<?xml" data
    then true
    else if has_ascii_ci_prefix_at ~offset:i ~prefix:"<svg" data
    then
      let next = i + 4 in
      next >= limit
      || is_ascii_ws data.[next]
      || Char.equal data.[next] '>'
      || Char.equal data.[next] '/'
    else if has_ascii_ci_prefix_at ~offset:i ~prefix:"<!doctype" data
    then
      let rec has_svg_token j =
        if j + 3 > limit
        then false
        else if Char.equal data.[j] '>'
        then false
        else if has_ascii_ci_prefix_at ~offset:j ~prefix:"svg" data
        then true
        else has_svg_token (j + 1)
      in
      has_svg_token (i + 9)
    else if has_prefix_at ~offset:i ~prefix:"<!--" data
    then
      (match find_comment_end (i + 4) with
       | Some after -> inspect after
       | None -> false)
    else false
  in
  inspect start
;;

let png_magic = "\x89PNG\r\n\x1a\n"

let sniff_raster_mime data =
  let len = String.length data in
  if len >= 8 && has_prefix_at ~offset:0 ~prefix:png_magic data
  then Some Image_png
  else if
    len >= 3
    && Char.code data.[0] = 0xFF
    && Char.code data.[1] = 0xD8
    && Char.code data.[2] = 0xFF
  then Some Image_jpeg
  else if
    len >= 6
    && (has_prefix_at ~offset:0 ~prefix:"GIF87a" data
        || has_prefix_at ~offset:0 ~prefix:"GIF89a" data)
  then Some Image_gif
  else if
    len >= 12
    && has_prefix_at ~offset:0 ~prefix:"RIFF" data
    && has_prefix_at ~offset:8 ~prefix:"WEBP" data
  then Some Image_webp
  else None
;;

let is_mp3_frame_header data =
  let len = String.length data in
  if len < 3
  then false
  else
    let b0 = Char.code data.[0] in
    let b1 = Char.code data.[1] in
    let b2 = Char.code data.[2] in
    let sync = b0 = 0xFF && b1 land 0xE0 = 0xE0 in
    let version = (b1 lsr 3) land 0x03 in
    let layer = (b1 lsr 1) land 0x03 in
    let bitrate_idx = (b2 lsr 4) land 0x0F in
    let sample_rate_idx = (b2 lsr 2) land 0x03 in
    sync && version <> 0x01 && layer <> 0x00 && bitrate_idx <> 0x0F && sample_rate_idx <> 0x03
;;

let sniff_media_mime data =
  match sniff_raster_mime data with
  | Some raster -> Some (Raster raster)
  | None ->
    let len = String.length data in
    if
      len >= 12
      && has_prefix_at ~offset:0 ~prefix:"RIFF" data
      && has_prefix_at ~offset:8 ~prefix:"WAVE" data
    then Some Audio_wav
    else if len >= 4 && has_prefix_at ~offset:0 ~prefix:"OggS" data
    then Some Audio_ogg
    else if len >= 4 && has_prefix_at ~offset:0 ~prefix:"MThd" data
    then Some Audio_midi
    else if len >= 5 && has_prefix_at ~offset:0 ~prefix:"%PDF-" data
    then Some Application_pdf
    else if (len >= 3 && has_prefix_at ~offset:0 ~prefix:"ID3" data) || is_mp3_frame_header data
    then Some Audio_mpeg
    else None
;;

(* ---- Pure OCaml raster dimension header parsers ---- *)

let positive_dimensions ~width ~height =
  if width > 0 && height > 0 then Some { width; height } else None
;;

let read_be_u16 s off =
  (Char.code s.[off] lsl 8) lor Char.code s.[off + 1]
;;

let read_le_u16 s off =
  Char.code s.[off] lor (Char.code s.[off + 1] lsl 8)
;;

let read_le_u24 s off =
  Char.code s.[off]
  lor (Char.code s.[off + 1] lsl 8)
  lor (Char.code s.[off + 2] lsl 16)
;;

let read_be_u31_opt s off =
  let b0 = Char.code s.[off] in
  if b0 >= 128
  then None
  else
    Some
      ((b0 lsl 24)
       lor (Char.code s.[off + 1] lsl 16)
       lor (Char.code s.[off + 2] lsl 8)
       lor Char.code s.[off + 3])
;;

let parse_png_dimensions data =
  if
    String.length data < 24
    || not (has_prefix_at ~offset:0 ~prefix:png_magic data)
    || not (has_prefix_at ~offset:12 ~prefix:"IHDR" data)
  then None
  else
    match read_be_u31_opt data 8, read_be_u31_opt data 16, read_be_u31_opt data 20 with
    | Some 13, Some width, Some height -> positive_dimensions ~width ~height
    | _ -> None
;;

let parse_gif_dimensions data =
  if
    String.length data < 10
    || not
         (has_prefix_at ~offset:0 ~prefix:"GIF87a" data
          || has_prefix_at ~offset:0 ~prefix:"GIF89a" data)
  then None
  else
    let width = read_le_u16 data 6 in
    let height = read_le_u16 data 8 in
    positive_dimensions ~width ~height
;;

let is_jpeg_sof_marker = function
  | 0xC0 | 0xC1 | 0xC2 | 0xC3 | 0xC5 | 0xC6 | 0xC7
  | 0xC9 | 0xCA | 0xCB | 0xCD | 0xCE | 0xCF -> true
  | _ -> false
;;

let parse_jpeg_dimensions data =
  let len = String.length data in
  if len < 4 || Char.code data.[0] <> 0xFF || Char.code data.[1] <> 0xD8
  then None
  else
    let rec skip_ff i =
      if i < len && Char.code data.[i] = 0xFF then skip_ff (i + 1) else i
    in
    let rec loop pos =
      if pos + 1 >= len || Char.code data.[pos] <> 0xFF
      then None
      else
        let marker_pos = skip_ff (pos + 1) in
        if marker_pos >= len
        then None
        else
          let marker = Char.code data.[marker_pos] in
          let body_pos = marker_pos + 1 in
          match marker with
          | 0x00 | 0xD9 | 0xDA -> None
          | 0x01 | 0xD0 | 0xD1 | 0xD2 | 0xD3 | 0xD4 | 0xD5 | 0xD6 | 0xD7 | 0xD8 ->
            loop body_pos
          | _ ->
            if body_pos + 2 > len
            then None
            else
              let seg_len = read_be_u16 data body_pos in
              if seg_len < 2 || body_pos + seg_len > len
              then None
              else if is_jpeg_sof_marker marker
              then
                if seg_len < 7 || body_pos + 7 > len
                then None
                else
                  let height = read_be_u16 data (body_pos + 3) in
                  let width = read_be_u16 data (body_pos + 5) in
                  positive_dimensions ~width ~height
              else loop (body_pos + seg_len)
    in
    loop 2
;;

let parse_webp_dimensions data =
  let len = String.length data in
  if
    len < 20
    || not (has_prefix_at ~offset:0 ~prefix:"RIFF" data)
    || not (has_prefix_at ~offset:8 ~prefix:"WEBP" data)
  then None
  else if has_prefix_at ~offset:12 ~prefix:"VP8 " data
  then
    if
      len < 30
      || Char.code data.[20] land 0x01 <> 0
      || Char.code data.[23] <> 0x9D
      || Char.code data.[24] <> 0x01
      || Char.code data.[25] <> 0x2A
    then None
    else
      let width = read_le_u16 data 26 land 0x3FFF in
      let height = read_le_u16 data 28 land 0x3FFF in
      positive_dimensions ~width ~height
  else if has_prefix_at ~offset:12 ~prefix:"VP8L" data
  then
    if len < 25 || Char.code data.[20] <> 0x2F
    then None
    else
      let b0 = Char.code data.[21] in
      let b1 = Char.code data.[22] in
      let b2 = Char.code data.[23] in
      let b3 = Char.code data.[24] in
      let width = 1 + (b0 lor ((b1 land 0x3F) lsl 8)) in
      let height = 1 + ((b1 lsr 6) lor (b2 lsl 2) lor ((b3 land 0x0F) lsl 10)) in
      positive_dimensions ~width ~height
  else if has_prefix_at ~offset:12 ~prefix:"VP8X" data
  then
    if len < 30
    then None
    else
      let width = 1 + read_le_u24 data 24 in
      let height = 1 + read_le_u24 data 27 in
      positive_dimensions ~width ~height
  else None
;;

let parse_raster_dimensions mime data =
  match mime with
  | Image_png -> parse_png_dimensions data
  | Image_jpeg -> parse_jpeg_dimensions data
  | Image_gif -> parse_gif_dimensions data
  | Image_webp -> parse_webp_dimensions data
;;

(* ---- Content addressing & durable atomic storage ---- *)

let media_dir ~base_dir =
  Filename.concat (Common.masc_dir_from_base_path ~base_path:base_dir) media_subdir
;;

let sha256_of_bytes data =
  Agent_core_sha256.(digest_string data |> to_hex)
;;

let media_url token = Masc_network_defaults.media_path token

let token_re = Re.compile (Re.Pcre.re "^[a-f0-9]{64}$")

let valid_token token = Re.execp token_re token

let max_raw_bytes () = Env_config_keeper.KeeperGeneratedMedia.max_bytes ()

let max_wire_bytes () =
  let raw_cap = max_raw_bytes () in
  ((raw_cap + 2) / 3 * 4) + 4096
;;

let validate_raw_size data =
  let size_bytes = String.length data in
  let max_bytes = max_raw_bytes () in
  if size_bytes > max_bytes then Error (size_bytes, max_bytes) else Ok ()
;;

let regular_file_exists path =
  try (Unix.lstat path).st_kind = Unix.S_REG with
  | Sys_error _ | Unix.Unix_error _ -> false
;;

let resolve_token ~base_dir ~token =
  if not (valid_token token)
  then None
  else
    let dir = media_dir ~base_dir in
    List.find_map
      (fun mime ->
         let path = Filename.concat dir (token ^ "." ^ ext_of_media_mime mime) in
         if regular_file_exists path then Some (path, mime) else None)
      all_media_mimes
;;

let file_path_of_token ~base_dir ~token =
  Option.map fst (resolve_token ~base_dir ~token)
;;

let write_verified_media ~base_dir ~mime ~data =
  let sha256 = sha256_of_bytes data in
  let ext = ext_of_media_mime mime in
  let dir = media_dir ~base_dir in
  let file_path = Filename.concat dir (sha256 ^ "." ^ ext) in
  let url = media_url sha256 in
  try
    Fs_compat.mkdir_p dir;
    if regular_file_exists file_path
    then Ok (sha256, url)
    else
      (match Fs_compat.save_file_atomic file_path data with
       | Ok () -> Ok (sha256, url)
       | Error msg -> Error msg)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printf.sprintf "persist workspace media: %s" (Printexc.to_string exn))
;;

let persist_raster_upload ~base_dir ~content_type ~data =
  let size_bytes = String.length data in
  if size_bytes = 0
  then Error Upload_empty
  else
    match validate_raw_size data with
    | Error (size_bytes, max_bytes) ->
      Error (Upload_too_large { size_bytes; max_bytes })
    | Ok () ->
      if Option.exists is_svg_content_type content_type || looks_like_svg_or_xml data
      then Error Upload_svg_not_allowed
      else (
        let sniffed = sniff_raster_mime data in
        match content_type with
        | None -> Error (Upload_unsupported_media_type { declared = None; sniffed })
        | Some raw_ct ->
          (match raster_mime_of_string raw_ct with
           | None ->
             Error
               (Upload_unsupported_media_type
                  { declared = Some (mime_essence raw_ct); sniffed })
           | Some declared ->
             (match sniffed with
              | None ->
                Error
                  (Upload_unsupported_media_type
                     { declared = Some (raster_mime_to_string declared)
                     ; sniffed = None
                     })
              | Some actual when actual <> declared ->
                Error (Upload_mime_mismatch { declared; sniffed = actual })
              | Some actual ->
                (match write_verified_media ~base_dir ~mime:(Raster actual) ~data with
                 | Error msg -> Error (Upload_write_failed msg)
                 | Ok (sha256, path) ->
                   Ok
                     { sha256
                     ; path
                     ; mime = actual
                     ; bytes = size_bytes
                     ; dimensions = parse_raster_dimensions actual data
                     }))))
;;

let upload_error_to_string = function
  | Upload_empty -> "empty upload"
  | Upload_too_large { size_bytes; max_bytes } ->
    Printf.sprintf "media too large: size_bytes=%d max_bytes=%d" size_bytes max_bytes
  | Upload_svg_not_allowed ->
    "SVG uploads are not allowed; use raster images (PNG, JPEG, GIF, WebP)"
  | Upload_unsupported_media_type { declared; sniffed } ->
    Printf.sprintf
      "unsupported media type (declared=%s, detected=%s)"
      (Option.value declared ~default:"none")
      (match sniffed with
       | Some m -> raster_mime_to_string m
       | None -> "unknown")
  | Upload_mime_mismatch { declared; sniffed } ->
    Printf.sprintf
      "declared Content-Type %s does not match payload magic bytes %s"
      (raster_mime_to_string declared)
      (raster_mime_to_string sniffed)
  | Upload_write_failed msg -> "failed to persist workspace media: " ^ msg
;;

let verify_media_payload ~media_type ~data =
  if is_svg_content_type media_type || looks_like_svg_or_xml data
  then Error Svg_not_allowed
  else
    let sniffed = sniff_media_mime data in
    match media_mime_of_string media_type with
    | None ->
      Error (Unsupported_media_type { declared = mime_essence media_type; sniffed })
    | Some declared ->
      (match sniffed with
       | None ->
         Error
           (Unsupported_media_type
              { declared = media_mime_to_string declared; sniffed = None })
       | Some actual when actual <> declared ->
         Error (Mime_mismatch { declared; sniffed = actual })
       | Some actual -> Ok actual)
;;

let persist_error_to_string = function
  | Unsupported_source_type source_type ->
    Printf.sprintf
      "unsupported media source_type: %s"
      (Llm_provider.Types.media_source_kind_to_string source_type)
  | Invalid_base64 msg -> "invalid base64 media payload: " ^ msg
  | Media_too_large { size_bytes; max_bytes } ->
    Printf.sprintf
      "generated media too large: size_bytes=%d max_bytes=%d"
      size_bytes
      max_bytes
  | Svg_not_allowed -> "SVG media is not allowed in workspace media store"
  | Unsupported_media_type { declared; sniffed } ->
    Printf.sprintf
      "unsupported media type: declared=%s detected=%s"
      declared
      (match sniffed with
       | Some m -> media_mime_to_string m
       | None -> "unknown")
  | Mime_mismatch { declared; sniffed } ->
    Printf.sprintf
      "media type mismatch: declared=%s detected=%s"
      (media_mime_to_string declared)
      (media_mime_to_string sniffed)
  | Write_failed msg -> "failed to persist generated media: " ^ msg
;;

let persist_typed ~base_dir ~media_type ~data =
  match validate_raw_size data with
  | Error (size_bytes, max_bytes) ->
    Error (Media_too_large { size_bytes; max_bytes })
  | Ok () ->
    (match verify_media_payload ~media_type ~data with
     | Error err -> Error err
     | Ok mime ->
       (match write_verified_media ~base_dir ~mime ~data with
        | Ok persisted -> Ok persisted
        | Error msg -> Error (Write_failed msg)))
;;

let persist_result ~base_dir ~media_type ~data =
  match persist_typed ~base_dir ~media_type ~data with
  | Ok persisted -> Ok persisted
  | Error err -> Error (persist_error_to_string err)
;;

let raw_data_of_source = function
  | Llm_provider.Types.Base64 data ->
    (match Base64.decode data with
     | Ok raw -> Ok raw
     | Error (`Msg msg) -> Error (Invalid_base64 msg))
  | (Llm_provider.Types.Url _ | Llm_provider.Types.File_id _) as source ->
    Error
      (Unsupported_source_type
         (Llm_provider.Types.media_source_kind_of_source source))
;;

let persist_media_source_result ~base_dir ~media_type ~source =
  match raw_data_of_source source with
  | Error err -> Error err
  | Ok raw -> persist_typed ~base_dir ~media_type ~data:raw
;;
