let ( let* ) = Result.bind

(* Binary transfers are buffered in memory before browser effects. This is a
   resource bound per file, not a Keeper runtime budget. One extra byte proves
   whether a file fits; no successful upload contains a truncated prefix. *)
let max_file_bytes = 16 * 1024 * 1024

let decode_hex output =
  let hex = String.to_seq output |> Seq.filter (function
    | ' ' | '\t' | '\r' | '\n' -> false | _ -> true) |> String.of_seq in
  let digit = function
    | '0' .. '9' as c -> Some (Char.code c - Char.code '0')
    | 'a' .. 'f' as c -> Some (Char.code c - Char.code 'a' + 10)
    | _ -> None in
  if String.length hex mod 2 <> 0 then Error "upload backend returned incomplete bytes"
  else
    let bytes = Bytes.create (String.length hex / 2) in
    let rec loop i =
      if i = Bytes.length bytes then Ok (Bytes.to_string bytes)
      else match digit hex.[2*i], digit hex.[2*i+1] with
        | Some a, Some b -> Bytes.set bytes i (Char.chr (a*16+b)); loop (i+1)
        | _ -> Error "upload backend returned invalid bytes" in
    loop 0

let backend_read ~turn_sandbox_factory ~config ~meta ~host_path ~max_bytes =
  let* backend_path = Keeper_sandbox_read_runner.container_path_of_host ~config ~meta ~host_path in
  (* Endpoint stdout rewrites visible paths, so raw binary `cat` is unsuitable.
     POSIX od's hex alphabet cannot contain a path. Keep each chunk's encoded
     output inside Process_eio's retained head; increasing run_command's limit
     cannot recover bytes that its subprocess capture has already elided.
     BSD od uses indentation and double spaces (more than four output bytes
     per input byte). Eight leaves room for both BSD and GNU layouts. *)
  let chunk_bytes = Common.max_process_capture_head_bytes / 8 in
  let bytes = Buffer.create (min max_bytes chunk_bytes) in
  let rec read offset =
    if offset = max_bytes then Ok (Buffer.contents bytes)
    else
      let count = min chunk_bytes (max_bytes - offset) in
      let* output = Keeper_sandbox_read_runner.run_command ?turn_sandbox_factory
          ~config ~meta
          ~command_argv:["sh"; "-c";
            "test -f \"$1\" || exit 1; exec od -An -v -tx1 -j \"$2\" -N \"$3\" \"$1\"";
            "browser-upload"; backend_path; string_of_int offset; string_of_int count]
          (* Keep the complete bounded Process_eio capture, including a possible
             truncation marker. A second prefix cut could hide that marker and
             turn incomplete hex into an apparently valid short final chunk.
             This does not alter Process_eio's head/tail caps; od itself is
             bounded by [count]. *)
          ~max_bytes:max_int
          ~timeout_sec:(Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Read ()) () in
      let* chunk = decode_hex output in
      if String.length chunk > count then Error "upload backend exceeded requested chunk size"
      else (
        Buffer.add_string bytes chunk;
        if String.length chunk < count then Ok (Buffer.contents bytes)
        else read (offset + String.length chunk)) in
  read 0

let with_staged_paths ?read_file ?turn_sandbox_factory ~config ~meta ~paths f =
  let read_file = match read_file with
    | Some reader -> reader
    | None -> backend_read ~turn_sandbox_factory ~config ~meta in
  let rec resolve acc = function
    | [] -> Ok (List.rev acc)
    | raw_path :: rest ->
      let* path = Keeper_tool_shared_runtime.resolve_keeper_read_path ~config ~meta ~raw_path in
      resolve ((raw_path,path) :: acc) rest in
  let* resolved = resolve [] paths in
  let files = List.map (fun (raw_path,host_path) ->
    Filename.basename host_path, (fun () ->
      let* bytes = read_file ~host_path ~max_bytes:(max_file_bytes + 1) in
      if String.length bytes > max_file_bytes then
        Error (Printf.sprintf "upload file exceeds %d bytes: %s" max_file_bytes raw_path)
      else Ok bytes)) resolved in
  Browser_lane.Upload_lease.with_staged_files ~files f
