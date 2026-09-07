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
     POSIX od's hex alphabet cannot contain a path. -N bounds the actual read;
     four output bytes per input byte cover spacing and line separators. *)
  let* output = Keeper_sandbox_read_runner.run_command ?turn_sandbox_factory
      ~config ~meta
      ~command_argv:["sh"; "-c";
        "test -f \"$1\" || exit 1; exec od -An -v -tx1 -N \"$2\" \"$1\"";
        "browser-upload"; backend_path; string_of_int max_bytes]
      ~max_bytes:(4 * max_bytes)
      ~timeout_sec:(Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Read ()) () in
  decode_hex output

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
  let* directory =
    try Ok (Filename.temp_dir ~perms:0o700 "masc-browser-upload-" "")
    with Sys_error message -> Error ("upload staging failed: " ^ message) in
  let staged = ref [] in
  let subdirs = ref [] in
  Eio_guard.protect ~finally:(fun () ->
    List.iter Unix.unlink !staged;
    List.iter Unix.rmdir !subdirs;
    Unix.rmdir directory) (fun () ->
      let rec stage index acc = function
        | [] -> Ok (List.rev acc)
        | (raw_path,host_path) :: rest ->
          let* bytes = read_file ~host_path ~max_bytes:(max_file_bytes + 1) in
          if String.length bytes > max_file_bytes then
            Error (Printf.sprintf "upload file exceeds %d bytes: %s" max_file_bytes raw_path)
          else
            let subdir = Filename.concat directory (string_of_int index) in
            Unix.mkdir subdir 0o700;
            subdirs := subdir :: !subdirs;
            let target = Filename.concat subdir (Filename.basename host_path) in
            let oc = open_out_gen [Open_wronly;Open_creat;Open_excl;Open_binary] 0o600 target in
            staged := target :: !staged;
            Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc bytes);
            stage (index+1) (target :: acc) rest in
      let* staged_paths =
        try stage 0 [] resolved with
        | Sys_error message -> Error ("upload staging failed: " ^ message)
        | Unix.Unix_error (error,operation,_) ->
          Error ("upload staging failed: " ^ operation ^ ": " ^ Unix.error_message error) in
      Ok (f staged_paths))
