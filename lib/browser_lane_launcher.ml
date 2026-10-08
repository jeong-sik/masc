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
  (* Reading the record can let other fibers run. The server is asked after
     it, so the client list here is as new as one the caller reads next. *)
  let bidi_host = Browser_bidi_host_record.observe ~base_path in
  { base_path; launcher; workspace_port; server = server (); bidi_host }

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

type bidi_launcher = Launcher_installed | Launcher_not_installed | Launcher_needs_reinstall

type bidi_attach = { launcher : string; arguments : string; standing : bidi_launcher }

(* What the launcher is given to attach to a Firefox the operator started
   with [firefox_flag]. *)
let bidi_host_arguments = "--bidi-url ws://127.0.0.1:PORT/session"
let firefox_flag = "--remote-debugging-port PORT"

let bidi_attach t =
  { launcher = Filename.concat (host_directory t.base_path) launcher_name
  ; arguments = bidi_host_arguments
  ; standing =
      (match t.launcher with
       | Follows_workspace -> Launcher_installed
       | Not_installed -> Launcher_not_installed
       | Undeclared | Unreadable | Describes_another_launcher -> Launcher_needs_reinstall)
  }

(* What the operator does to start a host. *)
let run_host t =
  let { launcher; arguments; standing = _ } = bidi_attach t in
  Printf.sprintf "runs %s %s" launcher arguments

(* What closes a paragraph that named the host command: the installation the
   launcher needs when it is not there or not as one wrote it, and where the
   steps are written. *)
let bidi_steps t =
  let installer = install ~base_path:t.base_path in
  let launcher_first =
    match (bidi_attach t).standing with
    | Launcher_installed -> ""
    | Launcher_not_installed ->
        Printf.sprintf
          " No browser lane is installed in this workspace, so that launcher is not there yet: \
           the operator first installs the lane by running %s."
          installer
    | Launcher_needs_reinstall ->
        Printf.sprintf
          " The launcher there is not as an installation wrote it: the operator first installs \
           the lane again by running %s."
          installer
  in
  Printf.sprintf "%s The steps are in %s." launcher_first
    (Browser_lane.live_transport_setup_doc Browser_lane.Webdriver_bidi)

let at seconds = Time_codec.rfc3339_of_unix seconds

let bidi_host_listed ~polling (entry : Browser_bidi_host_record.entry) =
  List.exists
    (fun (info : Browser_lane.client_info) ->
       info.transport = Browser_lane.Webdriver_bidi
       && String.equal
            (Browser_lane.client_id_to_string info.client_id)
            (Browser_lane.client_id_to_string entry.client_id))
    polling

type bidi_host_poll = Poll_unobserved | Polls_here | Not_listed_here

let bidi_host_poll t entry =
  match t.server with
  | Not_serving -> Poll_unobserved
  | Serving { polling; _ } -> if bidi_host_listed ~polling entry then Polls_here else Not_listed_here

type bidi_host_verdict =
  | Bidi_absent
  | Bidi_serving
  | Bidi_unverified
  | Bidi_not_running
  | Bidi_unreadable

let bidi_host_verdict t =
  match t.bidi_host, t.launcher with
  | Browser_bidi_host_record.Never_started, Not_installed -> Bidi_absent
  | ( Browser_bidi_host_record.Never_started
    , (Undeclared | Unreadable | Describes_another_launcher | Follows_workspace) )
  | (Browser_bidi_host_record.Ended _ | Browser_bidi_host_record.Died _), _ -> Bidi_not_running
  | Browser_bidi_host_record.Running entry, _ ->
      (match bidi_host_poll t entry with
       | Polls_here -> Bidi_serving
       | Poll_unobserved | Not_listed_here -> Bidi_unverified)
  | Browser_bidi_host_record.Unreadable _, _ -> Bidi_unreadable

(* The record is the host's own word; the lane's client list is the
   server's. A host the list lacks serves nothing here, whatever its record
   says, so the sentence names what makes the two differ. *)
let bidi_host_poll_sentence = function
  | Poll_unobserved ->
      " No MASC server runs in this process, so whether it polls one is not observed here; a \
       running server's own check reports it."
  | Polls_here -> " It polls this server."
  | Not_listed_here ->
      Printf.sprintf
        " This server does not list that client, so hover and drag are refused here. One of \
         these holds: the host polls another server (MASC_HTTP_BASE_URL or MASC_HTTP_PORT \
         exported in the shell that started it outranks this workspace's port); it has not \
         polled for %.0f seconds, after which this server ends a connection, and registers \
         again with its next poll; or this server started moments ago and the host has not \
         reached it yet. If the client stays unlisted, the operator stops that host and starts \
         it again from a shell without those variables."
        Browser_lane.lane_connected_window_sec

(* The results are in the record; the sentence says how many and that the
   record tells them apart. No acknowledgement reaching the host is not the
   server refusing one. *)
