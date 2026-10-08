module Launcher = Browser_lane_launcher
module Record = Browser_bidi_host_record

type observation = { lane : Launcher.t; record : Record.state }

(* Reading the record and the launcher's files can let other fibers run.
   The server is asked after both, so its connection list is the newest
   thing in the observation: a host that attached during the reads is in
   it. *)
let observe ~base_path =
  let record = Record.observe ~base_path in
  let lane = Launcher.observe ~base_path ~server:Launcher.Not_serving in
  { lane = { lane with server = Launcher.current_server () }; record }

(* A process that bound no listener was not asked for its connections, so
   they are listed here: once, either way. *)
let listed_clients { lane; record = _ } =
  match lane.server with
  | Launcher.Serving { polling; _ } -> polling
  | Launcher.Not_serving -> Browser_lane.active_clients ()

type launcher_standing = Launcher_installed | Launcher_not_installed | Launcher_needs_reinstall

type attach = { launcher : string; arguments : string; standing : launcher_standing }

(* What the launcher is given to attach to a Firefox the operator started
   with [firefox_flag PORT]. *)
let bidi_url_flag = "--bidi-url"
let host_arguments = bidi_url_flag ^ " ws://127.0.0.1:PORT/session"
let firefox_flag = "--remote-debugging-port"

let attach_for (t : Launcher.t) =
  { launcher = Launcher.launcher_path ~base_path:t.base_path
  ; arguments = host_arguments
  ; standing =
      (match t.launcher with
       | Launcher.Follows_workspace -> Launcher_installed
       | Launcher.Not_installed -> Launcher_not_installed
       | Launcher.Undeclared | Launcher.Unreadable | Launcher.Describes_another_launcher ->
           Launcher_needs_reinstall)
  }

