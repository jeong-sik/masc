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

(* [media_type] (an IANA type from the OAS media block) -> file extension. Unknown
   types fall back to [bin]; the content-type served is re-derived from the ext so
   the two stay consistent. *)
let ext_of_media_type media_type =
  match String.lowercase_ascii (String.trim media_type) with
  | "image/png" -> "png"
  | "image/jpeg" | "image/jpg" -> "jpg"
  | "image/gif" -> "gif"
  | "image/webp" -> "webp"
  | "audio/mpeg" | "audio/mp3" -> "mp3"
  | "audio/wav" | "audio/x-wav" -> "wav"
  | "audio/ogg" -> "ogg"
  | "application/pdf" -> "pdf"
  | _ -> "bin"

let content_type_of_ext = function
  | "png" -> "image/png"
  | "jpg" -> "image/jpeg"
  | "gif" -> "image/gif"
  | "webp" -> "image/webp"
  | "mp3" -> "audio/mpeg"
  | "wav" -> "audio/wav"
  | "ogg" -> "audio/ogg"
  | "pdf" -> "application/pdf"
  | _ -> "application/octet-stream"

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
