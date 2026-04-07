open Keeper_types
open Keeper_exec_shared

let handle_keeper_fs_read
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  ignore meta;
  let path = Safe_ops.json_string ~default:"" "path" args in
  let max_bytes =
    Safe_ops.json_int ~default:20000 "max_bytes" args |> fun n -> max 512 (min 200000 n)
  in
  match resolve_keeper_read_path ~config ~raw_path:path with
  | Error e -> error_json e
  | Ok target ->
    (match Safe_ops.read_file_safe target with
     | Error e when String.starts_with ~prefix:file_not_found_prefix e ->
       missing_file_error_json ~config ~target ~error:e
     | Error e -> error_json ~fields:[ "path", `String target ] e
     | Ok content ->
        let total = String.length content in
        let truncated = total > max_bytes in
        let body = if truncated then String.sub content 0 max_bytes else content in
        Yojson.Safe.to_string
          (`Assoc
             [ "ok", `Bool true
             ; "path", `String target
             ; "bytes", `Int total
             ; "truncated", `Bool truncated
             ; "content", `String body
             ]))
;;

let handle_keeper_fs_edit
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let path = Safe_ops.json_string ~default:"" "path" args in
  let content = Safe_ops.json_string ~default:"" "content" args in
  let mode =
    Safe_ops.json_string ~default:"overwrite" "mode" args |> String.lowercase_ascii
  in
  (* Early validation for 9B models that send empty/missing params *)
  if String.trim path = "" then
    error_json "path is required. Good: path='lib/foo.ml'. Bad: path=''."
  else if String.trim content = "" then
    error_json "content is required (non-empty). Writing 0 bytes is usually unintended."
  else if mode <> "overwrite" && mode <> "append" && mode <> "" then
    error_json (Printf.sprintf
      "mode must be 'overwrite' or 'append', got '%s'." mode)
  else
  match resolve_keeper_path ~config ~meta ~raw_path:path with
  | Error e -> error_json e
  | Ok target ->
    (try
       let parent = Filename.dirname target in
       Fs_compat.mkdir_p parent;
       (match mode with
        | "append" -> Fs_compat.append_file target content
        | "overwrite" | "" -> Fs_compat.save_file target content
        | other -> raise (Invalid_argument ("unsupported_mode:" ^ other)));
       Log.Keeper.info "WRITE_AUDIT: keeper=%s fs_edit path=%s mode=%s bytes=%d"
         meta.name target (if mode = "" then "overwrite" else mode)
         (String.length content);
       Yojson.Safe.to_string
         (`Assoc
             [ "ok", `Bool true
             ; "path", `String target
             ; "mode", `String (if mode = "" then "overwrite" else mode)
             ; "bytes_written", `Int (String.length content)
             ])
     with
     | Invalid_argument e -> error_json ~fields:[ "path", `String target ] e
     | Sys_error e -> error_json ~fields:[ "path", `String target ] e
     | Unix.Unix_error (err, _, _) ->
       error_json ~fields:[ "path", `String target ] (Unix.error_message err))
;;

