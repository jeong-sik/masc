type key = Enter | Tab | Escape | Backspace | Delete | ArrowUp | ArrowDown | ArrowLeft | ArrowRight | Home | End
type geolocation = { latitude : float; longitude : float; accuracy_m : float }
type emulation = { geolocation : geolocation option; locale : string option; timezone : string option }
let default_accuracy_m = 10.
let max_accuracy_m = 10_000.
type upload_target = File_input of string | Chooser_opener of string
type interaction =
  | Upload of { target : upload_target; paths : string list }
  | Set_emulation of emulation
  | Clear_emulation
  | Block_requests of string list
  | Unblock_requests
  | Accept_dialog of string option | Dismiss_dialog
  | Back | Forward | Reload | Stop_loading | Close_tab
type control_wait = { interval_ms : float option; timeout_ms : float option }
type keep_pages = Keep_all | Keep_labels of string list
let keep_pages_to_json = function
  | Keep_all -> `String "all"
  | Keep_labels labels -> `List (List.map (fun label -> `String label) labels)
type control = Hand_off | Take_over | Space_status | Finish_space of keep_pages | Wait_for_control of control_wait
  | Adopt_tab of { tab_id : int; label : string option }
  | Release_tab of int
type t = Open_tab of string | Control of control
  | On_tab of { tab_id : int; interaction : interaction }
(* The one control a live lane answers without a client: reclaiming the ego
   task space whose task ended while the operator held it. *)
let is_take_over = function
  | Control Take_over -> true
  | Control (Hand_off|Space_status|Finish_space _|Wait_for_control _|Adopt_tab _|Release_tab _)
  | Open_tab _|On_tab _ -> false
let reply_timeout_sec = function
  | Open_tab _ | Control _ | On_tab _ -> 60.
open Result.Syntax
let key_name = function
  | Enter -> "Enter" | Tab -> "Tab" | Escape -> "Escape" | Backspace -> "Backspace"
  | Delete -> "Delete" | ArrowUp -> "ArrowUp" | ArrowDown -> "ArrowDown"
  | ArrowLeft -> "ArrowLeft" | ArrowRight -> "ArrowRight" | Home -> "Home" | End -> "End"
let webdriver_key = function
  | Enter -> "\xee\x80\x87" | Tab -> "\xee\x80\x84" | Escape -> "\xee\x80\x8c"
  | Backspace -> "\xee\x80\x83" | Delete -> "\xee\x80\x97"
  | ArrowUp -> "\xee\x80\x93" | ArrowDown -> "\xee\x80\x95"
  | ArrowLeft -> "\xee\x80\x92" | ArrowRight -> "\xee\x80\x94"
  | Home -> "\xee\x80\x91" | End -> "\xee\x80\x90"
let string_list label = function
  | `List values ->
    let rec collect acc = function
      | [] -> Ok (List.rev acc)
      | `String s :: rest when String.trim s <> "" -> collect (s :: acc) rest
      | _ -> Error (label ^ " must contain nonempty strings") in
    collect [] values
  | _ -> Error (label ^ " must be an array")
(* Locale and time zone names are checked for shape only; the page's own Intl
   on the ego connection decides which ones exist and refuses the rest before
   any change. *)
let is_locale text =
  let parts = String.split_on_char '-' text in
  String.length text <= 35 && parts <> []
  && List.for_all (fun part -> part <> "" && String.length part <= 8
       && String.for_all (fun c -> (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) part) parts
  && String.length (List.hd parts) >= 2
let is_timezone text =
  String.length text <= 64 && text <> ""
  && String.for_all (fun c -> (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
       || c = '/' || c = '_' || c = '-' || c = '+') text
let parse_emulation fields =
  let number key = match List.assoc_opt key fields with
    | None -> Ok None
    | Some (`Int n) -> Ok (Some (float_of_int n))
    | Some (`Float f) when Float.is_finite f -> Ok (Some f)
    | Some _ -> Error (key ^ " must be a number") in
  let* latitude = number "latitude" in
  let* longitude = number "longitude" in
  let* accuracy = number "accuracyMeters" in
  let* geolocation = match latitude, longitude with
    | None, None -> if accuracy = None then Ok None else Error "accuracyMeters needs latitude and longitude"
    | Some latitude, Some longitude ->
      if latitude < -90. || latitude > 90. then Error "latitude must be between -90 and 90"
      else if longitude < -180. || longitude > 180. then Error "longitude must be between -180 and 180"
      else
        let accuracy_m = Option.value accuracy ~default:default_accuracy_m in
        if accuracy_m <= 0. || accuracy_m > max_accuracy_m
        then Error (Printf.sprintf "accuracyMeters must be above 0 and at most %.0f" max_accuracy_m)
        else Ok (Some {latitude; longitude; accuracy_m})
    | Some _, None | None, Some _ -> Error "latitude and longitude are given together" in
  let text key ok message = match List.assoc_opt key fields with
    | None -> Ok None
    | Some (`String value) when ok value -> Ok (Some value)
    | Some _ -> Error message in
  let* locale = text "locale" is_locale "locale must be a language tag such as ko-KR" in
  let* timezone = text "timezone" is_timezone "timezone must be an IANA name such as Asia/Seoul" in
  if geolocation = None && locale = None && timezone = None
  then Error "set_emulation needs a location, a locale or a timezone"
  else Ok {geolocation; locale; timezone}
(* A blocked host is compared for equality with the request URL's host,
   which is lowercase, so only a lowercase host name or IPv4 address can ever
   match. A host of any other shape is refused rather than sent to match
   nothing. *)
let is_host text =
  List.for_all (fun label -> label <> ""
      && String.for_all (fun c -> (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '-') label)
    (String.split_on_char '.' text)
let parse_hosts fields = match List.assoc_opt "hosts" fields with
  | None -> Error "block_requests needs hosts"
  | Some value ->
    let* hosts = string_list "hosts" value in
    if hosts = [] then Error "block_requests needs at least one host"
    else match List.find_opt (fun host -> not (is_host host)) hosts with
      | Some host -> Error ("hosts must be lowercase host names or IPv4 addresses such as ads.example.com, not " ^ host)
      | None -> Ok hosts
let control_wait_of_json = function
  | `Assoc fields when List.for_all (fun (key,_) -> List.mem key ["interval";"timeout"]) fields
      && List.length fields=List.length (List.sort_uniq String.compare (List.map fst fields)) ->
    let milliseconds key=match List.assoc_opt key fields with
      | None -> Ok None
      | Some (`Int value) when value>0 -> Ok (Some (float_of_int value))
      | Some (`Float value) when Float.is_finite value && value>0. -> Ok (Some value)
      | Some _ -> Error (key ^ " must be positive finite SDK milliseconds") in
    let* interval_ms=milliseconds "interval" in
    let* timeout_ms=milliseconds "timeout" in Ok {interval_ms;timeout_ms}
  | _ -> Error "invalid or duplicate control wait options"
let control_wait_to_json {interval_ms;timeout_ms} = `Assoc (
  (match interval_ms with None -> [] | Some value -> ["interval",`Float value])
  @ (match timeout_ms with None -> [] | Some value -> ["timeout",`Float value]))
let parse = function
  | `Assoc fields ->
    let string key = match List.assoc_opt key fields with
      | Some (`String s) -> Ok s | _ -> Error (key ^ " must be a string") in
    let nonempty key = let* s = string key in
      if String.trim s = "" then Error (key ^ " must not be empty") else Ok s in
    let integer key = match List.assoc_opt key fields with
      | Some (`Int n) -> Ok n | _ -> Error (key ^ " must be an integer") in
    let exact allowed =
      let keys = List.map fst fields in
      if List.length keys <> List.length (List.sort_uniq String.compare keys) then Error "duplicate browser argument"
      else if List.for_all (fun key -> List.mem key ("action" :: "lane" :: "clientId" :: allowed)) keys then Ok ()
      else Error "argument is not valid for this browser action" in
    let on_tab allowed interaction =
      let* () = exact ("tabId" :: allowed) in
      let* tab_id = integer "tabId" in
      if tab_id < 0 then Error "tabId must be nonnegative"
      else Ok (On_tab {tab_id;interaction}) in
    let* action = string "action" in
    (match action with
     | "open_tab" -> let* () = exact ["url"] in let* url = string "url" in Ok (Open_tab url)
     | "hand_off" -> let* () = exact [] in Ok (Control Hand_off)
     | "take_over" -> let* () = exact [] in Ok (Control Take_over)
     | "space_status" -> let* () = exact [] in Ok (Control Space_status)
     | "finish_space" ->
       let* ()=exact ["keepPages"] in
       let* keep=match List.assoc_opt "keepPages" fields with
         | None -> Ok (Keep_labels [])
         | Some (`String "all") -> Ok Keep_all
         | Some value ->
           let* labels = string_list "keepPages" value in
           if List.length labels=List.length (List.sort_uniq String.compare labels)
           then Ok (Keep_labels labels) else Error "keepPages must be all or distinct Page labels" in
       Ok (Control (Finish_space keep))
     | "wait_for_control" ->
       let* ()=exact ["controlOptions"] in
       let* options=control_wait_of_json (match List.assoc_opt "controlOptions" fields with
         | None -> `Assoc [] | Some value -> value) in
       Ok (Control (Wait_for_control options))
     | "adopt_tab" | "release_tab" ->
       let* ()=exact (if action="adopt_tab" then ["tabId";"pageLabel"] else ["tabId"]) in
       let* tab_id=integer "tabId" in
       let* ()=if tab_id>=0 then Ok () else Error "tabId must be nonnegative" in
       if action="release_tab" then Ok (Control (Release_tab tab_id))
       else
         let* label=match List.assoc_opt "pageLabel" fields with
           | None -> Ok None
           | Some (`String value) when String.trim value<>"" -> Ok (Some value)
           | Some _ -> Error "pageLabel must be nonempty text" in
         Ok (Control (Adopt_tab {tab_id;label}))
     | "upload" ->
       let* target = match List.mem_assoc "selector" fields, List.mem_assoc "opener" fields with
         | true, false -> Result.map (fun selector -> File_input selector) (nonempty "selector")
         | false, true -> Result.map (fun opener -> Chooser_opener opener) (nonempty "opener")
         | true, true -> Error "upload takes selector or opener, not both"
         | false, false -> Error "upload requires selector (a file input) or opener (the control that opens a file chooser)" in
       let* paths = match List.assoc_opt "paths" fields with
         | Some value -> string_list "paths" value | None -> Error "upload requires paths" in
       let* () = if paths = [] then Error "upload requires at least one file" else Ok () in
       let* () = if List.exists (fun p -> String.contains p '\n' || String.contains p '\r' || String.contains p '\000') paths
         then Error "upload paths must not contain line separators or NUL" else Ok () in
       on_tab ["selector";"opener";"paths"] (Upload {target;paths})
     | "accept_dialog" ->
       let* text = match List.assoc_opt "text" fields with
         | None -> Ok None | Some (`String text) -> Ok (Some text) | _ -> Error "text must be a string" in
       on_tab ["text"] (Accept_dialog text)
     | "set_emulation" ->
       let* emulation = parse_emulation fields in
       on_tab ["latitude";"longitude";"accuracyMeters";"locale";"timezone"] (Set_emulation emulation)
     | "clear_emulation" -> on_tab [] Clear_emulation
     | "block_requests" -> let* hosts = parse_hosts fields in on_tab ["hosts"] (Block_requests hosts)
     | "unblock_requests" -> on_tab [] Unblock_requests
     | "dismiss_dialog" -> on_tab [] Dismiss_dialog
     | "back" -> on_tab [] Back | "forward" -> on_tab [] Forward
     | "stop_loading" -> on_tab [] Stop_loading
     | "reload" -> on_tab [] Reload | "close_tab" -> on_tab [] Close_tab
     | _ -> Error "unknown browser action")
  | _ -> Error "browser action must be an object"
let to_json = function
  | Open_tab url -> `Assoc ["action",`String "open_tab";"url",`String url]
  | Control Hand_off -> `Assoc ["action",`String "hand_off"]
  | Control Take_over -> `Assoc ["action",`String "take_over"]
  | Control Space_status -> `Assoc ["action",`String "space_status"]
  | Control (Finish_space keep) -> `Assoc ["action",`String "finish_space";"keepPages",keep_pages_to_json keep]
  | Control (Wait_for_control options) -> `Assoc ["action",`String "wait_for_control";
      "controlOptions",control_wait_to_json options]
  | Control (Adopt_tab {tab_id;label}) -> `Assoc (["action",`String "adopt_tab";"tabId",`Int tab_id]
      @ Option.to_list (Option.map (fun value -> "pageLabel",`String value) label))
  | Control (Release_tab tab_id) -> `Assoc ["action",`String "release_tab";"tabId",`Int tab_id]
  | On_tab {tab_id;interaction} ->
    let action, args = match interaction with
      | Upload {target;paths} ->
        "upload", [(match target with
          | File_input selector -> "selector",`String selector
          | Chooser_opener opener -> "opener",`String opener);
          "paths",`List (List.map (fun p -> `String p) paths)]
      | Accept_dialog text -> "accept_dialog", Option.to_list (Option.map (fun s -> "text",`String s) text)
      | Dismiss_dialog -> "dismiss_dialog", []
      | Clear_emulation -> "clear_emulation", []
      | Block_requests hosts -> "block_requests", ["hosts",`List (List.map (fun host -> `String host) hosts)]
      | Unblock_requests -> "unblock_requests", []
      | Set_emulation {geolocation;locale;timezone} ->
        "set_emulation",
        (match geolocation with
         | Some {latitude;longitude;accuracy_m} ->
           ["latitude",`Float latitude;"longitude",`Float longitude;"accuracyMeters",`Float accuracy_m]
         | None -> [])
        @ Option.to_list (Option.map (fun l -> "locale",`String l) locale)
        @ Option.to_list (Option.map (fun z -> "timezone",`String z) timezone)
      | Back -> "back", [] | Forward -> "forward", [] | Reload -> "reload", [] | Stop_loading -> "stop_loading", [] | Close_tab -> "close_tab", [] in
    `Assoc (["action",`String action;"tabId",`Int tab_id] @ args)
