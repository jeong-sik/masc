(** Keeper_chat_media_store — content-addressed store for model-generated media.

    model-generated media (image / audio / document) streamed by AGENT_CORE as
    [MediaDelta { media_type; source }] is persisted here and surfaced in keeper chat
    by URL token, instead of being reduced to a byte count at the bridge. This
    generalizes the voice-clip token/serve pattern
    ([/api/v1/voice/audio/<token>]) to an arbitrary [media_type].

    Generated media is stored durably in {!Attachment_store} under
    [<masc_dir>/attachments/] and surfaced via canonical
    [/api/v1/attachments/att_<sha256>] URLs (with read compatibility on
    [/api/v1/media/<token>]). Non-allowlisted model-generated formats (e.g.
    FLAC, AAC, PCM, video) are preserved via {!Attachment_store.put_opaque} as
    downloadable evidence rather than dropped. Unreferenced blobs are reclaimed
    by {!Tool_blob_sweep.sweep_attachments} (wired into {!Tool_blob_sweep.reclaim});
    the voice-clip TTL sweep only owns [<masc_dir>/audio]. *)

let media_subdir = "media"

type persist_error =
  | Unsupported_source_type of Agent_core.Types.media_source_kind
  | Invalid_base64 of string
  | Media_too_large of { size_bytes : int; max_bytes : int }
  | Write_failed of string

(* Broad category of a media type, driving the keeper-chat block type used when the
   generated media is persisted for reload. Unknown types are
   [Other] and are stored/served opaquely rather than dropped. *)
type media_category =
  | Image
  | Audio
  | Midi
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
  ; { media_type = "audio/midi"; ext = "mid"; content_type = "audio/midi"; category = Midi }
  ; { media_type = "audio/x-midi"; ext = "mid"; content_type = "audio/midi"; category = Midi }
  ; { media_type = "audio/mp4"; ext = "m4a"; content_type = "audio/mp4"; category = Audio }
  ; { media_type = "audio/m4a"; ext = "m4a"; content_type = "audio/mp4"; category = Audio }
  ; { media_type = "audio/webm"; ext = "webm"; content_type = "audio/webm"; category = Audio }
  ; { media_type = "application/pdf"; ext = "pdf"; content_type = "application/pdf"; category = Document }
  ]

module String_set = Set.Make (String)

let known_storage_exts =
  let dedup_preserving_first entries =
    entries
    |> List.fold_left
         (fun (seen, acc) entry ->
            if String_set.mem entry seen then seen, acc
            else String_set.add entry seen, entry :: acc)
         (String_set.empty, [])
    |> snd
    |> List.rev
  in
  let exts =
    known_media |> List.map (fun media -> media.ext) |> dedup_preserving_first
  in
  if List.exists (String.equal "bin") exts then exts else exts @ [ "bin" ]

let normalize s = String.lowercase_ascii (String.trim s)

