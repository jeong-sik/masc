type key = Enter | Tab | Escape | Backspace | Delete | ArrowUp | ArrowDown | ArrowLeft | ArrowRight | Home | End
type interaction =
  | Click of string
  | Fill of { selector : string; text : string }
  | Press of { selector : string; key : key }
  | Select of { selector : string; value : string }
  | Scroll of { x : int; y : int }
  | Back | Forward | Reload | Close_tab
type t = Open_tab of string | On_tab of { tab_id : int; interaction : interaction }
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
let parse_key value =
  match List.find_opt (fun key -> key_name key = value)
      [Enter;Tab;Escape;Backspace;Delete;ArrowUp;ArrowDown;ArrowLeft;ArrowRight;Home;End] with
  | Some key -> Ok key | None -> Error "unsupported key"
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
      else if List.for_all (fun key -> List.mem key ("action" :: "lane" :: allowed)) keys then Ok ()
      else Error "argument is not valid for this browser action" in
    let on_tab allowed interaction =
      let* () = exact ("tabId" :: allowed) in
      let* tab_id = integer "tabId" in
      if tab_id < 0 then Error "tabId must be nonnegative"
      else Ok (On_tab {tab_id;interaction}) in
    let* action = string "action" in
    (match action with
     | "open_tab" -> let* () = exact ["url"] in let* url = string "url" in Ok (Open_tab url)
     | "click" -> let* selector = selector () in on_tab ["selector"] (Click selector)
     | "fill" -> let* selector = selector () in let* text = string "text" in
       on_tab ["selector";"text"] (Fill {selector;text})
     | "press" -> let* selector = selector () in let* key = string "key" in
       let* key = parse_key key in on_tab ["selector";"key"] (Press {selector;key})
     | "select" -> let* selector = selector () in let* value = string "value" in
       on_tab ["selector";"value"] (Select {selector;value})
     | "scroll" -> let* x = integer "x" in let* y = integer "y" in
       on_tab ["x";"y"] (Scroll {x;y})
     | "back" -> on_tab [] Back | "forward" -> on_tab [] Forward
     | "reload" -> on_tab [] Reload | "close_tab" -> on_tab [] Close_tab
     | _ -> Error "unknown browser action")
  | _ -> Error "browser action must be an object"
let to_json = function
  | Open_tab url -> `Assoc ["action",`String "open_tab";"url",`String url]
  | On_tab {tab_id;interaction} ->
    let action, args = match interaction with
      | Click selector -> "click", ["selector",`String selector]
      | Fill {selector;text} -> "fill", ["selector",`String selector;"text",`String text]
      | Press {selector;key} -> "press", ["selector",`String selector;"key",`String (key_name key)]
      | Select {selector;value} -> "select", ["selector",`String selector;"value",`String value]
      | Scroll {x;y} -> "scroll", ["x",`Int x;"y",`Int y]
      | Back -> "back", [] | Forward -> "forward", [] | Reload -> "reload", [] | Close_tab -> "close_tab", [] in
    `Assoc (["action",`String action;"tabId",`Int tab_id] @ args)
