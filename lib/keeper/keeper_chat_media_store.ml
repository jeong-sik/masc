(** Keeper_chat_media_store — content-addressed store for model-generated media.

    RFC-0301: model-generated media (image / audio / document) streamed by OAS as
    [MediaDelta { media_type; data }] is persisted here and surfaced in keeper chat
    by URL token, instead of being reduced to a byte count at the bridge. This
    generalizes the voice-clip token/serve pattern (RFC-0235:
    [/api/v1/voice/audio/<token>]) to an arbitrary [media_type].

    Files live under [<masc_dir>/media/] as [<token>.<ext>], where [token] is a
    deterministic SHA-256 hex locator derived from the media type and raw payload.
    Served by [GET /api/v1/media/<token>] behind normal read auth. Retention is
    enforced opportunistically on persist via [KeeperGeneratedMedia] age and
    directory-size caps; the voice-clip TTL sweep only owns [<masc_dir>/audio]. *)

let media_subdir = "media"

type persist_error =
  | Unsupported_source_type of Agent_sdk.Types.media_source_kind
  | Invalid_base64 of string
  | Media_too_large of { size_bytes : int; max_bytes : int }
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

(* Token = lowercase SHA-256 hex (64 chars). This is only an authenticated locator,
   not a bearer capability: the media route is read-auth gated. Include the
   normalized media type in the digest material so identical bytes mislabeled as
   different media types cannot create multiple files for one token. *)
let token_of_payload ~media_type data =
  Digestif.SHA256.(digest_string (normalize media_type ^ "\000" ^ data) |> to_hex)

let media_url token = Printf.sprintf "/api/v1/media/%s" token

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

let cleanup_old_files_in_dir dir =
  if Sys.file_exists dir && Sys.is_directory dir
  then
    try
      let cutoff =
        Time_compat.now ()
        -. Env_config_keeper.KeeperGeneratedMedia.retention_seconds ()
      in
      let entries =
        Sys.readdir dir
        |> Array.to_list
        |> List.filter_map (fun entry ->
          let path = Filename.concat dir entry in
          try
            let stat = Unix.stat path in
            if stat.st_kind = Unix.S_REG
            then Some (path, stat.st_mtime, stat.st_size)
            else None
          with
          | Unix.Unix_error _ | Sys_error _ -> None)
      in
      let by_age =
        List.sort (fun (_, left_mtime, _) (_, right_mtime, _) ->
          Float.compare left_mtime right_mtime)
          entries
      in
      let remove path =
        try Sys.remove path with
        | Unix.Unix_error _ | Sys_error _ -> ()
      in
      let remaining =
        List.filter
          (fun (path, mtime, _size) ->
            if mtime < cutoff
            then (
              remove path;
              false)
            else true)
          by_age
      in
      let dir_max_bytes = Env_config_keeper.KeeperGeneratedMedia.dir_max_bytes () in
      let total_size =
        List.fold_left (fun acc (_, _, size) -> acc + size) 0 remaining
      in
      if total_size > dir_max_bytes
      then
        ignore
          (List.fold_left
             (fun acc (path, _mtime, size) ->
               if acc <= dir_max_bytes
               then acc
               else (
                 remove path;
                 acc - size))
             total_size
             remaining)
    with
    | Sys_error _ | Unix.Unix_error _ -> ()

(* Resolve a token to its on-disk path by locating [<token>.<ext>] — the ext is
   not carried by the token, so the directory is scanned for the single file whose
   basename (sans ext) equals the token. Returns [None] if absent or reaped. *)
let file_path_of_token ~base_dir ~token =
  if not (valid_token token)
  then None
  else
    try
    let dir = media_dir ~base_dir in
    match Sys.file_exists dir && Sys.is_directory dir with
    | false -> None
    | true ->
        let rank name =
          match normalize (Filename.extension name) with
          | ".bin" -> 1
          | _ -> 0
        in
      Sys.readdir dir
      |> Array.to_list
      |> List.filter (fun name -> Filename.remove_extension name = token)
        |> List.sort (fun left right ->
          match compare (rank left) (rank right) with
          | 0 -> String.compare left right
          | by_rank -> by_rank)
      |> (function
       | [] -> None
           | name :: _ -> Some (Filename.concat dir name))
    with
    | Sys_error _ | Unix.Unix_error _ -> None

let content_type_of_path path =
  let ext = Filename.extension path in
  let ext =
    if String.length ext > 0 && Char.equal ext.[0] '.'
    then String.sub ext 1 (String.length ext - 1)
    else ext
  in
  content_type_of_ext (String.lowercase_ascii ext)

let persist_result ~base_dir ~media_type ~data =
  match validate_raw_size data with
  | Error (size_bytes, max_bytes) ->
      Error
        (Printf.sprintf "generated media too large: size_bytes=%d max_bytes=%d"
           size_bytes
           max_bytes)
  | Ok () ->
      let token = token_of_payload ~media_type data in
      let ext = ext_of_media_type media_type in
      let dir = media_dir ~base_dir in
      let url = media_url token in
      try
        Fs_compat.mkdir_p dir;
        cleanup_old_files_in_dir dir;
        match file_path_of_token ~base_dir ~token with
        | Some _ -> Ok (token, url)
        | None ->
            let path = Filename.concat dir (token ^ "." ^ ext) in
            (match Fs_compat.save_file_atomic path data with
             | Ok () -> Ok (token, url)
             | Error msg -> Error msg)
      with
      | exn ->
          Error
            (Printf.sprintf "persist generated media: %s" (Printexc.to_string exn))

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
  | Media_too_large { size_bytes; max_bytes } ->
      Printf.sprintf "generated media too large: size_bytes=%d max_bytes=%d"
        size_bytes
        max_bytes
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
      (match validate_raw_size raw with
       | Error (size_bytes, max_bytes) ->
           Error (Media_too_large { size_bytes; max_bytes })
       | Ok () -> (
           match persist_result ~base_dir ~media_type ~data:raw with
           | Ok persisted -> Ok persisted
           | Error msg -> Error (Write_failed msg)))
