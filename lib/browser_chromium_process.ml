(* HIGH-RISK-UNREVIEWED: the flags that open Chromium's DevTools socket to
   extension loading and name the one origin allowed on it
   (RFC-browser-lane-stagehand §4). *)
let profile_flag profile = "--user-data-dir=" ^ profile

type profile = Private_profile of string | Operator_profile of string

let profile_path = function Private_profile path | Operator_profile path -> path

(* The official Stagehand launcher's defaults that change behaviour here.
   An occluded window or a background tab slows its timers, which stretches
   Stagehand's wait for the DOM to settle. *)
let background_flags =
  [ "--disable-background-timer-throttling"
  ; "--disable-renderer-backgrounding"
  ; "--disable-backgrounding-occluded-windows"
  ]
;;

(* A fresh private profile would ask macOS for Keychain access on first use,
   and nobody is there to answer. An operator's profile keeps its own store:
   these flags would leave its saved logins unreadable. *)
let keychain_flags = function
  | Private_profile _ -> [ "--use-mock-keychain"; "--password-store=basic" ]
  | Operator_profile _ -> []
;;

(* The window size a headless page renders at; the Stagehand SDK launches with
   the same size, so pages lay out the way its prompts were tuned for. *)
let window_size = "--window-size=1280,800"

let argv ~chrome ~profile ~extension_id ~headless =
  [ chrome ]
  @ (if headless then [ "--headless=new" ] else [])
  @ background_flags
  @ keychain_flags profile
  @ [ "--remote-debugging-port=0"
    ; profile_flag (profile_path profile)
    ; "--enable-unsafe-extension-debugging"
    ; "--remote-allow-origins=chrome-extension://" ^ extension_id
    ; "--no-first-run"
    ; "--no-default-browser-check"
    ; window_size
    ; "about:blank"
    ]
;;

let devtools_port_file = "DevToolsActivePort"

let devtools_endpoint_of_string text =
  match String.split_on_char '\n' (String.trim text) with
  | port :: path :: _ ->
    (match int_of_string_opt (String.trim port) with
     | Some port when port > 0 && port <= 65535 ->
       let path = String.trim path in
       if String.length path > 0 && path.[0] = '/' then Ok (port, path)
       else Error "DevToolsActivePort has no websocket path"
     | Some _ | None -> Error "DevToolsActivePort has no port")
  | [ _ ] | [] -> Error "DevToolsActivePort needs a port line and a path line"
;;

let browser_ws_url ~port ~path =
  Printf.sprintf "ws://%s:%d%s" Masc_network_defaults.masc_http_loopback_peer port path
;;
