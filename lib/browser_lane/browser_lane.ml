(** Browser_lane — the in-process state of the masc ↔ browser lanes
    (docs/design/browser-lane.md, task-1382).

    A lane is one connected browser backend: "live" is the user's real
    Firefox/Zen through the extension's native-messaging host. "automation"
    is the in-process OCaml WebDriver executor. Only the live host long-polls
    this process and posts results through the HTTP transport; automation
    owns its session directly inside the server.

    Verbs are a closed variant: an unknown verb is refused by name on every
    boundary (tool input, lane issue, backend), the same rule the observe
    gate learned the hard way (#33638). *)

open Time_compat
module Action = Browser_action
module Upload_lease = Browser_upload_lease

type node_ref = { document_id : string; node_id : string }
type interaction = Click of string | Fill of { selector : string; text : string }
  | Scroll of { x : int; y : int }
  | Click_node of node_ref | Fill_node of { target : node_ref; text : string }

type verb =
  | Tabs_list
  | Page_read of { tab_id : int option; max_chars : int option }
  | Page_downloads of { tab_id : int }
  | Page_capture of { tab_id : int }
  | Page_scene of { tab_id : int; max_chars : int }
  | Page_interact of { tab_id : int; expected_url : string option; action : interaction }
  | Session_open of { headless : bool option }
  | Session_close
  (* Reads the backend's own record of whether a session exists. It issues no
     browser request, so it answers while a session is closed -- which is the
     question a keeper has before deciding to open one. *)
  | Session_status
  | Page_goto of { url : string; tab_id : int option }
  | Page_elements of { tab_id : int option }
  | Page_act of Browser_action.t
  | Page_context of { tab_id : int; frame_path : string list; mode : [ `Text of int | `Elements | `Frames | `Dialog ] }

let verb_to_string = function
  | Tabs_list -> "tabs.list"
  | Page_read _ -> "page.read"
  | Page_downloads _ -> "page.downloads"
  | Page_capture _ -> "page.capture"
  | Page_scene _ -> "page.scene"
  | Page_interact _ -> "page.interact"
  | Session_open _ -> "session.open"
  | Session_close -> "session.close"
  | Session_status -> "session.status"
  | Page_goto _ -> "page.goto"
  | Page_elements _ -> "page.elements"
  | Page_act _ -> "page.act"
  | Page_context _ -> "page.context"
;;

(* The wire carries a verb name plus args; the closed variant is the only
   thing that crosses a boundary. *)
let interaction_args ~tab_id ~expected_url action =
  let node_fields target = ["documentId",`String target.document_id; "nodeId",`String target.node_id] in
  let fields = match action with
    | Click selector -> ["action", `String "click"; "selector", `String selector]
    | Fill {selector; text} -> ["action", `String "fill"; "selector", `String selector; "text", `String text]
    | Click_node target -> ("action",`String "click") :: node_fields target
    | Fill_node {target;text} -> ("action",`String "fill") :: ("text",`String text) :: node_fields target
    | Scroll {x; y} -> ["action", `String "scroll"; "x", `Int x; "y", `Int y] in
  `Assoc (("tabId", `Int tab_id) :: fields @
    (Option.map (fun url -> "expectedUrl", `String url) expected_url |> Option.to_list))

let verb_json = function
  | Tabs_list -> `Assoc [ ("verb", `String "tabs.list"); ("args", `Assoc []) ]
  | Page_read { tab_id; max_chars } ->
    `Assoc
      [ ("verb", `String "page.read")
      ; ( "args"
        , `Assoc
            ([ Option.map (fun v -> ("tabId", `Int v)) tab_id
             ; Option.map (fun v -> ("maxChars", `Int v)) max_chars
             ]
             |> List.filter_map Fun.id) )
      ]
  | Page_downloads {tab_id} ->
    `Assoc ["verb",`String "page.downloads";"args",`Assoc ["tabId",`Int tab_id]]
  | Page_scene {tab_id;max_chars} ->
    `Assoc ["verb",`String "page.scene";"args",`Assoc ["tabId",`Int tab_id;"maxChars",`Int max_chars]]
  | Page_capture { tab_id } ->
    `Assoc ["verb", `String "page.capture"; "args", `Assoc ["tabId", `Int tab_id]]
  | Page_interact { tab_id; expected_url; action } ->
    `Assoc ["verb", `String "page.interact"; "args", interaction_args ~tab_id ~expected_url action]
  | Session_open { headless } ->
    `Assoc
      [ ("verb", `String "session.open")
      ; ( "args"
        , `Assoc (Option.map (fun v -> ("headless", `Bool v)) headless |> Option.to_list) )
      ]
  | Session_close -> `Assoc [ ("verb", `String "session.close"); ("args", `Assoc []) ]
  | Session_status -> `Assoc [ ("verb", `String "session.status"); ("args", `Assoc []) ]
  | Page_goto { url; tab_id } ->
    `Assoc ["verb", `String "page.goto"; "args", `Assoc
      (["url", `String url] @ Option.to_list (Option.map (fun id -> "tabId", `Int id) tab_id))]
  | Page_elements { tab_id } ->
    `Assoc ["verb", `String "page.elements"; "args", `Assoc
      (Option.to_list (Option.map (fun id -> "tabId", `Int id) tab_id))]
  | Page_context {tab_id;frame_path;mode} ->
    let name, extra = match mode with
      | `Text cap -> "text", ["maxChars",`Int cap]
      | `Elements -> "elements", [] | `Frames -> "frames", [] | `Dialog -> "dialog", [] in
    `Assoc ["verb",`String "page.context";"args",`Assoc
      (["tabId",`Int tab_id;"framePath",`List (List.map (fun s -> `String s) frame_path);"mode",`String name] @ extra)]
  | Page_act action ->
    `Assoc ["verb", `String "page.act"; "args", Browser_action.to_json action]
;;

(* Two different questions, two different classifications, both exhaustive
   over the closed verb set:

   - [verb_is_read]: does this leave browser content and lifecycle unchanged?
     Interaction, navigation, and session changes are writes.
   - [verb_allowed_on_live]: may this run against the operator's browser?
     Readers and explicit-tab interactions are supported. Session ownership
     and direct navigation remain with the automation backend. *)
let verb_is_read = function
  | Tabs_list | Page_read _ | Page_elements _ | Page_capture _ | Page_scene _ | Page_context _ | Page_downloads _
  | Session_status -> true
  | Session_open _ | Session_close | Page_goto _ | Page_act _ | Page_interact _ -> false
;;

let verb_allowed_on_live = function
  | Page_context _ | Page_downloads _ -> false
  | Tabs_list | Page_read _ | Page_elements _ | Page_capture _ | Page_scene _ | Page_interact _ -> true
  (* The operator's browser owns itself, so it has no session to report on.
     Answering here would describe something the automation backend holds. *)
  | Session_open _ | Session_close | Session_status | Page_goto _ | Page_act _ -> false
;;

type issued = { id : string; verb_json : Yojson.Safe.t }

type answer =
  | Answered of Yojson.Safe.t
  | Lane_absent
  | Timed_out
  | Refused of string
  | Rejected_before_effect of string

(* The public source stays live/automation. Native-process identity owns each
   live command queue; browser-local tab IDs never select a different client. *)
let external_lane_name = "live"
type browser = Firefox | Zen
let browser_name = function Firefox -> "firefox" | Zen -> "zen"
let browser_of_string = function
  | "firefox" -> Ok Firefox | "zen" -> Ok Zen | _ -> Error "unsupported_browser"
type client_id = Uuidm.t
let client_id_to_string = Uuidm.to_string
let client_id_of_string value =
  match Uuidm.of_string value with
  | Some id when String.equal (Uuidm.to_string id) value -> Ok id
  | _ -> Error "invalid_client_id"
type client_info = { client_id : client_id; browser : browser; version : string; engine_version : string }
type client = { info : client_info; commands : issued Eio.Stream.t;
  mutex : Eio.Mutex.t;
  waiters : (string, Yojson.Safe.t Eio.Promise.u) Hashtbl.t;
  mutable connected_until : Monotonic_deadline.t; mutable closed : bool }
type target = Automation | Live_client of client
let clients : (string, client) Hashtbl.t = Hashtbl.create 4
let clients_mutex = Eio.Mutex.create ()
(* Retain only IDs after disconnect; queues and page payloads must be reclaimed. *)
let retired_clients : (string, unit) Hashtbl.t = Hashtbl.create 4
let command_uuid = Uuidm.v4_gen (Random.State.make_self_init ())
let lane_connected_window_sec = 120.
let connected client = not client.closed && not (Monotonic_deadline.passed client.connected_until)
let same_info left right = left.browser = right.browser
  && String.equal left.version right.version && String.equal left.engine_version right.engine_version
let retire_unlocked key client =
  client.closed <- true;
  Hashtbl.remove clients key;
  Hashtbl.replace retired_clients key ();
  Eio.Mutex.use_rw ~protect:true client.mutex (fun () ->
    Hashtbl.iter (fun _ resolver -> Eio.Promise.resolve resolver
      (`Assoc ["ok", `Bool false; "error", `String "client_disconnected"])) client.waiters;
    Hashtbl.clear client.waiters);
  while Option.is_some (Eio.Stream.take_nonblocking client.commands) do () done
let prune_unlocked () =
  Hashtbl.fold (fun key client acc -> if connected client then acc else (key,client)::acc) clients []
  |> List.iter (fun (key,client) -> retire_unlocked key client)
let active_clients () =
  Eio.Mutex.use_rw ~protect:true clients_mutex (fun () ->
    prune_unlocked ();
    Hashtbl.fold (fun _ client acc -> client.info :: acc) clients [])
  |> List.sort (fun left right -> String.compare
       (client_id_to_string left.client_id) (client_id_to_string right.client_id))
let client_json info = `Assoc ["clientId", `String (client_id_to_string info.client_id);
  "browser", `String (browser_name info.browser); "version", `String info.version;
  "engineVersion", `String info.engine_version]
let target_client_id = function Automation -> None | Live_client client -> Some client.info.client_id
let resolve_target ~lane_name ~client_id =
  match lane_name, client_id with
  | "automation", None -> Ok Automation
  | "automation", Some _ -> Error "client_id_requires_live"
  | "live", selected ->
    Eio.Mutex.use_rw ~protect:true clients_mutex (fun () ->
      prune_unlocked ();
      match selected with
      | Some id ->
        (match Hashtbl.find_opt clients (client_id_to_string id) with
         | Some client when connected client -> Ok (Live_client client)
         | Some _ | None -> Error "client_not_connected")
      | None ->
        match Hashtbl.fold (fun _ client acc -> if connected client then client :: acc else acc) clients [] with
        | [client] -> Ok (Live_client client)
        | [] -> Error "client_not_connected"
        | _ :: _ -> Error "ambiguous_browser_clients")
  | _ -> Error "unknown_lane"
let register info =
  Eio.Mutex.use_rw ~protect:true clients_mutex (fun () ->
    prune_unlocked ();
    let key = client_id_to_string info.client_id in
    if Hashtbl.mem retired_clients key then Error "client_disconnected"
    else match Hashtbl.find_opt clients key with
    | Some client when client.closed -> Error "client_disconnected"
    | Some client when not (same_info client.info info) -> Error "client_identity_changed"
    | Some client ->
      client.connected_until <- Monotonic_deadline.after ~seconds:lane_connected_window_sec;
      Ok client
    | None ->
      let client = {info; commands=Eio.Stream.create 16; mutex=Eio.Mutex.create ();
        waiters=Hashtbl.create 8; closed=false;
        connected_until=Monotonic_deadline.after ~seconds:lane_connected_window_sec} in
      Hashtbl.add clients key client; Ok client)
let take_command ~client_info ~window_sec =
  match register client_info with
  | Error _ as error -> error
  | Ok client ->
    let rec take () =
      let issued = Eio.Stream.take client.commands in
      if not (connected client) then None
      else if Eio.Mutex.use_ro client.mutex (fun () -> Hashtbl.mem client.waiters issued.id)
      then Some issued else take () in
    Ok (Eio.Fiber.first take (fun () -> Time_compat.sleep window_sec; None))
let deliver_result ~client_id ~id ~payload =
  match Eio.Mutex.use_ro clients_mutex (fun () ->
    Hashtbl.find_opt clients (client_id_to_string client_id)) with
  | None -> Error "unknown_client"
  | Some client when not (connected client) -> Error "client_not_connected"
  | Some client ->
    let waiter = Eio.Mutex.use_rw ~protect:true client.mutex (fun () ->
      let found = Hashtbl.find_opt client.waiters id in
      Hashtbl.remove client.waiters id; found) in
    match waiter with
    | None -> Error "request_not_owned_by_client"
    | Some resolver -> Eio.Promise.resolve resolver payload; Ok ()
let disconnect_client ~client_id =
  Eio.Mutex.use_rw ~protect:true clients_mutex (fun () ->
    let key = client_id_to_string client_id in
    match Hashtbl.find_opt clients key with
    | None when Hashtbl.mem retired_clients key -> Ok ()
    | None -> Error "unknown_client"
    | Some client -> retire_unlocked key client; Ok ())
let issue_live client ~verb ~timeout_sec =
  if not (connected client) then Refused "client_not_connected"
  else if not (verb_allowed_on_live verb) then
    Refused "session ownership and direct navigation belong to the automation lane"
  else
    Eio.Switch.run (fun sw ->
      let id = Uuidm.to_string (command_uuid ()) in
      let promise, resolver = Eio.Promise.create () in
      Eio.Mutex.use_rw ~protect:true client.mutex (fun () -> Hashtbl.add client.waiters id resolver);
      Eio.Switch.on_release sw (fun () ->
        Eio.Mutex.use_rw ~protect:true client.mutex (fun () -> Hashtbl.remove client.waiters id));
      Eio.Fiber.first
        (fun () -> Eio.Stream.add client.commands {id; verb_json=verb_json verb};
          Answered (Eio.Promise.await promise))
        (fun () -> Time_compat.sleep timeout_sec; Timed_out))
let automation_executor : (verb -> answer) option Atomic.t = Atomic.make None
let install_automation_executor executor = Atomic.set automation_executor executor
let issue_for ~target ~verb ~timeout_sec =
  match target with
  | Live_client client -> issue_live client ~verb ~timeout_sec
  | Automation ->
    match Atomic.get automation_executor with
    | None -> Lane_absent
    | Some execute -> Eio.Fiber.first (fun () -> execute verb)
        (fun () -> Time_compat.sleep timeout_sec; Timed_out)
let issue ~lane_name ~verb ~timeout_sec =
  match resolve_target ~lane_name ~client_id:None with
  | Error error -> Refused error
  | Ok target -> issue_for ~target ~verb ~timeout_sec
