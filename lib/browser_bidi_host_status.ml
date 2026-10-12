module Launcher = Browser_lane_launcher
module Record = Browser_bidi_host_record
module Start_record = Browser_keeper_firefox_start_record
module Starter = Browser_keeper_firefox_starter

type keeper =
  | Masc_starts of { port : int; profile : string; last_start : Start_record.read }
  | Lane_off
  | Not_configured
  | Not_known

(* The live lane being off is said first, table or not: nothing starts
   either way. *)
let keeper_of_configuration ~base_path = function
  | Some { Browser_configuration.live_enabled = false; _ } -> Lane_off
  | Some { Browser_configuration.live_bidi = Some config; live_enabled = true; _ } ->
      Masc_starts { port = config.port; profile = config.profile; last_start = Start_record.read ~base_path }
  | Some { Browser_configuration.live_bidi = None; live_enabled = true; _ } -> Not_configured
  | None -> Not_known

type observation = { lane : Launcher.t; record : Record.state; keeper : keeper }

(* Reading the records and the launcher's files can let other fibers run.
   The server is asked after them, so its connection list is the newest
   thing in the observation: a host that attached during the reads is in
   it. *)
let observe ~base_path ~configuration =
  let record = Record.observe ~base_path in
  let keeper = keeper_of_configuration ~base_path configuration in
  let lane = Launcher.observe ~base_path ~server:Launcher.Not_serving in
  { lane = { lane with server = Launcher.current_server () }; record; keeper }

let without_last_start observation =
  match observation.keeper with
  | Masc_starts started -> { observation with keeper = Masc_starts { started with last_start = Start_record.Absent } }
  | Lane_off | Not_configured | Not_known -> observation

(* A process that bound no listener was not asked for its connections, so
   they are listed here: once, either way. *)
let listed_clients { lane; _ } =
  match lane.server with
  | Launcher.Serving { polling; _ } -> polling
  | Launcher.Not_serving -> Browser_lane.active_clients ()

type launcher_standing = Launcher_installed | Launcher_not_installed | Launcher_needs_reinstall

type attach = { launcher : string; arguments : string; standing : launcher_standing }

(* What the launcher is given to attach to a Firefox the operator started
   with [firefox_flag PORT]. *)
let bidi_url_flag = "--bidi-url"
let firefox_profile_flag = "--firefox-profile"
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

let verdict { lane; record; _ } =
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

(* Count the actual decoded record, including a longer record from another
   writer or an archive failure. A count alone cannot prove archival. *)
let unacknowledged (t : Launcher.t) (entry : Record.entry) =
  let listed what each trim =
    Printf.sprintf
      " Its record, %s, lists %s the host holds no acknowledgement for, and %swhether the server \
       refused it, the host could not send it, or no acknowledgement came.%s"
      (Record.record_path ~base_path:t.base_path)
      what each trim
  in
  match List.length entry.unacknowledged with
  | 0 -> ""
  | 1 -> listed "one result" "" ""
  | count ->
      let trim =
        if count < Record.unacknowledged_limit then ""
        else
          let window =
            if count = Record.unacknowledged_limit then
              Printf.sprintf " The record is at the %d-result snapshot window; it may omit older results."
                Record.unacknowledged_limit
            else
              Printf.sprintf " All %d listed results remain in the record, exceeding the %d-result snapshot window."
                count Record.unacknowledged_limit
          in
          window ^ Printf.sprintf
            " Archived result metadata is read from %s; this count does not establish whether archival succeeded or how many earlier results exist."
            (Record.unacknowledged_archive_path ~base_path:t.base_path)
      in
      listed (Printf.sprintf "%d results" count) "for each " trim

(* What the operator does once another Firefox holds the port a host was
   given: the host ends a session on any other profile, so a Firefox on the
   one kept for this cannot open that port until the other is closed. A host
   given that profile is the one MASC starts for [browser.live.bidi]. *)
