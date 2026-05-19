(** Tool_code_read_core — SSOT pipeline for [masc_code_read].

    See [tool_code_read_core.mli] for the rationale.

    The binary-extension list and the max-file-size constant live here
    (and are re-exported by [Tool_code] for wire compatibility) so
    this module has no upward dependency on [Tool_code] and can be
    composed freely. *)

(* SSOT binary-extension block list — drift = silent regression in
   the binary block. [Tool_code.is_binary_file] now delegates here. *)
let binary_extensions =
  [ ".so"; ".a"; ".lib"; ".dll"; ".dylib"
  ; ".wasm"; ".o"; ".obj"
  ; ".jpg"; ".jpeg"; ".png"; ".gif"; ".bmp"; ".ico"; ".webp"
  ; ".mp3"; ".mp4"; ".avi"; ".mov"; ".wav"; ".flac"
  ; ".zip"; ".tar"; ".gz"; ".bz2"; ".xz"; ".7z"
  ; ".pdf"; ".doc"; ".docx"; ".xls"; ".xlsx"; ".ppt"; ".pptx"
  ]

let is_binary_file path =
  List.exists
    (fun ext ->
      let plen = String.length path in
      let elen = String.length ext in
      plen >= elen
      && String.equal (String.sub path (plen - elen) elen) ext)
    binary_extensions

let max_file_size = 500 * 1024

type read_error =
  | Path_is_directory of { path : string }
  | File_not_found of { path : string }
  | Binary_file of { path : string }
  | Too_large of { path : string; size : int; max : int }
  | Io_error of { path : string; detail : string }
  | Internal_error of { path : string; detail : string }

type ok =
  { display_path : string
  ; total_lines : int
  ; safe_offset : int
  ; safe_limit : int
  ; lines : string list
  }

let slice_lines ~lines ~total_lines ~offset ~limit =
  let safe_offset = max 0 (min offset total_lines) in
  let safe_limit = min limit (total_lines - safe_offset) in
  let safe_limit = max 0 safe_limit in
  let selected = ref [] in
  for i = safe_offset to safe_offset + safe_limit - 1 do
    match List.nth_opt lines i with
    | Some line -> selected := line :: !selected
    | None -> ()
  done;
  (safe_offset, safe_limit, List.rev !selected)

let read_with_pagination ~display_path ~validated_path ~offset ~limit :
    (ok, read_error) result =
  try
    if not (Sys.file_exists validated_path) then
      Error (File_not_found { path = display_path })
    else if Sys.is_directory validated_path then
      Error (Path_is_directory { path = display_path })
    else if is_binary_file validated_path then
      Error (Binary_file { path = display_path })
    else
      let max = max_file_size in
      let size = (Unix.stat validated_path).Unix.st_size in
      if size > max then
        Error (Too_large { path = display_path; size; max })
      else
        let content =
          In_channel.with_open_text validated_path In_channel.input_all
        in
        let lines = String.split_on_char '\n' content in
        let total_lines = List.length lines in
        let safe_offset, safe_limit, sliced =
          slice_lines ~lines ~total_lines ~offset ~limit
        in
        Ok
          { display_path
          ; total_lines
          ; safe_offset
          ; safe_limit
          ; lines = sliced
          }
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Sys_error detail ->
    Error (Io_error { path = display_path; detail })
  | Unix.Unix_error (err, fn, arg) ->
    let detail =
      Printf.sprintf "%s: %s(%s)" (Unix.error_message err) fn arg
    in
    Error (Io_error { path = display_path; detail })
  | exn ->
    Error
      (Internal_error
         { path = display_path; detail = Printexc.to_string exn })

let error_kind = function
  | Path_is_directory _ -> "path_is_directory"
  | File_not_found _ -> "file_not_found"
  | Binary_file _ -> "binary_file"
  | Too_large _ -> "file_too_large"
  | Io_error _ -> "io_error"
  | Internal_error _ -> "internal_error"

let error_message = function
  | Path_is_directory { path } ->
    Printf.sprintf "Path is a directory, not a file: %s" path
  | File_not_found { path } -> Printf.sprintf "File not found: %s" path
  | Binary_file { path } ->
    Printf.sprintf "Binary file detected: %s" path
  | Too_large { path; size; max } ->
    Printf.sprintf "File too large: %s (%d bytes, max %d)" path size max
  | Io_error { path; detail } ->
    Printf.sprintf "Failed to read file %s: %s" path detail
  | Internal_error { path; detail } ->
    Printf.sprintf "Internal error reading file %s: %s" path detail

let error_hint = function
  | Path_is_directory _ ->
    Some
      "Use masc_code_search to find files inside the directory, or shell \
       'ls -la <path>' to list its contents."
  | Binary_file _ ->
    Some
      "Binary files are not readable through masc_code_read. Inspect via \
       a dedicated tool if needed."
  | Too_large _ ->
    Some
      "Use offset/limit pagination on a smaller window, or rg/grep for \
       the relevant section."
  | File_not_found _ | Io_error _ | Internal_error _ -> None

let path_of = function
  | Path_is_directory { path }
  | File_not_found { path }
  | Binary_file { path }
  | Too_large { path; _ }
  | Io_error { path; _ }
  | Internal_error { path; _ } -> path

let read_error_to_json e : Yojson.Safe.t =
  let base =
    [ "error", `String (error_message e)
    ; "error_kind", `String (error_kind e)
    ; "path", `String (path_of e)
    ]
  in
  let with_hint =
    match error_hint e with
    | None -> base
    | Some h -> base @ [ "hint", `String h ]
  in
  `Assoc with_hint

let ok_to_json ~display_path o : Yojson.Safe.t =
  `Assoc
    [ "path", `String display_path
    ; "offset", `Int o.safe_offset
    ; "limit", `Int o.safe_limit
    ; "total_lines", `Int o.total_lines
    ; "lines", `List (List.map (fun s -> `String s) o.lines)
    ]
