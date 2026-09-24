(* HIGH-RISK-UNREVIEWED: the flags that open Chromium's DevTools socket to
   extension loading and name the one origin allowed on it
   (RFC-browser-lane-stagehand §4). *)
type owner = { pid : int; chrome : string; profile : string }
type leftover = Stop_recorded_browser of int | Not_the_recorded_browser

let lane_dir ~masc_root = Filename.concat masc_root "browser-lane"
let owner_record_path ~masc_root = Filename.concat (lane_dir ~masc_root) "stagehand-owner.json"
let server_profile ~masc_root = Filename.concat (lane_dir ~masc_root) "stagehand-profile"

let owner_to_string { pid; chrome; profile } =
  Yojson.Safe.to_string (`Assoc [ "pid", `Int pid; "chrome", `String chrome; "profile", `String profile ])
;;

let owner_of_string text =
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error detail -> Error detail
  | `Assoc fields ->
    (match List.assoc_opt "pid" fields, List.assoc_opt "chrome" fields, List.assoc_opt "profile" fields with
     | Some (`Int pid), Some (`String chrome), Some (`String profile)
       when pid > 0 && (not (Filename.is_relative chrome)) && not (Filename.is_relative profile) ->
       Ok { pid; chrome; profile }
     | (Some _ | None), (Some _ | None), (Some _ | None) ->
       Error "browser record needs a positive pid and absolute chrome and profile paths")
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Error "browser record is not an object"
;;

let profile_flag profile = "--user-data-dir=" ^ profile

(* The window size a headless page renders at; the Stagehand SDK launches with
   the same size, so pages lay out the way its prompts were tuned for. *)
let window_size = "--window-size=1280,800"

let argv ~chrome ~profile ~extension_id ~headless =
  [ chrome ]
  @ (if headless then [ "--headless=new" ] else [])
  @ [ "--remote-debugging-port=0"
    ; profile_flag profile
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

(* Chrome's own helper processes carry the same --user-data-dir, and the
   executable path may contain spaces (a macOS app bundle), so the match is on
   the whole executable followed by a separator, plus the profile flag. *)
let leftover owner ~command =
  match command with
  | Some command
    when String.starts_with ~prefix:(owner.chrome ^ " ") command
         && String_util.contains_substring command (profile_flag owner.profile) ->
    Stop_recorded_browser owner.pid
  | Some _ | None -> Not_the_recorded_browser
;;