(* What the operator does to start a host. After a host, the address is the
   one that host was given; before any, the launcher's own words stand. *)
let run_host (t : Launcher.t) ~address =
  let { launcher; arguments; standing = _ } = attach_for t in
  match address with
  | None -> Printf.sprintf "runs %s %s" (Filename.quote launcher) arguments
  | Some address ->
      Printf.sprintf "runs %s %s %s" (Filename.quote launcher) bidi_url_flag (Filename.quote address)

(* What closes a paragraph that named the host command: the installation the
   launcher needs when it is not there or not as one wrote it, and where the
   steps are written. *)
let steps (t : Launcher.t) =
  let installer = Launcher.install ~base_path:t.base_path in
  let launcher_first =
    match (attach_for t).standing with
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

(* What starts a Firefox that answers at an address a host was given: on
   the profile kept for it, which a Firefox started some other way is not. *)
let firefox_at address =
  let flag =
    match Browser_bidi_downloads.endpoint address with
    | Ok (_, port, _) -> Printf.sprintf "%s %d" firefox_flag port
    | Error _ -> Printf.sprintf "%s set to that address's port" firefox_flag
  in
  flag ^ " on the profile kept for this"

let at seconds = Time_codec.rfc3339_of_unix seconds

let bidi_clients polling =
  List.filter
    (fun (info : Browser_lane.client_info) -> info.transport = Browser_lane.Webdriver_bidi)
    polling

(* Whether the observed server lists the client a running host's record
   names, as a BiDi client: an extension connection under that ID is not
   that host. The record is the host's word and the list is the server's. A
   host the list lacks serves nothing there, unless it is there under an ID
   its record has not caught up with, which is what another BiDi connection
   in the list may be. *)
type poll = Poll_unobserved | Polls_here | Not_listed_here | Another_bidi_listed

let poll_of (t : Launcher.t) (entry : Record.entry) =
  match t.server with
  | Launcher.Not_serving -> Poll_unobserved
  | Launcher.Serving { polling; _ } ->
      let named = Browser_lane.client_id_to_string entry.client_id in
      (match
         List.partition
           (fun (info : Browser_lane.client_info) ->
              String.equal (Browser_lane.client_id_to_string info.client_id) named)
           (bidi_clients polling)
       with
       | _ :: _, _ -> Polls_here
       | [], [] -> Not_listed_here
       | [], _ :: _ -> Another_bidi_listed)

type verdict = Host_absent | Host_serving | Host_unverified | Host_not_running | Host_unreadable

let verdict { lane; record } =
  match record, lane.launcher with
  | Record.Never_started, Launcher.Not_installed -> Host_absent
  | ( Record.Never_started
    , Launcher.(Undeclared | Unreadable | Describes_another_launcher | Follows_workspace) )
  | (Record.Ended _ | Record.Died _), _ -> Host_not_running
  | Record.Record_missing_but_locked, _ -> Host_unverified
  | Record.Running entry, _ ->
      (match poll_of lane entry with
       | Polls_here -> Host_serving
       | Poll_unobserved | Not_listed_here | Another_bidi_listed -> Host_unverified)
  | Record.Unreadable _, _ -> Host_unreadable

let poll_sentence = function
  | Poll_unobserved ->
      " No MASC server runs in this process, so whether it polls one is not observed here; a \
       running server's own check reports it."
  | Polls_here -> " It polls this server."
  | Not_listed_here ->
      Printf.sprintf
        " This server lists no BiDi connection, so hover and drag are refused here. One of \
         these holds: the host polls another server (MASC_HTTP_BASE_URL or MASC_HTTP_PORT \
         exported in the shell that started it outranks this workspace's port); it has not \
         polled for %.0f seconds, after which this server ends a connection, and registers \
         again with its next poll; or this server started moments ago and the host has not \
         reached it yet. If no BiDi connection appears, the operator stops that host and starts \
         it again from a shell without those variables."
        Browser_lane.lane_connected_window_sec
  | Another_bidi_listed ->
      " This server does not list that client and lists another BiDi connection. That \
       connection is this host's if it registered again under a new ID that it could not write \
       to its record. Otherwise it is another host's, and this one polls another server or has \
       stopped polling."

(* What is said, besides, of a host that does not run while the server lists
   a BiDi connection: the record and the list are two words, and for a while
   they can differ. *)
let listed_beside (t : Launcher.t) =
  match t.server with
  | Launcher.Not_serving -> ""
  | Launcher.Serving { polling; _ } ->
      (match bidi_clients polling with
       | [] -> ""
       | _ :: _ ->
           Printf.sprintf
             " This server lists a BiDi connection all the same: a host that died stays listed \
              until %.0f seconds pass without a poll, and a host started for another workspace \
              can poll this server."
             Browser_lane.lane_connected_window_sec)

(* The results are in the record; the sentence says how many, where, and
   that the record tells them apart. No acknowledgement reaching the host is
   not the server refusing one. *)
let unacknowledged (t : Launcher.t) (entry : Record.entry) =
  let listed what each =
    Printf.sprintf
      " Its record, %s, lists %s the host holds no acknowledgement for, and %swhether the server \
       refused it, the host could not send it, or no acknowledgement came."
      (Record.record_path ~base_path:t.base_path)
      what each
  in
  match List.length entry.unacknowledged with
  | 0 -> ""
  | 1 -> listed "one result" ""
  | count -> listed (Printf.sprintf "%d results" count) "for each "

(* What became of the last host's session decides what the operator does
   before the next one. A Firefox that holds a session refuses every host
   until that session's host ends it or the Firefox is restarted; one that
   holds none takes the next host as it is. A host that never got a session
   left none, and what kept it from one is still there for the next. *)
let next_host t (entry : Record.entry) (ending : Record.ending) =
  let run = run_host t ~address:(Some entry.bidi_url) in
  let firefox = firefox_at entry.bidi_url in
  match entry.attached_at, ending.session with
  | Some _, No_session_left ->
      Printf.sprintf
        " It ended its BiDi session, so the Firefox at that address needs no restart and takes \
         the next host while it runs. The operator %s; a Firefox that was closed is first \
         started again with %s."
        run firefox
  | None, No_session_left ->
      Printf.sprintf
        " It ended before Firefox gave it a session and left none there. The next host needs a \
         Firefox that answers at that address, one started with %s: the operator checks that, \
         then %s."
        firefox run
  | (Some _ | None), Session_left ->
      Printf.sprintf
        " Firefox did not confirm that its BiDi session ended, and while it holds that session \
         it refuses the next host. The operator restarts the Firefox at that address with %s, \
         then %s."
        firefox run
  | (Some _ | None), Session_unknown ->
      Printf.sprintf
        " Its connection to Firefox was gone before it could end its BiDi session. A Firefox \
         that exited took the session along; one that still runs holds it and refuses the next \
         host. The operator starts the Firefox for that address again with %s, restarting it if \
         it still runs, then %s."
        firefox run
  | (Some _ | None), Session_refused ->
      Printf.sprintf
        " Firefox refused it a BiDi session, which it does while it holds one: that of a host \
         attached from another workspace, or one a host that died left there. The operator \
         stops a host still attached to the Firefox at that address, then %s; when that host \
         is refused too with none attached, a dead host's session is left there, and that \
         Firefox is first restarted with %s."
        run firefox

(* A reason is another program's words inside this paragraph: it is set
   apart by quotes, and a quote in it is marked. *)
let quoted text = "\"" ^ String.concat "\\\"" (String.split_on_char '"' text) ^ "\""

let message { lane = t; record } =
  match record with
  | Record.Never_started ->
      Printf.sprintf
        "No BiDi browser host has run for this workspace. Hover and drag on the live lane need \
         one. The operator starts Firefox on a profile kept for this with %s PORT, then %s.%s%s"
        firefox_flag (run_host t ~address:None) (listed_beside t) (steps t)
  | Record.Record_missing_but_locked ->
      "A BiDi browser host holds this workspace's lock, but its record is missing. It may be \
       starting or the record may have been removed while it ran; its status is unverified. \
       A second host is refused while the lock is held."
  | Record.Running entry ->
      let client = Browser_lane.client_id_to_string entry.client_id in
      (match entry.attached_at, poll_of t entry with
       | Some attached, poll ->
           Printf.sprintf "A BiDi browser host (pid %d) is attached to %s since %s, as client %s.%s%s"
             entry.pid entry.bidi_url (at attached) client (poll_sentence poll)
             (unacknowledged t entry)
       (* Only a host that has its session polls, so a listed client is an
          attached host whose record is behind. *)
       | None, Polls_here ->
           Printf.sprintf
             "A BiDi browser host (pid %d) is attached to %s and polls this server as client \
              %s. Its record does not say since when: it was read before the host wrote that, \
              or the host could not write it.%s"
             entry.pid entry.bidi_url client (unacknowledged t entry)
       | None, (Poll_unobserved | Not_listed_here | Another_bidi_listed) ->
           Printf.sprintf "A BiDi browser host (pid %d) started at %s and is connecting to %s."
             entry.pid (at entry.started_at) entry.bidi_url)
  | Record.Ended (entry, ending) ->
      Printf.sprintf
        "No BiDi browser host is running. The last one (pid %d, given %s) ended at %s with this \
         reason: %s.%s%s%s%s"
        entry.pid entry.bidi_url (at ending.at) (quoted ending.reason)
        (unacknowledged t entry) (next_host t entry ending) (listed_beside t)
        (steps t)
  | Record.Died entry ->
      Printf.sprintf
        "No BiDi browser host is running. The last one (pid %d, given %s, started at %s) left no \
         reason for ending: it was killed or crashed, or could not write one.%s Its BiDi session \
         may be left in the Firefox at that address. The operator %s; when Firefox refuses that \
         host a session, the session was left there, and that Firefox is restarted with %s \
         before the host is run again.%s%s"
        entry.pid entry.bidi_url (at entry.started_at) (unacknowledged t entry)
        (run_host t ~address:(Some entry.bidi_url)) (firefox_at entry.bidi_url) (listed_beside t)
        (steps t)
  | Record.Unreadable { detail; held = Some true } ->
      Printf.sprintf
        "A BiDi browser host holds this workspace's lock, so one is running, and its record \
         cannot be read (%s). A second host is refused while that one runs. Once the operator \
         stops it, the next host writes a new record in its place, and does not start when it \
         cannot."
        detail
  | Record.Unreadable { detail; held = Some false } ->
      Printf.sprintf
        "The BiDi browser host's record cannot be read (%s). No host holds this workspace's \
         lock, so none is running. The next host writes a new record in its place, and does not \
         start when it cannot. The operator starts Firefox on a profile kept for this with %s \
         PORT, unless it runs already, then %s.%s%s"
        detail firefox_flag (run_host t ~address:None) (listed_beside t) (steps t)
  | Record.Unreadable { detail; held = None } ->
      Printf.sprintf
        "Whether a BiDi browser host runs for this workspace could not be checked (%s)." detail

type report =
  { state : Record.state
  ; attach : attach
  ; message : string
  }

let report observation =
  { state = observation.record
  ; attach = attach_for observation.lane
  ; message = message observation
  }

let state_name = function
  | Record.Never_started -> "never_started"
  | Record.Record_missing_but_locked -> "record_missing_but_locked"
  | Record.Running _ -> "running"
  | Record.Ended _ -> "ended"
  | Record.Died _ -> "died"
  | Record.Unreadable _ -> "unreadable"

let launcher_standing_to_wire = function
  | Launcher_installed -> "installed"
  | Launcher_not_installed -> "not_installed"
  | Launcher_needs_reinstall -> "needs_reinstall"

let launcher_standing_of_wire = function
  | "installed" -> Some Launcher_installed
  | "not_installed" -> Some Launcher_not_installed
  | "needs_reinstall" -> Some Launcher_needs_reinstall
  | _ -> None

let report_fields = [ "state"; "record"; "lock_held"; "detail"; "attach"; "message" ]
let attach_fields = [ "launcher"; "arguments"; "launcher_state" ]

(* The state is written as what it was read from: the record and whether
   the lock was held. [lock_held] is null where the state does not turn on
   it, and for a lock that could not be asked. *)
let report_to_json { state; attach; message } =
  let entry_json = Record.entry_to_json in
  let record, lock_held, detail =
    match state with
    | Record.Never_started -> `Null, `Bool false, `Null
    | Record.Record_missing_but_locked -> `Null, `Bool true, `Null
    | Record.Running entry -> entry_json entry, `Bool true, `Null
    | Record.Ended (entry, ending) ->
        entry_json { entry with ended = Some ending }, `Null, `Null
    | Record.Died entry -> entry_json entry, `Bool false, `Null
    | Record.Unreadable { detail; held } ->
        `Null, Option.fold ~none:`Null ~some:(fun held -> `Bool held) held, `String detail
  in
  `Assoc
    [ "state", `String (state_name state)
    ; "record", record
    ; "lock_held", lock_held
    ; "detail", detail
    ; ( "attach"
      , `Assoc
          [ "launcher", `String attach.launcher
          ; "arguments", `String attach.arguments
          ; "launcher_state", `String (launcher_standing_to_wire attach.standing)
          ] )
    ; "message", `String message
    ]

let to_json observation = report_to_json (report observation)

let summary_to_json observation =
  `Assoc
    [ "state", `String (state_name observation.record)
    ; "message", `String (message observation)
    ]

let report_of_json json =
  let ( let* ) = Result.bind in
  (* Exactly the fields the writer writes: one more, one fewer or one twice
     is another layout, and is refused rather than read around. *)
  let exactly ~what ~names = function
    | `Assoc fields ->
        if List.equal String.equal
             (List.sort String.compare names)
             (List.sort String.compare (List.map fst fields))
        then Ok fields
        else Error (what ^ " does not have exactly the fields this reader knows")
    | _ -> Error (what ^ " is not an object")
  in
  let text fields name =
    match List.assoc name fields with
    | `String text -> Ok text
    | _ -> Error ("the BiDi host report's " ^ name ^ " is not a string")
  in
  let* fields = exactly ~what:"the BiDi host report" ~names:report_fields json in
  let* name = text fields "state" in
  let* record =
    match List.assoc "record" fields with
    | `Null -> Ok None
    | record -> Result.map Option.some (Record.entry_of_json record)
  in
  let* lock_held =
    match List.assoc "lock_held" fields with
    | `Null -> Ok None
    | `Bool held -> Ok (Some held)
    | _ -> Error "the BiDi host report's lock_held is neither true, false nor null"
  in
  let* detail =
    match List.assoc "detail" fields with
    | `Null -> Ok None
    | `String detail -> Ok (Some detail)
    | _ -> Error "the BiDi host report's detail is neither a string nor null"
  in
  (* The state is worked out again from what it was read from, by the rule
     the record's own reader uses, and has to be the one the report names. *)
  let* state =
    match record, detail, lock_held with
    | None, Some detail, held -> Ok (Record.Unreadable { detail; held })
    | Some _, Some _, (Some _ | None) ->
        Error "the BiDi host report has a record and a reason it cannot be read"
    | None, None, Some lock_held -> Ok (Record.state_of ~lock_held (Ok None))
    | None, None, None -> Error "the BiDi host report does not say whether the lock is held"
    | Some ({ ended = Some _; _ } as entry), None, None ->
        Ok (Record.state_of ~lock_held:false (Ok (Some entry)))
    | Some { ended = Some _; _ }, None, Some _ ->
        Error "the BiDi host report says of a lock beside a record that has its ending"
    | Some ({ ended = None; _ } as entry), None, Some lock_held ->
        Ok (Record.state_of ~lock_held (Ok (Some entry)))
    | Some { ended = None; _ }, None, None ->
        Error "the BiDi host report does not say whether the host's lock is held"
  in
  let* () =
    if String.equal (state_name state) name
    then Ok ()
    else Error "the BiDi host report names a state its record and lock do not make"
  in
  let* attach =
    let* attach =
      exactly ~what:"the BiDi host report's attach" ~names:attach_fields (List.assoc "attach" fields)
    in
    let* launcher = text attach "launcher" in
    let* arguments = text attach "arguments" in
    let* standing =
      let* raw = text attach "launcher_state" in
      Option.to_result
        ~none:"the BiDi host report names a launcher state this reader does not know"
        (launcher_standing_of_wire raw)
    in
    Ok { launcher; arguments; standing }
  in
  let* message = text fields "message" in
  Ok { state; attach; message }
