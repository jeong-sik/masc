type t =
  | Launcher
  | Browser_process_owner
[@@deriving enumerate]

let name = function
  | Launcher -> "masc-native-addon-launcher"
  | Browser_process_owner -> "masc-browser-process-owner"

let locate program =
  let name = name program in
  try
    let siblings = if Filename.is_relative Sys.executable_name then [] else
      [Filename.concat (Filename.dirname (Unix.realpath Sys.executable_name)) name;
       Filename.concat (Filename.dirname Sys.executable_name) name] in
    let paths = match Sys.getenv_opt "PATH" with
      | None -> []
      | Some raw -> Executable_path.split_search_path raw
          |> List.filter (fun directory -> directory<>"")
          |> List.map (fun directory -> Filename.concat directory name) in
    match List.find_opt Executable_path.command_available (siblings @ paths) with
    | Some path -> Ok (Unix.realpath path)
    | None -> Error (name ^ " is not installed beside MASC or on PATH")
  with (Unix.Unix_error _ | Sys_error _) as exn -> Error (Printexc.to_string exn)

let command_ready ~package_directory command =
  let candidate = if Filename.is_relative command && String.contains command '/'
    then Filename.concat package_directory command else command in
  Executable_path.command_available candidate
