type t =
  | Serve
  | Open_tui of { binary : string; argv : string list }

let tui_binary_name = "masc-tui"

let path_entries path =
  String.split_on_char ':' path |> List.filter (fun dir -> not (String.equal dir ""))

let discover_tui ~executable_name ~path_env ~is_executable =
  let in_dir dir =
    let candidate = Filename.concat dir tui_binary_name in
    if is_executable candidate then Some candidate else None
  in
  match in_dir (Filename.dirname executable_name) with
  | Some found -> Some found
  | None ->
    (match path_env with
     | None -> None
     | Some path -> List.find_map in_dir (path_entries path))

let tui_argv ~binary ~port ~base_path =
  [ binary; "--port"; string_of_int port ]
  @ (match base_path with
     | Some path -> [ "--base-path"; path ]
     | None -> [])

let decide
      ~interactive
      ~host
      ~default_host
      ~deployment_flags_present
      ~port
      ~base_path
      ~executable_name
      ~path_env
      ~is_executable
  =
  if deployment_flags_present
     || (not (String.equal host default_host))
     || not interactive
  then Serve
  else
    match discover_tui ~executable_name ~path_env ~is_executable with
    | None -> Serve
    | Some binary -> Open_tui { binary; argv = tui_argv ~binary ~port ~base_path }
