type launcher = Not_installed | Unreadable | Follows_workspace | Pinned of int | Unusable_origin

type t = { launcher : launcher; workspace_port : (int, Workspace_connection.error) result }

type verdict = Absent | Aligned | Misconfigured

(* An http origin without an explicit port is port 80 (RFC 9110, section 4.2.1). *)
let http_scheme_port = 80

let launcher_path base_path =
  List.fold_left Filename.concat base_path
    [ Common.masc_dirname; "browser-lane"; "host"; "launch" ]

(* install-host.sh writes the launcher as one exec line of shell-quoted words,
   so the scan reads whole words, never substrings. *)
let server_argument text =
  let rec scan = function
    | "--server" :: origin :: _ ->
        let uri = Uri.of_string origin in
        if Uri.scheme uri = Some "http" then
          match Uri.port uri with
          | Some port when port > 0 && port <= 65535 -> Pinned port
          | Some _ -> Unusable_origin
          | None -> Pinned http_scheme_port
        else Unusable_origin
    | _ :: rest -> scan rest
    | [] -> Follows_workspace
  in
  scan (List.filter (fun word -> word <> "") (String.split_on_char ' ' text))

let observe ~base_path =
  let path = launcher_path base_path in
  let launcher =
    match Sys.file_exists path with
    | false -> Not_installed
    | true ->
        (match In_channel.with_open_bin path In_channel.input_all with
         | text -> server_argument text
         | exception Sys_error _ -> Unreadable)
    | exception Sys_error _ -> Not_installed
  in
  let workspace_port =
    match Workspace_connection.read ~base_path with
    | Error error -> Error error
    | Ok None -> Ok Masc_network_defaults.masc_http_default_port
    | Ok (Some port) -> Ok (Workspace_connection.to_int port)
  in
  { launcher; workspace_port }

let verdict t =
  match t.launcher, t.workspace_port with
  | Not_installed, _ -> Absent
  | (Unreadable | Unusable_origin), _ | (Follows_workspace | Pinned _), Error _ -> Misconfigured
  | Follows_workspace, Ok _ -> Aligned
  | Pinned port, Ok expected when port = expected -> Aligned
  | Pinned _, Ok _ -> Misconfigured

let reinstall =
  "Re-run connectors/browser/install-host.sh so the lane follows the workspace, then reload \
   the browser extension so a new host starts."

let message t =
  match t.launcher, t.workspace_port with
  | Not_installed, _ ->
      "No browser lane host is installed in this workspace. The operator installs it with \
       connectors/browser/install-host.sh and loads the MASC extension in the browser."
  | Unreadable, _ -> "The browser lane launcher cannot be read."
  | (Follows_workspace | Pinned _ | Unusable_origin), Error error ->
      Workspace_connection.error_message error
  | Unusable_origin, Ok _ ->
      "The browser lane launcher's --server is not an http origin with a usable port. " ^ reinstall
  | Follows_workspace, Ok port ->
      Printf.sprintf
        "The browser lane launcher follows the workspace connection port, now %d, and reads it \
         again after a failed poll. An exported MASC_HTTP_BASE_URL or MASC_HTTP_PORT in the \
         browser's environment still takes precedence, which this observation cannot see."
        port
  | Pinned port, Ok expected when port = expected ->
      Printf.sprintf
        "The browser lane launcher is fixed to port %d, which the workspace connection names \
         now. It will not follow a later port change. %s"
        port reinstall
  | Pinned port, Ok expected ->
      Printf.sprintf
        "The browser lane launcher is fixed to port %d while the workspace connection port is \
         %d. %s"
        port expected reinstall

let to_json t =
  let launcher, launcher_port =
    match t.launcher with
    | Not_installed -> "not_installed", `Null
    | Unreadable -> "unreadable", `Null
    | Follows_workspace -> "follows_workspace", `Null
    | Pinned port -> "pinned", `Int port
    | Unusable_origin -> "unusable_origin", `Null
  in
  let workspace_port, workspace_port_error =
    match t.workspace_port with
    | Ok port -> `Int port, `Null
    | Error error -> `Null, `String (Workspace_connection.error_message error)
  in
  `Assoc
    [ "launcher", `String launcher
    ; "launcher_port", launcher_port
    ; "workspace_port", workspace_port
    ; "workspace_port_error", workspace_port_error
    ; "verdict", `String (match verdict t with
        | Absent -> "absent" | Aligned -> "aligned" | Misconfigured -> "misconfigured")
    ; "message", `String (message t)
    ]
