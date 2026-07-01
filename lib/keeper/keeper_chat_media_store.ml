(** Keeper_chat_media_store — content-addressed store for model-generated media.

    RFC-0301: model-generated media (image / audio / document) streamed by OAS as
    [MediaDelta { media_type; data }] is persisted here and surfaced in keeper chat
    by URL token, instead of being reduced to a byte count at the bridge. This
    generalizes the voice-clip token/serve pattern (RFC-0235:
    [/api/v1/voice/audio/<token>]) to an arbitrary [media_type].

    Files live under [<masc_dir>/media/] as [<token>.<ext>], where [token] is a
    deterministic 32-char hex locator derived from the media type and raw payload.
    Served by [GET /api/v1/media/<token>] behind normal read auth. Retention
    follows the voice-clip policy: files are GC'd by the same directory sweep. *)

let media_subdir = "media"

type persist_error =
  | Unsupported_source_type of Agent_sdk.Types.media_source_kind
  | Invalid_base64 of string
  | Write_failed of string

(* Broad category of a media type, driving the keeper-chat block type used when the
   generated media is persisted for reload (RFC-0301 item 6). Unknown types are
   [Other] and are stored/served opaquely rather than dropped. *)
type media_category =
  | Image
  | Audio
  | Document
  | Other

(* Single source of truth for the media types the store names, serves, and
   classifies: [ext] is the on-disk extension, [content_type] the canonical IANA
   type served for that ext, and [category] the reload block type. Deriving
   [ext_of_media_type] / [content_type_of_ext] / [category_of_media_type] from one
   table avoids three parallel media-type match arms drifting apart. *)
type known_media = {
  media_type : string;
  ext : string;
  content_type : string;
  category : media_category;
}

let known_media =
  [ { media_type = "image/png"; ext = "png"; content_type = "image/png"; category = Image }
  ; { media_type = "image/jpeg"; ext = "jpg"; content_type = "image/jpeg"; category = Image }
  ; { media_type = "image/jpg"; ext = "jpg"; content_type = "image/jpeg"; category = Image }
  ; { media_type = "image/gif"; ext = "gif"; content_type = "image/gif"; category = Image }
  ; { media_type = "image/webp"; ext = "webp"; content_type = "image/webp"; category = Image }
  ; { media_type = "audio/mpeg"; ext = "mp3"; content_type = "audio/mpeg"; category = Audio }
  ; { media_type = "audio/mp3"; ext = "mp3"; content_type = "audio/mpeg"; category = Audio }
  ; { media_type = "audio/wav"; ext = "wav"; content_type = "audio/wav"; category = Audio }
  ; { media_type = "audio/x-wav"; ext = "wav"; content_type = "audio/wav"; category = Audio }
  ; { media_type = "audio/ogg"; ext = "ogg"; content_type = "audio/ogg"; category = Audio }
  ; { media_type = "application/pdf"; ext = "pdf"; content_type = "application/pdf"; category = Document }
  ]

let normalize s = String.lowercase_ascii (String.trim s)

(* [media_type] (an IANA type from the OAS media block) -> file extension. Unknown
   types fall back to [bin]; the content-type served is re-derived from the ext so
   the two stay consistent. *)
let ext_of_media_type media_type =
  let m = normalize media_type in
  match List.find_opt (fun k -> String.equal k.media_type m) known_media with
  | Some k -> k.ext
  | None -> "bin"

let category_of_media_type media_type =
  let m = normalize media_type in
  match List.find_opt (fun k -> String.equal k.media_type m) known_media with
  | Some k -> k.category
  | None -> Other

(* [ext] -> canonical content-type. The first table entry for an ext wins, so
   ["jpg"] canonicalizes to ["image/jpeg"] and ["mp3"] to ["audio/mpeg"]. *)
let content_type_of_ext ext =
  let e = normalize ext in
  match List.find_opt (fun k -> String.equal k.ext e) known_media with
  | Some k -> k.content_type
  | None -> "application/octet-stream"

let media_dir ~base_dir =
  Filename.concat (Common.masc_dir_from_base_path ~base_path:base_dir) media_subdir

(* Token = lowercase MD5 hex (32 chars). This is only an authenticated locator,
   not a bearer capability: the media route is read-auth gated. Include the
   normalized media type in the digest material so identical bytes mislabeled as
   different media types cannot create multiple files for one token. *)
let token_of_payload ~media_type data =
  Digest.to_hex (Digest.string (normalize media_type ^ "\000" ^ data))

let media_url token = Printf.sprintf "/api/v1/media/%s" token

let token_re = Re.compile (Re.Pcre.re "^[a-f0-9]{32}$")

let valid_token token =
  Re.execp token_re token

(* Resolve a token to its on-disk path by locating [<token>.<ext>] — the ext is
   not carried by the token, so the directory is scanned for the single file whose
   basename (sans ext) equals the token. Returns [None] if absent or reaped. *)
let file_path_of_token ~base_dir ~token =
  if not (valid_token token)
  then None
  else (
    let dir = media_dir ~base_dir in
    match Sys.file_exists dir && Sys.is_directory dir with
    | false -> None
    | true ->
      Sys.readdir dir
      |> Array.to_list
      |> List.filter (fun name -> Filename.remove_extension name = token)
      |> List.sort String.compare
      |> (function
       | [] -> None
       | name :: _ -> Some (Filename.concat dir name)))

let content_type_of_path path =
  let ext = Filename.extension path in
  let ext =
    if String.length ext > 0 && Char.equal ext.[0] '.'
    then String.sub ext 1 (String.length ext - 1)
    else ext
  in
  content_type_of_ext (String.lowercase_ascii ext)

let persist_result ~base_dir ~media_type ~data =
  let token = token_of_payload ~media_type data in
  let ext = ext_of_media_type media_type in
  let dir = media_dir ~base_dir in
  let url = media_url token in
  try
    Fs_compat.mkdir_p dir;
    match file_path_of_token ~base_dir ~token with
    | Some _ -> Ok (token, url)
    | None ->
        let path = Filename.concat dir (token ^ "." ^ ext) in
        (match Fs_compat.save_file_atomic path data with
         | Ok () -> Ok (token, url)
         | Error msg -> Error msg)
  with
  | exn -> Error (Printf.sprintf "persist generated media: %s" (Printexc.to_string exn))

let persist ~base_dir ~media_type ~data =
  match persist_result ~base_dir ~media_type ~data with
  | Ok persisted -> persisted
  | Error msg -> failwith msg

let persist_error_to_string = function
  | Unsupported_source_type source_type ->
      Printf.sprintf "unsupported media source_type: %s"
        (Agent_sdk.Types.media_source_kind_to_string source_type)
  | Invalid_base64 msg ->
      "invalid base64 media payload: " ^ msg
  | Write_failed msg ->
      "failed to persist generated media: " ^ msg

let raw_data_of_source ~source_type ~data =
  match source_type with
  | Agent_sdk.Types.Base64 -> (
      match Base64.decode data with
      | Ok raw -> Ok raw
      | Error (`Msg msg) -> Error (Invalid_base64 msg))
  | Agent_sdk.Types.Url | Agent_sdk.Types.File_id ->
      Error (Unsupported_source_type source_type)

let persist_media_source_result ~base_dir ~media_type ~source_type ~data =
  match raw_data_of_source ~source_type ~data with
  | Error err -> Error err
  | Ok raw ->
      (match persist_result ~base_dir ~media_type ~data:raw with
       | Ok persisted -> Ok persisted
       | Error msg -> Error (Write_failed msg))
