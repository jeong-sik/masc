(** Keeper_chat_media_store — content-addressed store for model-generated media.

    RFC-0301: model-generated media (image / audio / document) streamed by OAS as
    [MediaDelta { media_type; data }] is persisted here and surfaced in keeper chat
    by URL token, instead of being reduced to a byte count at the bridge. This
    generalizes the voice-clip token/serve pattern (RFC-0235:
    [/api/v1/voice/audio/<token>]) to an arbitrary [media_type].

    Files live under [<masc_dir>/media/] as [<token>.<ext>], where [token] is the
    lowercase MD5 hex of the payload — so identical media dedup to a single file —
    and [ext] is derived from [media_type]. Served by [GET /api/v1/media/<token>]
    (public read), the same capability tier as the voice clip route. Retention
    follows the voice-clip policy: files are GC'd by the same directory sweep. *)

let media_subdir = "media"

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

(* Token = lowercase MD5 hex (32 chars), mirroring the voice clip 128-bit token so
   the shared [is_valid_token] shape and public-read route generalize cleanly. *)
let token_of_data data = Digest.to_hex (Digest.string data)

let valid_token token =
  Re.execp (Re.compile (Re.Pcre.re "^[a-f0-9]{32}$")) token

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
      |> List.find_opt (fun name -> Filename.remove_extension name = token)
      |> Option.map (fun name -> Filename.concat dir name))

let content_type_of_path path =
  let ext = Filename.extension path in
  let ext =
    if String.length ext > 0 && Char.equal ext.[0] '.'
    then String.sub ext 1 (String.length ext - 1)
    else ext
  in
  content_type_of_ext (String.lowercase_ascii ext)

(* Persist [data] under a content-addressed token and return
   [(token, relative_url)]. The write is idempotent: a re-persist of identical
   bytes reuses the existing file (content-addressed dedup). The URL is the
   reader-facing reference the bridge emits in place of the old byte count. *)
let persist ~base_dir ~media_type ~data =
  let token = token_of_data data in
  let ext = ext_of_media_type media_type in
  let dir = media_dir ~base_dir in
  (try if not (Sys.file_exists dir) then Unix.mkdir dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let path = Filename.concat dir (token ^ "." ^ ext) in
  if not (Sys.file_exists path) then Fs_compat.save_file path data;
  token, Printf.sprintf "/api/v1/media/%s" token
