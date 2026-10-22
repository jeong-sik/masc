type key = Enter | Tab | Escape | Backspace | Delete | ArrowUp | ArrowDown | ArrowLeft | ArrowRight | Home | End
type interaction =
  | Upload of { selector : string; paths : string list }
  | Accept_dialog of string option | Dismiss_dialog
  | Back | Forward | Reload | Close_tab
type t = Open_tab of string | On_tab of { tab_id : int; frame_path : string list; interaction : interaction }
let reply_timeout_sec = function
  | Open_tab _ | On_tab _ -> 60.
let ( let* ) = Result.bind
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
let parse_frame_path = function
  | `Assoc fields -> (match List.assoc_opt "framePath" fields with
      | None -> Ok [] | Some value -> string_list "framePath" value)
  | _ -> Error "browser arguments must be an object"
let parse = function
  | `Assoc fields ->
    let string key = match List.assoc_opt key fields with
      | Some (`String s) -> Ok s | _ -> Error (key ^ " must be a string") in
    let selector () = let* s = string "selector" in
      if String.trim s = "" then Error "selector must not be empty" else Ok s in
    let integer key = match List.assoc_opt key fields with
      | Some (`Int n) -> Ok n | _ -> Error (key ^ " must be an integer") in
    let exact allowed =
      let keys = List.map fst fields in
      if List.length keys <> List.length (List.sort_uniq String.compare keys) then Error "duplicate browser argument"
      else if List.for_all (fun key -> List.mem key ("action" :: "lane" :: "clientId" :: allowed)) keys then Ok ()
      else Error "argument is not valid for this browser action" in
    let on_tab allowed interaction =
      let* () = exact ("tabId" :: "framePath" :: allowed) in
      let* frame_path = parse_frame_path (`Assoc fields) in
      let* () = match interaction, frame_path with
        | (Back | Forward | Reload | Close_tab | Accept_dialog _ | Dismiss_dialog), _ :: _ -> Error "this action operates on the top-level tab"
        | ((Back | Forward | Reload | Close_tab | Accept_dialog _ | Dismiss_dialog), [])
        | Upload _, _ -> Ok () in
      let* tab_id = integer "tabId" in
      if tab_id < 0 then Error "tabId must be nonnegative"
      else Ok (On_tab {tab_id;frame_path;interaction}) in
    let* action = string "action" in
    (match action with
     | "open_tab" -> let* () = exact ["url"] in let* url = string "url" in Ok (Open_tab url)
     | "upload" ->
       let* selector = selector () in
       let* paths = match List.assoc_opt "paths" fields with
         | Some value -> string_list "paths" value | None -> Error "upload requires paths" in
       let* () = if paths = [] then Error "upload requires at least one file" else Ok () in
       let* () = if List.exists (fun p -> String.contains p '\n' || String.contains p '\r' || String.contains p '\000') paths
         then Error "upload paths must not contain line separators or NUL" else Ok () in
       on_tab ["selector";"paths"] (Upload {selector;paths})
     | "accept_dialog" ->
       let* text = match List.assoc_opt "text" fields with
         | None -> Ok None | Some (`String text) -> Ok (Some text) | _ -> Error "text must be a string" in
       on_tab ["text"] (Accept_dialog text)
     | "dismiss_dialog" -> on_tab [] Dismiss_dialog
     | "back" -> on_tab [] Back | "forward" -> on_tab [] Forward
     | "reload" -> on_tab [] Reload | "close_tab" -> on_tab [] Close_tab
     | _ -> Error "unknown browser action")
  | _ -> Error "browser action must be an object"
let to_json = function
  | Open_tab url -> `Assoc ["action",`String "open_tab";"url",`String url]
  | On_tab {tab_id;frame_path;interaction} ->
    let action, args = match interaction with
      | Upload {selector;paths} -> "upload", ["selector",`String selector;"paths",`List (List.map (fun p -> `String p) paths)]
      | Accept_dialog text -> "accept_dialog", Option.to_list (Option.map (fun s -> "text",`String s) text)
      | Dismiss_dialog -> "dismiss_dialog", []
      | Back -> "back", [] | Forward -> "forward", [] | Reload -> "reload", [] | Close_tab -> "close_tab", [] in
    `Assoc (["action",`String action;"tabId",`Int tab_id] @
      (if frame_path = [] then [] else ["framePath",`List (List.map (fun s -> `String s) frame_path)]) @ args)