(* [media_type] (an IANA type from the AGENT_CORE media block) -> file extension. Unknown
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

let token_re = Re.compile (Re.Pcre.re "^[a-f0-9]{64}$")

let valid_token token =
  Re.execp token_re token

let max_raw_bytes () =
  Env_config_keeper.KeeperGeneratedMedia.max_bytes ()

let max_wire_bytes () =
  let raw_cap = max_raw_bytes () in
  ((raw_cap + 2) / 3 * 4) + 4096

let validate_raw_size data =
  let size_bytes = String.length data in
  let max_bytes = max_raw_bytes () in
  if size_bytes > max_bytes
  then Error (size_bytes, max_bytes)
  else Ok ()

let regular_file_exists path =
  try (Unix.stat path).st_kind = Unix.S_REG with
  | Sys_error _ | Unix.Unix_error _ -> false

(* Resolve a token to its on-disk path by probing the extensions this module can
   write. [bin] is last, so known content types win over the opaque fallback. *)
let file_path_of_token ~base_dir ~token =
  if not (valid_token token)
  then None
  else
    let dir = media_dir ~base_dir in
    List.find_map
      (fun ext ->
        let path = Filename.concat dir (token ^ "." ^ ext) in
        if regular_file_exists path then Some path else None)
      known_storage_exts

let content_type_of_path path =
  let ext = Filename.extension path in
  let ext =
    if String.length ext > 0 && Char.equal ext.[0] '.'
    then String.sub ext 1 (String.length ext - 1)
    else ext
  in
  content_type_of_ext (String.lowercase_ascii ext)

let put_attachment_meta ~base_dir ~media_type ~data =
  let store = Attachment_store.create ~base_path:base_dir in
  let declared_mime =
    let m = normalize media_type in
    if String.equal m "" then None else Some m
  in
  let put_with ?declared () =
    Attachment_store.put
      ~max_bytes:(max_raw_bytes ())
      ?declared_mime:declared
      ~origin:Attachment_store.Model_generated
      ~created_by:"keeper"
      ~retention:Attachment_store.Durable
      store
      ~bytes:data
  in
  match put_with ?declared:declared_mime () with
  | Ok meta -> Ok meta
  | Error (Attachment_store.Mime_mismatch _) ->
    (* If the provider mislabeled a supported image/audio/document (e.g. JPEG
       bytes labeled image/png), trust magic-byte sniffing instead of dropping
       the generated media. *)
    put_with ()
  | Error (Attachment_store.Unsupported_or_unknown_format _ | Attachment_store.Encrypted_document _) ->
    (* Preserve non-allowlisted model-generated media (e.g. FLAC, AAC, PCM,
       video, an encrypted document) opaquely so generated evidence is never
       dropped; HTTP serves opaque binaries strictly with
       [Content-Disposition: attachment]. *)
    Attachment_store.put_opaque
      ~max_bytes:(max_raw_bytes ())
      ?declared_mime
      ~origin:Attachment_store.Model_generated
      ~created_by:"keeper"
      ~retention:Attachment_store.Durable
      store
      ~bytes:data
  | Error
      (( Attachment_store.Empty_payload
       | Attachment_store.Payload_too_large _
       | Attachment_store.Forbidden_mime _
       | Attachment_store.Invalid_keeper_name _
       | Attachment_store.Store_io_failed _ ) as err) -> Error err

let persist_result ~base_dir ~media_type ~data =
  match validate_raw_size data with
  | Error (size_bytes, max_bytes) ->
      Error
        (Printf.sprintf "generated media too large: size_bytes=%d max_bytes=%d"
           size_bytes
           max_bytes)
  | Ok () ->
      (match put_attachment_meta ~base_dir ~media_type ~data with
       | Ok meta -> Ok (meta.sha256, Attachment_store.url_of_id meta.id)
       | Error err -> Error (Attachment_store.put_error_to_string err))

let persist_error_to_string = function
  | Unsupported_source_type source_type ->
      Printf.sprintf "unsupported media source_type: %s"
        (Llm_provider.Types.media_source_kind_to_string source_type)
  | Invalid_base64 msg ->
      "invalid base64 media payload: " ^ msg
  | Media_too_large { size_bytes; max_bytes } ->
      Printf.sprintf "generated media too large: size_bytes=%d max_bytes=%d"
        size_bytes
        max_bytes
  | Write_failed msg ->
      "failed to persist generated media: " ^ msg

let raw_data_of_source = function
  | Llm_provider.Types.Base64 data -> (
      match Base64.decode data with
      | Ok raw -> Ok raw
      | Error (`Msg msg) -> Error (Invalid_base64 msg))
  | (Llm_provider.Types.Url _ | Llm_provider.Types.File_id _) as source ->
      Error (Unsupported_source_type (Llm_provider.Types.media_source_kind_of_source source))

let persist_media_source_meta ~base_dir ~media_type ~source =
  match raw_data_of_source source with
  | Error err -> Error err
  | Ok raw ->
      (match validate_raw_size raw with
       | Error (size_bytes, max_bytes) ->
           Error (Media_too_large { size_bytes; max_bytes })
       | Ok () -> (
           match put_attachment_meta ~base_dir ~media_type ~data:raw with
           | Ok meta -> Ok meta
           | Error (Attachment_store.Payload_too_large { actual; maximum }) ->
               Error (Media_too_large { size_bytes = actual; max_bytes = maximum })
           | Error
               (( Attachment_store.Empty_payload
                | Attachment_store.Unsupported_or_unknown_format _
                | Attachment_store.Forbidden_mime _
                | Attachment_store.Mime_mismatch _
                | Attachment_store.Encrypted_document _
                | Attachment_store.Invalid_keeper_name _
                | Attachment_store.Store_io_failed _ ) as err) ->
               Error (Write_failed (Attachment_store.put_error_to_string err))))

let persist_media_source_result ~base_dir ~media_type ~source =
  Result.map
    (fun (meta : Attachment_store.meta) ->
       meta.sha256, Attachment_store.url_of_id meta.id)
    (persist_media_source_meta ~base_dir ~media_type ~source)