let other_firefox_there t (entry : Record.entry) ~expected ~found =
  let holder =
    match found with
    | Some found ->
        Printf.sprintf
          " The Firefox at that address runs the profile %s, and this host keeps a session only \
           with a Firefox on %s, so it did not keep one there. Another Firefox holds that port: \
           the operator quits it."
          found expected
    | None ->
        Printf.sprintf
          " The Firefox at that address did not say which profile it runs, and this host keeps a \
           session only with a Firefox on %s, so it did not keep one there. Unless that Firefox is \
           the one on %s, another Firefox holds that port, and the operator quits it."
          expected expected
  in
  holder
  ^ Printf.sprintf
      " Then a server start, or a Keeper's next hover or drag, starts the Keeper Firefox and its \
       host when runtime.toml has [browser.live.bidi] and [browser.live] is on; otherwise the \
       operator starts Firefox with %s, then %s %s %s."
      (firefox_at entry.bidi_url) (run_host t ~address:(Some entry.bidi_url)) firefox_profile_flag
      (Filename.quote expected)

(* What became of the last host's session decides what the operator does
   before the next one. A Firefox that holds a session refuses every host
   until that session's host ends it or the Firefox is restarted; one that
   holds none takes the next host as it is. A host that never got a session
   left none, and what kept it from one is still there for the next. A host
   that ended for a cause the next step turns on says that cause first. *)
let next_host t (entry : Record.entry) (ending : Record.ending) =
  let run = run_host t ~address:(Some entry.bidi_url) in
  let firefox = firefox_at entry.bidi_url in
  match ending.because with
  | Record.Profile_not_kept { expected; found } -> other_firefox_there t entry ~expected ~found
  | Record.Reason_only ->
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

(* The paragraph for a workspace whose operator starts Firefox and the host. *)
let by_operator t record =
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
         stops it, the next host keeps a copy of a record it read and cannot load beside it and \
         writes a new one in its place. It does not start while the record cannot be read at \
         all, or a new one cannot be written."
        detail
  | Record.Unreadable { detail; held = Some false } ->
      Printf.sprintf
        "The BiDi browser host's record cannot be read (%s). No host holds this workspace's \
         lock, so none is running. The next host keeps a copy of a record it read and cannot \
         load beside it and writes a new one in its place. It does not start while the record \
         cannot be read at all, or a new one cannot be written. The operator starts Firefox on a \
         profile kept for this with %s PORT, unless it runs already, then %s.%s%s"
        detail firefox_flag (run_host t ~address:None) (listed_beside t) (steps t)
  | Record.Unreadable { detail; held = None } ->
      Printf.sprintf
        "Whether a BiDi browser host runs for this workspace could not be checked (%s)." detail

(* When MASC's next start comes, where it starts them: at every server
   start, and for every hover or drag a Keeper asks for that no listed
   connection serves (RFC-browser-keeper-firefox §3.5). *)
let next_start = "at the next server start, or when a Keeper next asks for hover or drag"

(* MASC starts what is not running: the host alone for a port that
   already answers. A launcher that is not there yet is installed first, as
   {!steps} says. *)
let masc_starts t ~port ~profile =
  let starts =
    Printf.sprintf
      "MASC starts what is not running of the Keeper Firefox on port %d with the profile %s and its \
       host, %s"
      port profile next_start
  in
  match (attach_for t).standing with
  | Launcher_installed -> starts
  | Launcher_not_installed | Launcher_needs_reinstall -> "Once the browser lane is installed, " ^ starts

(* MASC restarts only the Keeper Firefox it is shown to have started
   (§3.5.4). *)
let masc_restarts =
  Printf.sprintf
    "%s, MASC restarts the Keeper Firefox it started there, or starts it if it was closed, and starts \
     its host; a Firefox MASC is not shown to have started, the operator quits first"
    (String.capitalize_ascii next_start)

let refused_then_restarted =
  "when Firefox refuses that host a session, the start after it restarts the Keeper Firefox \
   MASC is shown to have started"

