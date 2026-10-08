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
  ; bidi_host : Browser_bidi_host_record.state
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
  { base_path; launcher; workspace_port; server
  ; bidi_host = Browser_bidi_host_record.observe ~base_path }

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
    "the MASC browser host installer, install-host.sh (%s in the MASC repository), with \
     --base-path %s"
    (Browser_lane.live_transport_setup_doc Browser_lane.Web_extension)
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

type bidi_attach = { launcher : string; arguments : string }

(* What the launcher is given to attach to a Firefox the operator started
   with --remote-debugging-port PORT. *)
let bidi_host_arguments = "--bidi-url ws://127.0.0.1:PORT/session"

let bidi_attach ~base_path =
  { launcher = Filename.concat (host_directory base_path) launcher_name
  ; arguments = bidi_host_arguments
  }

(* How a BiDi connection is added. *)
let attach_bidi ~base_path =
  let { launcher; arguments } = bidi_attach ~base_path in
  Printf.sprintf
    "the operator starts Firefox on a profile kept for this with --remote-debugging-port PORT, \
     then runs %s %s (%s)"
    launcher arguments
    (Browser_lane.live_transport_setup_doc Browser_lane.Webdriver_bidi)

let at seconds = Time_codec.rfc3339_of_unix seconds

(* Whether the host the record names polls the server this process is. The
   record is the host's own word; the lane's client list is the server's. *)
let bidi_host_polls t (entry : Browser_bidi_host_record.entry) =
  match t.server with
  | Not_serving ->
      " No MASC server runs in this process, so whether it polls one is not observed here."
  | Serving { polling; _ } ->
      if List.exists
           (fun (info : Browser_lane.client_info) ->
              info.transport = Browser_lane.Webdriver_bidi
              && String.equal (Browser_lane.client_id_to_string info.client_id) entry.client_id)
           polling
      then " It polls this server."
      else
        " This server does not list that client now. The host asks again after a request \
         that failed, so a server that only just started lists it within seconds."

(* The host's results that got no acknowledgement are in the record; the
   sentence only says there are some. *)
let bidi_host_unacknowledged (entry : Browser_bidi_host_record.entry) =
  match List.length entry.unacknowledged with
  | 0 -> ""
  | 1 -> " The server acknowledged all but one of its results; the record lists that one."
  | count ->
      Printf.sprintf " The server did not acknowledge %d of its results; the record lists them." count

let bidi_host_session (ending : Browser_bidi_host_record.ending) =
  match ending.session with
  | No_session_left -> ""
  | Session_left ->
      " Firefox did not confirm that its BiDi session ended. Restart that Firefox before \
       attaching again: while it holds the session it refuses the next host."
  | Session_unknown ->
      " Its connection to Firefox was gone before it could end its BiDi session. If that Firefox \
       is still running, it holds the session and refuses the next host until it is restarted."

let bidi_host_message t =
  let attach = attach_bidi ~base_path:t.base_path in
  match t.bidi_host with
  | Browser_bidi_host_record.Never_started ->
      Printf.sprintf
        "No BiDi browser host has run for this workspace. Hover and drag on the live lane \
         need one: %s."
        attach
  | Browser_bidi_host_record.Running ({ attached_at = None; _ } as entry) ->
      Printf.sprintf "A BiDi browser host (pid %d) started at %s and is connecting to %s."
        entry.pid (at entry.started_at) entry.bidi_url
  | Browser_bidi_host_record.Running ({ attached_at = Some attached; _ } as entry) ->
      Printf.sprintf "A BiDi browser host (pid %d) is attached to %s since %s, as client %s.%s%s"
        entry.pid entry.bidi_url (at attached) entry.client_id (bidi_host_polls t entry)
        (bidi_host_unacknowledged entry)
  | Browser_bidi_host_record.Ended (entry, ending) ->
      Printf.sprintf
        "No BiDi browser host is running. The last one (pid %d) ended at %s: %s.%s%s To attach \
         again, %s."
        entry.pid (at ending.at) ending.reason (bidi_host_session ending)
        (bidi_host_unacknowledged entry) attach
  | Browser_bidi_host_record.Died entry ->
      Printf.sprintf
        "No BiDi browser host is running. The last one (pid %d, started at %s) left no reason \
         for ending: it was killed or crashed, or could not write one. Its BiDi session may be \
         left in that Firefox, which then refuses the next host until it is restarted.%s To \
         attach again, %s."
        entry.pid (at entry.started_at) (bidi_host_unacknowledged entry) attach
  | Browser_bidi_host_record.Unreadable detail ->
      Printf.sprintf
        "The BiDi browser host's record cannot be read (%s). A host that starts replaces it: %s."
        detail attach

type bidi_host_report =
  { state : Browser_bidi_host_record.state
  ; attach : bidi_attach
  ; message : string
  }

let bidi_host_report t =
  { state = t.bidi_host
  ; attach = bidi_attach ~base_path:t.base_path
  ; message = bidi_host_message t
  }

let bidi_host_report_to_json { state; attach; message } =
  let name, record, detail =
    match state with
    | Browser_bidi_host_record.Never_started -> "never_started", `Null, `Null
    | Browser_bidi_host_record.Running entry ->
        "running", Browser_bidi_host_record.entry_to_json entry, `Null
    | Browser_bidi_host_record.Ended (entry, _) ->
        "ended", Browser_bidi_host_record.entry_to_json entry, `Null
    | Browser_bidi_host_record.Died entry -> "died", Browser_bidi_host_record.entry_to_json entry, `Null
    | Browser_bidi_host_record.Unreadable detail -> "unreadable", `Null, `String detail
  in
  `Assoc
    [ "state", `String name
    ; "record", record
    ; "detail", detail
    ; ( "attach"
      , `Assoc [ "launcher", `String attach.launcher; "arguments", `String attach.arguments ] )
    ; "message", `String message
    ]

let bidi_host_to_json t = bidi_host_report_to_json (bidi_host_report t)

let bidi_host_report_of_json json =
  let ( let* ) = Result.bind in
  let field fields name =
    Option.to_result ~none:("the BiDi host report has no " ^ name) (List.assoc_opt name fields)
  in
  let text fields name =
    let* value = field fields name in
    match value with
    | `String text -> Ok text
    | _ -> Error ("the BiDi host report's " ^ name ^ " is not a string")
  in
  let* fields =
    match json with
    | `Assoc fields -> Ok fields
    | _ -> Error "the BiDi host report is not an object"
  in
  let* name = text fields "state" in
  let entry () =
    let* record = field fields "record" in
    Browser_bidi_host_record.entry_of_json record
  in
  let* state =
    match name with
    | "never_started" -> Ok Browser_bidi_host_record.Never_started
    | "running" -> Result.map (fun entry -> Browser_bidi_host_record.Running entry) (entry ())
    | "ended" ->
        let* entry = entry () in
        (match entry.ended with
         | Some ending -> Ok (Browser_bidi_host_record.Ended (entry, ending))
         | None -> Error "the BiDi host report calls a record without an ending ended")
    | "died" -> Result.map (fun entry -> Browser_bidi_host_record.Died entry) (entry ())
    | "unreadable" ->
        Result.map (fun detail -> Browser_bidi_host_record.Unreadable detail) (text fields "detail")
    | _ -> Error "the BiDi host report names a state this reader does not know"
  in
  let* attach =
    let* attach = field fields "attach" in
    match attach with
    | `Assoc attach ->
        let* launcher = text attach "launcher" in
        let* arguments = text attach "arguments" in
        Ok { launcher; arguments }
    | _ -> Error "the BiDi host report's attach is not an object"
  in
  let* message = text fields "message" in
  Ok { state; attach; message }

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
    ; "bidi_host", bidi_host_to_json t
    ]
