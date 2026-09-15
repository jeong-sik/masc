type launcher = Not_installed | Undeclared | Unreadable | Follows_workspace

type t =
  { base_path : string
  ; launcher : launcher
  ; workspace_port : (int, Workspace_connection.error) result
  ; serving_port : int option
  }

type verdict = Absent | Aligned | Misconfigured

let host_directory base_path =
  List.fold_left Filename.concat base_path [ Common.masc_dirname; "browser-lane"; "host" ]

(* install-host.sh writes this declaration beside the launcher it installs;
   the two names are the contract between that script and this reader. *)
let launcher_name = "launch"
let declaration_name = "launch.json"

let declared = function
  | `Assoc [ ("destination", `String "workspace_connection") ] -> Follows_workspace
  | _ -> Unreadable

let observe ~base_path ~serving_port =
  let directory = host_directory base_path in
  let exists name =
    match Sys.file_exists (Filename.concat directory name) with
    | present -> present
    | exception Sys_error _ -> false
  in
  let launcher =
    match exists launcher_name, exists declaration_name with
    | false, _ -> Not_installed
    | true, false -> Undeclared
    | true, true ->
        (match Yojson.Safe.from_file (Filename.concat directory declaration_name) with
         | json -> declared json
         | exception (Sys_error _ | Yojson.Json_error _) -> Unreadable)
  in
  let workspace_port =
    Workspace_connection.resolve ~base_path:(Some base_path) ~cli:None ~environment:None
    |> Result.map Workspace_connection.to_int
  in
  { base_path; launcher; workspace_port; serving_port }

let verdict t =
  match t.launcher, t.workspace_port, t.serving_port with
  | Not_installed, _, _ -> Absent
  | (Undeclared | Unreadable), _, _ | Follows_workspace, Error _, _ -> Misconfigured
  | Follows_workspace, Ok port, Some serving when port = serving -> Aligned
  | Follows_workspace, Ok _, Some _ -> Misconfigured
  | Follows_workspace, Ok _, None -> Aligned

let install ~base_path =
  Printf.sprintf
    "the MASC browser host installer, install-host.sh (connectors/browser/host/README.md in the \
     MASC repository), with --base-path %s"
    base_path

let reinstall ~base_path =
  Printf.sprintf
    "The operator runs %s, then reloads the browser extension so a new host starts."
    (install ~base_path)

let environment_note =
  "An exported MASC_HTTP_BASE_URL or MASC_HTTP_PORT in the browser's environment fixes the \
   address instead, which this observation cannot see."

let message t =
  let base_path = t.base_path in
  match t.launcher, t.workspace_port, t.serving_port with
  | Not_installed, _, _ ->
      Printf.sprintf
        "No browser lane host is installed in this workspace. The operator runs %s and loads \
         the MASC extension in the browser."
        (install ~base_path)
  | Undeclared, _, _ ->
      Printf.sprintf
        "The browser lane launcher in %s has no %s beside it, so where that host polls is \
         unknown. %s"
        (host_directory base_path) declaration_name (reinstall ~base_path)
  | Unreadable, _, _ ->
      Printf.sprintf "The browser lane launcher declaration %s cannot be read. %s"
        (Filename.concat (host_directory base_path) declaration_name) (reinstall ~base_path)
  | Follows_workspace, Error error, _ -> Workspace_connection.error_message error
  | Follows_workspace, Ok port, Some serving when port = serving ->
      Printf.sprintf
        "The browser lane host follows the workspace connection port, %d, which is the port \
         this server listens on. %s"
        port environment_note
  | Follows_workspace, Ok port, Some serving ->
      Printf.sprintf
        "The browser lane host follows the workspace connection port, %d, but this server \
         listens on %d, so the host polls another address. `masc workspace-connection --port \
         %d --save` points the connection at this server. %s"
        port serving serving environment_note
  | Follows_workspace, Ok port, None ->
      Printf.sprintf
        "The browser lane host follows the workspace connection port, now %d. It moves to a new \
         port only once its current server stops answering and the new one answers. %s"
        port environment_note

let to_json t =
  let workspace_port, workspace_port_error =
    match t.workspace_port with
    | Ok port -> `Int port, `Null
    | Error error -> `Null, `String (Workspace_connection.error_message error)
  in
  `Assoc
    [ "launcher", `String (match t.launcher with
        | Not_installed -> "not_installed" | Undeclared -> "undeclared"
        | Unreadable -> "unreadable" | Follows_workspace -> "follows_workspace")
    ; "workspace_port", workspace_port
    ; "workspace_port_error", workspace_port_error
    ; "serving_port", (match t.serving_port with Some port -> `Int port | None -> `Null)
    ; "verdict", `String (match verdict t with
        | Absent -> "absent" | Aligned -> "aligned" | Misconfigured -> "misconfigured")
    ; "message", `String (message t)
    ]
