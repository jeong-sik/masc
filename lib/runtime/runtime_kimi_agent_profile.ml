let ( let* ) = Result.bind
let agents_directory = Filename.concat ".kimi-code" "agents"
let file_relative_path = Filename.concat agents_directory "agent.md"

(* Kimi Code 2.7.3 requires [description] and a non-empty body, and reads
   [tools] as a list of names or globs; a JSON array is a YAML flow list. *)
let masc_only ~mcp_server_name =
  let tools =
    match mcp_server_name with
    | Some name -> [ `String (Printf.sprintf "mcp__%s__*" name) ]
    | None -> []
  in
  String.concat
    "\n"
    [ "---"
    ; "name: agent"
    ; "description: MASC Keeper host with the MASC tools only"
    ; "override: true"
    ; "tools: " ^ Yojson.Safe.to_string (`List tools)
    ; "---"
    ; "${base_prompt}"
    ; ""
    ]
;;

let make_directory path =
  match Sys.mkdir path 0o700 with
  | () -> Ok ()
  | exception Sys_error detail -> Error detail
;;

let surface_revision = masc_only ~mcp_server_name:None

let write_masc_only ~cwd ~mcp_server_name =
  let directories = [ Filename.concat cwd ".kimi-code"; Filename.concat cwd agents_directory ] in
  let rec make = function
    | [] -> Ok ()
    | dir :: rest ->
      let* () = make_directory dir in
      make rest
  in
  let empty =
    match Sys.readdir cwd with
    | [||] -> Ok ()
    | _ -> Error (cwd ^ ": the folder is not empty")
    | exception Sys_error detail -> Error detail
  in
  (* [with_open_gen] closes without reporting errors, and a profile this
     short is only written at the close, so the flush inside reports a full
     disk instead of leaving an empty file behind an [Ok]. *)
  let write () =
    match
      Out_channel.with_open_gen
        [ Open_wronly; Open_creat; Open_excl; Open_text ]
        0o600
        (Filename.concat cwd file_relative_path)
        (fun oc ->
           Out_channel.output_string oc (masc_only ~mcp_server_name);
           Out_channel.flush oc)
    with
    | () -> Ok ()
    | exception Sys_error detail -> Error detail
  in
  let result =
    let* () = empty in
    let* () = make directories in
    write ()
  in
  Result.map_error (fun detail -> "kimi agent profile: " ^ detail) result
;;
