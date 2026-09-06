(** Browser_lane — the in-process state of the masc ↔ browser lanes
    (docs/design/browser-lane.md, task-1382).

    A lane is one connected browser backend: "live" is the user's real
    Firefox/Zen through the extension's native-messaging host, "automation"
    is the Playwright daemon. Backends long-poll this process for commands
    over HTTP ([Server_routes_http_routes_browser_lane]) and post results
    back; keeper tools issue verbs and await the answer.

    Verbs are a closed variant: an unknown verb is refused by name on every
    boundary (tool input, lane issue, backend), the same rule the observe
    gate learned the hard way (#33638). *)

open Time_compat

type verb =
  | Tabs_list
  | Page_read of { tab_id : int option; max_chars : int option }
  | Session_open of { headless : bool option }
  | Session_close
  | Page_goto of { url : string }

let verb_to_string = function
  | Tabs_list -> "tabs.list"
  | Page_read _ -> "page.read"
  | Session_open _ -> "session.open"
  | Session_close -> "session.close"
  | Page_goto _ -> "page.goto"
;;

(* The wire carries a verb name plus args; the closed variant is the only
   thing that crosses a boundary. *)
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
  | Session_open { headless } ->
    `Assoc
      [ ("verb", `String "session.open")
      ; ( "args"
        , `Assoc (Option.map (fun v -> ("headless", `Bool v)) headless |> Option.to_list) )
      ]
  | Session_close -> `Assoc [ ("verb", `String "session.close"); ("args", `Assoc []) ]
  | Page_goto { url } ->
    `Assoc [ ("verb", `String "page.goto"); ("args", `Assoc [ ("url", `String url) ]) ]
;;

(* Reads change nothing in the browser; a navigation can (a POST replayed in
   a logged-in session). The verb set is closed, so this classification is
   exhaustive by construction. *)
let verb_is_read = function
  | Tabs_list | Page_read _ | Session_open _ | Session_close -> true
  | Page_goto _ -> false
;;

type issued = { id : string; verb_json : Yojson.Safe.t }

type answer =
  | Answered of Yojson.Safe.t
  | Lane_absent
  | Timed_out

(* Two lanes by design — "live" (the user's browser via the extension host)
   and "automation" (the Playwright daemon). Anything else is refused. *)
let allowed_lane_names = [ "live"; "automation" ]

type lane =
  { name : string
  ; commands : issued Eio.Stream.t
  ; mutex : Eio.Mutex.t
  ; waiters : (string, Yojson.Safe.t Eio.Promise.t * Yojson.Safe.t Eio.Promise.u) Hashtbl.t
  ; mutable last_seen : float
  }

let lanes : (string, lane) Hashtbl.t = Hashtbl.create 4
let lanes_mutex = Eio.Mutex.create ()

let lane_named ~name =
  Eio.Mutex.use_rw ~protect:true lanes_mutex (fun () ->
      match Hashtbl.find_opt lanes name with
      | Some lane -> Some lane
      | None ->
        if not (List.mem name allowed_lane_names) then None
        else
          let lane =
            { name
            ; commands = Eio.Stream.create 16
            ; mutex = Eio.Mutex.create ()
            ; waiters = Hashtbl.create 8
            ; last_seen = 0.
            }
          in
          Hashtbl.replace lanes name lane;
          Some lane)
;;

(* The poll side: carry one command to the browser, or [None] after the
   window — the host loops and polls again. *)
let take_command ~lane_name ~window_sec =
  match lane_named ~name:lane_name with
  | None -> Error "unknown_lane"
  | Some lane ->
    lane.last_seen <- Unix.gettimeofday ();
    Ok
      (Eio.Fiber.first
         (fun () -> Some (Eio.Stream.take lane.commands))
         (fun () ->
            Time_compat.sleep window_sec;
            None))
;;

(* The result side: resolve the tool call waiting on this id. *)
let deliver_result ~lane_name ~id ~payload =
  match Hashtbl.find_opt lanes lane_name with
  | None -> Error "unknown_lane"
  | Some lane ->
    let waiter =
      Eio.Mutex.use_rw ~protect:true lane.mutex (fun () ->
          match Hashtbl.find_opt lane.waiters id with
          | Some promise ->
            Hashtbl.remove lane.waiters id;
            Some promise
          | None -> None)
    in
    (match waiter with
    | Some (_, resolver) -> Eio.Promise.resolve resolver payload
    | None -> ());
    Ok ()
;;

let unregister_waiter lane id =
  Eio.Mutex.use_rw ~protect:true lane.mutex (fun () ->
      Hashtbl.remove lane.waiters id)
;;

(* The tool side: issue one verb and await its answer, bounded by the
   timeout. A lane that has never polled does not exist yet and the call
   says so instead of timing out into silence. *)
let lane_connected ~lane_name =
  match Hashtbl.find_opt lanes lane_name with
  | Some lane -> Unix.gettimeofday () -. lane.last_seen < 120.
  | None -> false
;;

let issue ~lane_name ~verb:v ~timeout_sec =
  match Hashtbl.find_opt lanes lane_name with
  | Some lane when not (lane_connected ~lane_name) -> Lane_absent
  | None -> Lane_absent
  | Some lane ->
    let id =
      Printf.sprintf "bl%d-%06d" (Unix.time () |> int_of_float) (Random.int 1_000_000)
    in
    let promise, resolver = Eio.Promise.create () in
    Eio.Mutex.use_rw ~protect:true lane.mutex (fun () ->
        Hashtbl.replace lane.waiters id (promise, resolver));
    Eio.Stream.add lane.commands { id; verb_json = verb_json v };
    let outcome =
      Eio.Fiber.first
        (fun () -> Answered (Eio.Promise.await promise))
        (fun () ->
           Time_compat.sleep timeout_sec;
           Timed_out)
    in
    unregister_waiter lane id;
    outcome
;;