let bidi_host_unacknowledged (entry : Browser_bidi_host_record.entry) =
  let listed what =
    Printf.sprintf
      " The record lists %s the host holds no acknowledgement for, and says of each whether the \
       server refused it, the host could not send it, or no acknowledgement came."
      what
  in
  match List.length entry.unacknowledged with
  | 0 -> ""
  | 1 -> listed "one result"
  | count -> listed (Printf.sprintf "%d results" count)

(* What became of the last host's session decides what the operator does
   before the next one: a Firefox that holds a session refuses every host
   until it is restarted, and one that holds none needs only the host. *)
let bidi_host_next t (session : Browser_bidi_host_record.session) =
  let run = run_host t in
  match session with
  | No_session_left ->
      Printf.sprintf
        " While that Firefox still runs it takes the next host, so the operator only %s; a \
         Firefox that was closed is started again with %s first."
        run firefox_flag
  | Session_left ->
      Printf.sprintf
        " Firefox did not confirm that its BiDi session ended, and while it holds that session \
         it refuses the next host. The operator restarts that Firefox with %s, then %s."
        firefox_flag run
  | Session_unknown ->
      Printf.sprintf
        " Its connection to Firefox was gone before it could end its BiDi session. A Firefox \
         that exited took the session along; one that still runs holds it and refuses the next \
         host. The operator starts that Firefox again with %s, restarting it if it still runs, \
         then %s."
        firefox_flag run
  | Session_refused ->
      Printf.sprintf
        " Firefox refused it a BiDi session, which it does while it holds one already: that of \
         a host attached from another workspace, or one a host that died left there. The \
         operator stops that other host or, when none is attached, restarts that Firefox with \
         %s, then %s."
        firefox_flag run

let bidi_host_message t =
  let run = run_host t in
  match t.bidi_host with
  | Browser_bidi_host_record.Never_started ->
      Printf.sprintf
        "No BiDi browser host has run for this workspace. Hover and drag on the live lane need \
         one. The operator starts Firefox on a profile kept for this with %s, then %s.%s"
        firefox_flag run (bidi_steps t)
  | Browser_bidi_host_record.Running entry ->
      let client = Browser_lane.client_id_to_string entry.client_id in
      (match entry.attached_at, bidi_host_poll t entry with
       | Some attached, poll ->
           Printf.sprintf "A BiDi browser host (pid %d) is attached to %s since %s, as client %s.%s%s"
             entry.pid entry.bidi_url (at attached) client (bidi_host_poll_sentence poll)
             (bidi_host_unacknowledged entry)
       (* Only a host that has its session polls, so a listed client is an
          attached host whose record is behind. *)
       | None, Polls_here ->
           Printf.sprintf
             "A BiDi browser host (pid %d) is attached to %s and polls this server as client \
              %s. Its record does not say since when: the host could not write that.%s"
             entry.pid entry.bidi_url client (bidi_host_unacknowledged entry)
       | None, (Poll_unobserved | Not_listed_here) ->
           Printf.sprintf "A BiDi browser host (pid %d) started at %s and is connecting to %s."
             entry.pid (at entry.started_at) entry.bidi_url)
  | Browser_bidi_host_record.Ended (entry, ending) ->
      Printf.sprintf
        "No BiDi browser host is running. The last one (pid %d) ended at %s and gave this \
         reason: %S.%s%s%s"
        entry.pid (at ending.at) ending.reason (bidi_host_unacknowledged entry)
        (bidi_host_next t ending.session) (bidi_steps t)
  | Browser_bidi_host_record.Died entry ->
      Printf.sprintf
        "No BiDi browser host is running. The last one (pid %d, started at %s) left no reason \
         for ending: it was killed or crashed, or could not write one.%s Its BiDi session may be \
         left in that Firefox. The operator %s; when Firefox refuses that host a session, the \
         session was left there, and that Firefox is restarted with %s before the host is run \
         again.%s"
        entry.pid (at entry.started_at) (bidi_host_unacknowledged entry) run firefox_flag (bidi_steps t)
  | Browser_bidi_host_record.Unreadable { detail; held = Some true } ->
      Printf.sprintf
        "A BiDi browser host holds this workspace's lock, so one is running, and its record \
         cannot be read (%s): another build of MASC wrote it, or it was changed. A second host \
         is refused while that one runs. Once the operator stops it, the next host replaces the \
         record."
        detail
  | Browser_bidi_host_record.Unreadable { detail; held = Some false } ->
      Printf.sprintf
        "The BiDi browser host's record cannot be read (%s). No host holds this workspace's \
         lock, so none is running, and the next host replaces the record. The operator starts \
         Firefox on a profile kept for this with %s, unless it runs already, then %s.%s"
        detail firefox_flag run (bidi_steps t)
  | Browser_bidi_host_record.Unreadable { detail; held = None } ->
      Printf.sprintf
        "Whether a BiDi browser host runs for this workspace could not be checked (%s)." detail

type bidi_host_report =
  { state : Browser_bidi_host_record.state
  ; attach : bidi_attach
  ; message : string
  }

