type launcher =
  | Not_installed
  | Undeclared
  | Unreadable
  | Describes_another_launcher
  | Follows_workspace

type server =
  | Not_serving
  | Serving of { port : int; polling : Browser_lane.client_info list }

let current_server () =
  match Browser_lane.serving_port () with
  | Browser_lane.Serving_port_unknown -> Not_serving
  | Browser_lane.Serving_port port -> Serving { port; polling = Browser_lane.active_clients () }

type t =
  { base_path : string
  ; launcher : launcher
  ; workspace_port : (int, Workspace_connection.error) result
  ; server : server
  }

type verdict = Absent | Connected | Aligned | Unverified | Misconfigured

let host_directory base_path =
  List.fold_left Filename.concat base_path [ Common.masc_dirname; "browser-lane"; "host" ]

(* install-host.sh writes both files in one installation; the names and the
   declaration's fields are the contract between that script and this reader. *)
let launcher_name = "launch"
let declaration_name = "launch.json"
let declaration_fields = [ "destination"; "launcher_sha256" ]

(* The launcher digest a declaration carries, when the declaration is exactly
   the object the installer writes; see the interface for the refusal rule. *)
let declared_launcher_digest = function
  | `Assoc fields ->
      (match
         List.sort String.compare (List.map fst fields),
         List.assoc_opt "destination" fields,
         List.assoc_opt "launcher_sha256" fields
       with
       | names, Some (`String "workspace_connection"), Some (`String digest)
         when names = declaration_fields -> Some digest
       | _ -> None)
  | _ -> None

let read_file path =
  match In_channel.with_open_bin path In_channel.input_all with
  | text -> Some text
  | exception Sys_error _ -> None

let observe ~base_path ~server =
  let directory = host_directory base_path in
  let path name = Filename.concat directory name in
  let exists name =
    match Sys.file_exists (path name) with
    | present -> present
    | exception Sys_error _ -> false
  in
  let launcher =
    match exists launcher_name, exists declaration_name with
    | false, _ -> Not_installed
    | true, false -> Undeclared
    | true, true ->
        let declared =
          Option.bind (read_file (path declaration_name)) (fun text ->
            match Yojson.Safe.from_string text with
            | json -> declared_launcher_digest json
            | exception Yojson.Json_error _ -> None)
        in
        (match declared, read_file (path launcher_name) with
         | None, _ | _, None -> Unreadable
         | Some digest, Some script
           when String.equal digest Digestif.SHA256.(to_hex (digest_string script)) ->
             Follows_workspace
         | Some _, Some _ -> Describes_another_launcher)
  in
  let workspace_port =
    Workspace_connection.resolve ~base_path:(Some base_path) ~cli:None ~environment:None
    |> Result.map Workspace_connection.to_int
  in
  { base_path; launcher; workspace_port; server }

let verdict t =
  match t.server, t.launcher, t.workspace_port with
  | Serving { polling = _ :: _; _ }, _, _ -> Connected
  | _, Not_installed, _ -> Absent
  | _, (Undeclared | Unreadable | Describes_another_launcher), _ | _, Follows_workspace, Error _ ->
      Misconfigured
  | Not_serving, Follows_workspace, Ok _ -> Unverified
  | Serving { port; polling = [] }, Follows_workspace, Ok workspace when workspace = port -> Aligned
  | Serving { polling = []; _ }, Follows_workspace, Ok _ -> Misconfigured

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

let launcher_problem t =
  let base_path = t.base_path in
  match t.launcher with
  | Not_installed ->
      Some (Printf.sprintf
        "No browser lane host is installed in this workspace. The operator runs %s and loads \
         the MASC extension in the browser."
        (install ~base_path))
  | Undeclared ->
      Some (Printf.sprintf
        "The browser lane launcher in %s has no %s beside it, so where that host polls is \
         unknown. %s"
        (host_directory base_path) declaration_name (reinstall ~base_path))
  | Unreadable ->
      Some (Printf.sprintf
        "The browser lane launcher or its declaration %s cannot be read as one installation \
         wrote them. %s"
        (Filename.concat (host_directory base_path) declaration_name) (reinstall ~base_path))
  | Describes_another_launcher ->
      Some (Printf.sprintf
        "The browser lane declaration %s was written for other launcher contents than the \
         launch script beside it, so where that host polls is unknown. %s"
        (Filename.concat (host_directory base_path) declaration_name) (reinstall ~base_path))
  | Follows_workspace -> None

let message t =
  let polling = "A browser lane host polls this server now." in
  match t.server, launcher_problem t, t.workspace_port with
  | Serving { polling = _ :: _; _ }, None, _ -> polling
  | Serving { polling = _ :: _; _ }, Some problem, _ -> polling ^ " " ^ problem
  | (Not_serving | Serving { polling = []; _ }), Some problem, _ -> problem
  | (Not_serving | Serving { polling = []; _ }), None, Error error ->
      Workspace_connection.error_message error
  | Serving { port = serving; polling = [] }, None, Ok port when port = serving ->
      Printf.sprintf
        "The browser lane host follows the workspace connection port, %d, which is the port \
         this server listens on, and no browser host polls this server now. %s"
        port environment_note
  | Serving { port = serving; polling = [] }, None, Ok port ->
      Printf.sprintf
        "The workspace connection names port %d, but this server listens on %d, and no browser \
         host polls this server. A host the launcher starts goes to %d. After a request there \
         fails it reads the connection again, stays while a server at its address still \
         answers, and moves only to an address that answers. The operator runs `masc \
         workspace-connection --port %d --save`, then reloads the browser extension so a new \
         host starts on %d. %s"
        port serving port serving serving environment_note
  | Not_serving, None, Ok port ->
      Printf.sprintf
        "The browser lane host follows the workspace connection port, now %d. No MASC server \
         runs in this process, so whether a browser host polls that port is not observed \
         here; a running server's own check reports it. %s"
        port environment_note

let to_json t =
  let workspace_port, workspace_port_error =
    match t.workspace_port with
    | Ok port -> `Int port, `Null
    | Error error -> `Null, `String (Workspace_connection.error_message error)
  in
  let serving_port, polling_hosts =
    match t.server with
    | Serving { port; polling } -> `Int port, `Int (List.length polling)
    | Not_serving -> `Null, `Null
  in
  `Assoc
    [ "launcher", `String (match t.launcher with
        | Not_installed -> "not_installed" | Undeclared -> "undeclared"
        | Unreadable -> "unreadable" | Describes_another_launcher -> "describes_another_launcher"
        | Follows_workspace -> "follows_workspace")
    ; "workspace_port", workspace_port
    ; "workspace_port_error", workspace_port_error
    ; "serving_port", serving_port
    ; "polling_hosts", polling_hosts
    ; "verdict", `String (match verdict t with
        | Absent -> "absent" | Connected -> "connected" | Aligned -> "aligned"
        | Unverified -> "unverified" | Misconfigured -> "misconfigured")
    ; "message", `String (message t)
    ]