(* What the host record says since: an ended host's end, a dead or running
   host's attach (its start, when it never attached). *)
let since_of = function
  | Record.Never_started | Record.Record_missing_but_locked | Record.Unreadable _ -> None
  | Record.Ended (_, ending) -> Some ending.at
  | Record.Died entry | Record.Running entry ->
      Some (Option.value entry.attached_at ~default:entry.started_at)

type last_start_note =
  | No_note
  | Failed_start of { at : float; not_attached : Starter.not_attached }
  | Start_record_unreadable of string

(* A start for another port or profile says nothing of this configuration,
   and one that ended before what the record says since nothing of it. *)
let last_start_note keeper state =
  match keeper with
  | Lane_off | Not_configured | Not_known -> No_note
  | Masc_starts { port; profile; last_start } ->
      (match last_start with
       | Start_record.Absent | Start_record.Recorded { outcome = Start_record.Attached _; _ } ->
           No_note
       | Start_record.Unreadable detail -> Start_record_unreadable detail
       | Start_record.Recorded ({ at; outcome = Start_record.Not_attached not_attached; _ } as entry) ->
           let older = match since_of state with Some after -> at < after | None -> false in
           if older || not (Start_record.for_configuration ~port ~profile entry) then No_note
           else Failed_start { at; not_attached })

let last_start_sentence ~base_path = function
  | No_note -> ""
  | Start_record_unreadable detail ->
      Printf.sprintf " The record of MASC's last start, %s, cannot be read (%s)."
        (Start_record.record_path ~base_path) detail
  | Failed_start { at = ended; not_attached } ->
      let sentence why = if String.ends_with ~suffix:"." why then why else why ^ "." in
      (match not_attached with
       | Starter.Operator_needed why ->
           Printf.sprintf " MASC's last start, at %s, waits for the operator: %s" (at ended) (sentence why)
       | Starter.Start_failed why ->
           Printf.sprintf " MASC's last start, at %s, failed: %s The next start tries again." (at ended)
             (sentence why)
       | Starter.Not_listed_in_time why ->
           Printf.sprintf " MASC's last start, at %s, showed no connection in time: %s" (at ended)
             (sentence why))

let recorded_on_port (entry : Record.entry) ~port =
  match Browser_bidi_downloads.endpoint entry.bidi_url with
  | Ok (_, recorded_port, _) -> recorded_port = port
  | Error _ -> false

(* What comes before the next host where MASC starts it, by what became of
   the last host's session, as {!next_host} says for the operator. A session
   held in a Firefox on another port than the configured one is not MASC's
   to restart: it starts its own on its port. *)
let next_host_by_masc t (entry : Record.entry) (ending : Record.ending) ~port ~profile =
  let starts = masc_starts t ~port ~profile in
  let held_there = if recorded_on_port entry ~port then masc_restarts else starts in
  match ending.because with
  | Record.Profile_not_kept { expected; found } -> other_firefox_there t entry ~expected ~found
  | Record.Reason_only ->
  match entry.attached_at, ending.session with
  | Some _, No_session_left ->
      Printf.sprintf " It ended its BiDi session, so the Firefox at that address takes the next host. %s."
        starts
  | None, No_session_left ->
      Printf.sprintf " It ended before Firefox gave it a session and left none there. %s." starts
  | (Some _ | None), Session_left ->
      Printf.sprintf
        " Firefox did not confirm that its BiDi session ended, and while it holds that session it \
         refuses the next host. %s."
        held_there
  | (Some _ | None), Session_refused ->
      Printf.sprintf
        " Firefox refused it a BiDi session, which it does while it holds one: that of a host \
         attached from another workspace, or one a host that died left there. %s."
        held_there
  | (Some _ | None), Session_unknown ->
      Printf.sprintf
        " Its connection to Firefox was gone before it could end its BiDi session. A Firefox that \
         exited took the session along; one that still runs holds it. %s; %s."
        starts refused_then_restarted

(* The paragraph for a workspace where MASC starts Firefox and the host:
   the operator's steps give way to what MASC's next start does. A last
   start is said beside what the record says since: since a host ended, or
   a dead or running host attached (or started, when it never attached). *)
let by_masc t record ~port ~profile ~last_start =
  let last =
    last_start_sentence ~base_path:t.Launcher.base_path
      (last_start_note (Masc_starts { port; profile; last_start }) record) in
  let starts = masc_starts t ~port ~profile in
  match record with
  | Record.Never_started ->
      Printf.sprintf
        "No BiDi browser host has run for this workspace. Hover and drag on the live lane need \
         one. %s.%s%s%s"
        starts last (listed_beside t) (steps t)
  | Record.Ended (entry, ending) ->
      Printf.sprintf
        "No BiDi browser host is running. The last one (pid %d, given %s) ended at %s with this \
         reason: %s.%s%s%s%s%s"
        entry.pid entry.bidi_url (at ending.at) (quoted ending.reason)
        (unacknowledged t entry) (next_host_by_masc t entry ending ~port ~profile)
        last (listed_beside t) (steps t)
  | Record.Died entry ->
      Printf.sprintf
        "No BiDi browser host is running. The last one (pid %d, given %s, started at %s) left no \
         reason for ending: it was killed or crashed, or could not write one.%s Its BiDi session \
         may be left in the Firefox at that address. %s; %s.%s%s%s"
        entry.pid entry.bidi_url (at entry.started_at) (unacknowledged t entry) starts
        refused_then_restarted
        last (listed_beside t) (steps t)
  | Record.Unreadable { detail; held = Some false } ->
      Printf.sprintf
        "The BiDi browser host's record cannot be read (%s). No host holds this workspace's \
         lock, so none is running. The next host keeps a copy of a record it read and cannot \
         load beside it and writes a new one in its place. It does not start while the record \
         cannot be read at all, or a new one cannot be written. %s.%s%s%s"
        detail starts last (listed_beside t) (steps t)
  | Record.Running _ -> by_operator t record ^ last
  | Record.Record_missing_but_locked | Record.Unreadable { held = Some true | None; _ } ->
      by_operator t record ^ last

(* Where the operator starts them, the paragraph says how they are started
   for a workspace with no table: by the table. *)
let unless_configured = function
  | Record.Never_started | Record.Ended _ | Record.Died _ | Record.Unreadable { held = Some false; _ } ->
      " With [browser.live.bidi] in runtime.toml, MASC starts that Firefox and its host itself."
  | Record.Record_missing_but_locked | Record.Running _
  | Record.Unreadable { held = Some true | None; _ } -> ""

let message { lane = t; record; keeper } =
  match keeper with
  | Masc_starts { port; profile; last_start } -> by_masc t record ~port ~profile ~last_start
  | Lane_off ->
      "[browser.live] is off in runtime.toml, so the live lane serves nothing, and MASC starts no \
       Firefox or host. "
      ^ by_operator t record
  | Not_configured -> by_operator t record ^ unless_configured record
  | Not_known -> by_operator t record

type report =
  { state : Record.state
  ; attach : attach
  ; keeper : keeper
  ; message : string
  }

let report observation =
  { state = observation.record
  ; attach = attach_for observation.lane
  ; keeper = observation.keeper
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

let report_fields = [ "state"; "record"; "lock_held"; "detail"; "attach"; "keeper"; "message" ]

let keeper_to_json = function
  | Masc_starts { port; profile; last_start } ->
      `Assoc
        [ "kind", `String "masc_starts"; "port", `Int port; "profile", `String profile
        ; ( "last_start"
          , match last_start with
            | Start_record.Absent -> `Assoc [ "kind", `String "absent" ]
            | Start_record.Recorded entry ->
                `Assoc [ "kind", `String "recorded"; "entry", Start_record.entry_to_json entry ]
            | Start_record.Unreadable detail ->
                `Assoc [ "kind", `String "unreadable"; "detail", `String detail ] ) ]
  | Lane_off -> `Assoc [ "kind", `String "lane_off" ]
  | Not_configured -> `Assoc [ "kind", `String "not_configured" ]
  | Not_known -> `Assoc [ "kind", `String "not_known" ]
let attach_fields = [ "launcher"; "arguments"; "launcher_state" ]

(* The state is written as what it was read from: the record and whether
   the lock was held. [lock_held] is null where the state does not turn on
   it, and for a lock that could not be asked. *)
let report_to_json { state; attach; keeper; message } =
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
    ; "keeper", keeper_to_json keeper
    ; "message", `String message
    ]

let to_json observation = report_to_json (report observation)

let summary_to_json observation =
  `Assoc
    [ "state", `String (state_name observation.record)
    ; "message", `String (message observation)
    ]

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

(* Text a reader draws on a terminal holds no control character. *)
let drawable text =
  String.for_all (fun ch -> let code = Char.code ch in code >= 0x20 && code <> 0x7f) text

let drawable_text ~what fields name =
  match List.assoc name fields with
  | `String text when drawable text -> Ok text
  | `String _ -> Error (what ^ "'s " ^ name ^ " contains a control character")
  | _ -> Error (what ^ "'s " ^ name ^ " is not a string")

let kind_of ~what = function
  | `Assoc fields ->
      (match List.assoc_opt "kind" fields with
       | Some (`String kind) -> Ok kind
       | Some _ | None -> Error (what ^ " does not name its kind"))
  | _ -> Error (what ^ " is not an object")

let last_start_of_json json =
  let ( let* ) = Result.bind in
  let what = "the BiDi host report's last start" in
  let* kind = kind_of ~what json in
  match kind with
  | "absent" -> Result.map (fun _ -> Start_record.Absent) (exactly ~what ~names:[ "kind" ] json)
  | "recorded" ->
      let* fields = exactly ~what ~names:[ "kind"; "entry" ] json in
      Result.map
        (fun entry -> Start_record.Recorded entry)
        (Start_record.entry_of_json (List.assoc "entry" fields))
  | "unreadable" ->
      let* fields = exactly ~what ~names:[ "kind"; "detail" ] json in
      Result.map
        (fun detail -> Start_record.Unreadable detail)
        (drawable_text ~what fields "detail")
  | _ -> Error (what ^ " is of a kind this reader does not know")

let keeper_of_json json =
  let ( let* ) = Result.bind in
  let what = "the BiDi host report's keeper" in
  let only keeper = Result.map (fun _ -> keeper) (exactly ~what ~names:[ "kind" ] json) in
  let* kind = kind_of ~what json in
  match kind with
  | "masc_starts" ->
      let* fields = exactly ~what ~names:[ "kind"; "port"; "profile"; "last_start" ] json in
      let* port =
        match List.assoc "port" fields with
        | `Int port when port > 0 && port < 65536 -> Ok port
        | _ -> Error (what ^ "'s port is not a port")
      in
      let* profile = drawable_text ~what fields "profile" in
      let* last_start = last_start_of_json (List.assoc "last_start" fields) in
      Ok (Masc_starts { port; profile; last_start })
  | "lane_off" -> only Lane_off
  | "not_configured" -> only Not_configured
  | "not_known" -> only Not_known
  | _ -> Error (what ^ " is of a kind this reader does not know")

let report_of_json json =
  let ( let* ) = Result.bind in
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
    let* () =
      if String.trim launcher <> "" then Ok ()
      else Error "the BiDi host report's launcher is empty"
    in
    let* arguments = text attach "arguments" in
    let* () =
      if String.equal arguments host_arguments then Ok ()
      else Error "the BiDi host report's attach arguments are not the launcher's arguments"
    in
    let* standing =
      let* raw = text attach "launcher_state" in
      Option.to_result
        ~none:"the BiDi host report names a launcher state this reader does not know"
        (launcher_standing_of_wire raw)
    in
    Ok { launcher; arguments; standing }
  in
  let* keeper = keeper_of_json (List.assoc "keeper" fields) in
  let* message = drawable_text ~what:"the BiDi host report" fields "message" in
  Ok { state; attach; keeper; message }