let bidi_host_report t =
  { state = t.bidi_host; attach = bidi_attach t; message = bidi_host_message t }

let bidi_host_state_name = function
  | Browser_bidi_host_record.Never_started -> "never_started"
  | Browser_bidi_host_record.Running _ -> "running"
  | Browser_bidi_host_record.Ended _ -> "ended"
  | Browser_bidi_host_record.Died _ -> "died"
  | Browser_bidi_host_record.Unreadable _ -> "unreadable"

let bidi_launcher_to_wire = function
  | Launcher_installed -> "installed"
  | Launcher_not_installed -> "not_installed"
  | Launcher_needs_reinstall -> "needs_reinstall"

let bidi_launcher_of_wire = function
  | "installed" -> Some Launcher_installed
  | "not_installed" -> Some Launcher_not_installed
  | "needs_reinstall" -> Some Launcher_needs_reinstall
  | _ -> None

(* The state is written as what it was read from: the record and whether
   the lock was held. [lock_held] is null where the state does not turn on
   it, and for a lock that could not be asked. *)
let bidi_host_report_to_json { state; attach; message } =
  let entry_json = Browser_bidi_host_record.entry_to_json in
  let record, lock_held, detail =
    match state with
    | Browser_bidi_host_record.Never_started -> `Null, `Null, `Null
    | Browser_bidi_host_record.Running entry -> entry_json entry, `Bool true, `Null
    | Browser_bidi_host_record.Ended (entry, ending) ->
        entry_json { entry with ended = Some ending }, `Null, `Null
    | Browser_bidi_host_record.Died entry -> entry_json entry, `Bool false, `Null
    | Browser_bidi_host_record.Unreadable { detail; held } ->
        `Null, Option.fold ~none:`Null ~some:(fun held -> `Bool held) held, `String detail
  in
  `Assoc
    [ "state", `String (bidi_host_state_name state)
    ; "record", record
    ; "lock_held", lock_held
    ; "detail", detail
    ; ( "attach"
      , `Assoc
          [ "launcher", `String attach.launcher
          ; "arguments", `String attach.arguments
          ; "launcher_state", `String (bidi_launcher_to_wire attach.standing)
          ] )
    ; "message", `String message
    ]

let bidi_host_to_json t = bidi_host_report_to_json (bidi_host_report t)

let bidi_host_summary_to_json t =
  `Assoc [ "state", `String (bidi_host_state_name t.bidi_host); "message", `String (bidi_host_message t) ]

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
  let* record =
    let* record = field fields "record" in
    match record with
    | `Null -> Ok None
    | record -> Result.map Option.some (Browser_bidi_host_record.entry_of_json record)
  in
  let* lock_held =
    let* lock_held = field fields "lock_held" in
    match lock_held with
    | `Null -> Ok None
    | `Bool held -> Ok (Some held)
    | _ -> Error "the BiDi host report's lock_held is neither true, false nor null"
  in
  let* detail =
    let* detail = field fields "detail" in
    match detail with
    | `Null -> Ok None
    | `String detail -> Ok (Some detail)
    | _ -> Error "the BiDi host report's detail is neither a string nor null"
  in
  (* The state is worked out again from what it was read from, by the rule
     the record's own reader uses, and has to be the one the report names. *)
  let* state =
    match record, detail, lock_held with
    | None, Some detail, held -> Ok (Browser_bidi_host_record.Unreadable { detail; held })
    | Some _, Some _, (Some _ | None) ->
        Error "the BiDi host report has a record and a reason it cannot be read"
    | None, None, None -> Ok (Browser_bidi_host_record.state_of ~lock_held:false (Ok None))
    | None, None, Some _ -> Error "the BiDi host report says of a lock with no record beside it"
    | Some ({ ended = Some _; _ } as entry), None, None ->
        Ok (Browser_bidi_host_record.state_of ~lock_held:false (Ok (Some entry)))
    | Some { ended = Some _; _ }, None, Some _ ->
        Error "the BiDi host report says of a lock beside a record that has its ending"
    | Some ({ ended = None; _ } as entry), None, Some lock_held ->
        Ok (Browser_bidi_host_record.state_of ~lock_held (Ok (Some entry)))
    | Some { ended = None; _ }, None, None ->
        Error "the BiDi host report does not say whether the host's lock is held"
  in
  let* () =
    if String.equal (bidi_host_state_name state) name
    then Ok ()
    else Error "the BiDi host report names a state its record and lock do not make"
  in
  let* attach =
    let* attach = field fields "attach" in
    match attach with
    | `Assoc attach ->
        let* launcher = text attach "launcher" in
        let* arguments = text attach "arguments" in
        let* standing =
          let* raw = text attach "launcher_state" in
          Option.to_result
            ~none:"the BiDi host report names a launcher state this reader does not know"
            (bidi_launcher_of_wire raw)
        in
        Ok { launcher; arguments; standing }
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
    ]
