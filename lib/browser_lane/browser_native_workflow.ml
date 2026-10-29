type element_state = Attached | Detached | Visible | Hidden
type load_state = Dom_content_loaded | Load | Network_idle
type option_match = { value : string option; label : string option; index : int option }
type option_choice = Text of string | Match of option_match
type selection = Clear | One of option_choice | Many of option_choice list
type clipboard_content = { text : string; html : string option }
type page_code = Expression of string | Call of { source : string; argument : Yojson.Safe.t }
type url_matcher = Glob of string | Regexp of { source : string; flags : string option }
type native_options = Yojson.Safe.t
type action =
  | Click of string | Double_click of string | Hover of string
  | Drag_and_drop of { selector : string; destination : string }
  | Mouse_click of { x : float; y : float }
  | Mouse_move of { x : float; y : float }
  | Mouse_wheel of { x : float; y : float }
  | Fill of { selector : string; text : string }
  | Press of { selector : string; key : string }
  | Focus of string | Reload
  | Keyboard_type of string | Keyboard_insert_text of string
  | Keyboard_paste of clipboard_content | Keyboard_press of string
  | Select_option of { selector : string; selection : selection }
  | Goto of string | Wait_for_url of url_matcher
  | Wait_for_selector of { selector : string; state : element_state }
  | Wait_for_load_state of load_state option
  | Evaluate of page_code
  | Wait_for_function of page_code
  | Fetch of string
  | Cancel_download of string
  | Url | Title | Info | Snapshot
  | Events
  | Wait_for_timeout of float
type step = { action : action; options : native_options option }
type snapshot_scope = Viewport | Full_page
type t = { tab_id : int; expected_url : string; steps : step list;
  snapshot_scope : snapshot_scope; max_chars : int }
open Result.Syntax
let object_fields allowed = function
  | `Assoc fields when List.for_all (fun (name, _) -> List.mem name allowed) fields
      && List.length fields = List.length (List.sort_uniq String.compare (List.map fst fields)) -> Ok fields
  | _ -> Error "unknown or duplicate native workflow fields"
let required name fields = Option.to_result ~none:("workflow requires " ^ name) (List.assoc_opt name fields)
let text name fields = let* value = required name fields in match value with
  | `String value when String.trim value <> "" -> Ok value
  | _ -> Error (name ^ " must be a nonempty string")
let string_field name fields = let* value = required name fields in match value with
  | `String value -> Ok value
  | _ -> Error (name ^ " must be a string")
let integer name fields = let* value = required name fields in match value with
  | `Int value when value >= 0 && Int64.of_int value <= 9007199254740991L -> Ok value
  | _ -> Error (name ^ " must be a nonnegative JavaScript-safe integer")
let finite_number = function
  | `Int value -> Some (float_of_int value)
  | `Float value when Float.is_finite value -> Some value
  | `Null|`Bool _|`Intlit _|`Float _|`String _|`List _|`Assoc _ -> None
let number name fields = let* value=required name fields in
  Option.to_result ~none:(name ^ " must be a finite number") (finite_number value)
let url text =
  let uri = Uri.of_string text in
  match Uri.scheme uri, Uri.host uri with
  | Some ("http" | "https"), Some host when host <> "" -> Ok text
  | (None | Some _), (None | Some _) -> Error "workflow navigation requires an absolute HTTP(S) URL"
let element_state = function
  | "attached" -> Ok Attached | "detached" -> Ok Detached | "visible" -> Ok Visible | "hidden" -> Ok Hidden
  | _ -> Error "unknown native element state"
let element_state_name = function Attached -> "attached" | Detached -> "detached" | Visible -> "visible" | Hidden -> "hidden"
let load_state = function
  | "domcontentloaded" -> Ok Dom_content_loaded | "load" -> Ok Load | "networkidle" -> Ok Network_idle
  | _ -> Error "unknown native load state"
let load_state_name = function Dom_content_loaded -> "domcontentloaded" | Load -> "load" | Network_idle -> "networkidle"
let rec json_argument = function
  | `Null|`Bool _|`Int _|`Intlit _|`String _ -> true
  | `Float value -> Float.is_finite value
  | `List values -> List.for_all json_argument values
  | `Assoc fields -> List.length fields=List.length (List.sort_uniq String.compare (List.map fst fields))
      && List.for_all (fun (_,value) -> json_argument value) fields
let json_field name fields =
  let* source=string_field name fields in
  match Yojson.Safe.from_string source with
  | value when json_argument value -> Ok value
  | _ -> Error (name ^ " must contain finite JSON without duplicate fields")
  | exception Yojson.Json_error _ -> Error (name ^ " must encode one JSON value")
let page_code fields =
  let* source=text "source" fields in
  match List.assoc_opt "argumentJson" fields with
  | None -> Ok (Expression source)
  | Some _ -> let* argument=json_field "argumentJson" fields in Ok (Call {source;argument})
let url_matcher fields =
  match List.assoc_opt "url" fields, List.assoc_opt "urlRegex" fields with
  | Some _, None -> let* value=text "url" fields in Ok (Glob value)
  | None, Some raw ->
    let* fields=object_fields ["source";"flags"] raw in
    let* source=string_field "source" fields in
    let* flags=match List.assoc_opt "flags" fields with
      | None -> Ok None
      | Some (`String flags) -> Ok (Some flags)
      | Some _ -> Error "URL regex flags must be a string" in
    Ok (Regexp {source;flags})
  | Some _, Some _ | None, None -> Error "waitForURL requires exactly one of url or urlRegex"
let option_choice = function
  | `String value -> Ok (Text value)
  | (`Assoc _ as raw) ->
    let* fields=object_fields ["value";"label";"index"] raw in
    let optional_string key=match List.assoc_opt key fields with
      | None -> Ok None | Some (`String value) -> Ok (Some value)
      | Some _ -> Error ("selection " ^ key ^ " must be a string") in
    let* value=optional_string "value" in let* label=optional_string "label" in
    let* index=match List.assoc_opt "index" fields with None -> Ok None
      | Some _ -> Result.map Option.some (integer "index" fields) in
    if value=None && label=None && index=None then Error "selection object needs value, label or index"
    else Ok (Match {value;label;index})
  | `Null|`Bool _|`Int _|`Intlit _|`Float _|`List _ -> Error "selection item must be a string or option object"
let selection_of_json = function
  | `Null -> Ok Clear
  | `List values ->
    let rec decode acc = function [] -> Ok (Many (List.rev acc))
      | value::rest -> let* choice=option_choice value in decode (choice::acc) rest in
    decode [] values
  | (`String _|`Assoc _ as value) -> Result.map (fun value -> One value) (option_choice value)
  | `Bool _|`Int _|`Intlit _|`Float _ -> Error "invalid native selectOption selection"
let options_of_json action raw =
  let allowed=match action with
    | Click _ -> Some ["button";"clickCount";"delay";"position";"force";"timeout";"label"]
    | Double_click _ -> Some ["button";"delay";"position";"force";"timeout";"label"]
    | Hover _ -> Some ["position";"force";"timeout";"label"]
    | Drag_and_drop _ -> Some ["button";"sourcePosition";"targetPosition";"force";"timeout";"label"]
    | Mouse_click _ -> Some ["button";"clickCount";"delay";"label"]
    | Mouse_move _ -> Some ["steps";"label"] | Mouse_wheel _ -> Some ["label"]
    | Fill _ -> Some ["clearFirst";"timeout"]
    | Press _ -> Some ["delay";"timeout"]
    | Focus _|Select_option _|Wait_for_url _|Wait_for_selector _ -> Some ["timeout"]
    | Reload -> Some ["timeout";"waitUntil"] | Goto _ -> Some ["referer";"timeout";"waitUntil"]
    | Keyboard_type _|Keyboard_press _ -> Some ["delay"]
    | Wait_for_load_state _ -> Some ["timeout";"idleMs"]
    | Wait_for_function _ -> Some ["timeout";"polling"]
    | Fetch _ -> Some ["timeout";"saveAs";"method";"headers";"body";"cache";"credentials";"integrity";
        "keepalive";"mode";"redirect";"referrer";"referrerPolicy"]
    | Snapshot -> Some ["scope";"root";"includeActionMarks";"includeStableLocator"]
    | Keyboard_insert_text _|Keyboard_paste _|Evaluate _|Cancel_download _|Url|Title|Info|Events|Wait_for_timeout _ -> None in
  let* allowed=Option.to_result ~none:"this SDK method accepts no options" allowed in
  let* fields=object_fields allowed raw in
  let strings values=List.for_all (function _,`String _ -> true | _,_ -> false) values in
  let position value=match object_fields ["x";"y"] value with
    | Error _ -> false | Ok fields -> List.length fields=2
        && Result.is_ok (number "x" fields) && Result.is_ok (number "y" fields) in
  let valid name value=match name,value with
    | "saveAs",`String value -> String.trim value<>"" && value<>"." && value<>".."
        && not (String.exists (fun c -> c='/' || c='\\' || Char.code c<32 || Char.code c=127) value)
    | ("label"|"referer"|"method"|"body"|"integrity"|"referrer"),`String _ -> true
    | ("force"|"clearFirst"|"keepalive"|"includeActionMarks"|"includeStableLocator"),`Bool _ -> true
    | "scope",`String ("full_page"|"only_within_viewport"|"subtree") -> true
    | "root",`String value -> String.trim value<>""
    | "button",`String ("left"|"middle"|"right")
    | "waitUntil",`String ("commit"|"domcontentloaded"|"load"|"networkidle")
    | "cache",`String ("default"|"no-store"|"reload"|"no-cache"|"force-cache"|"only-if-cached")
    | "credentials",`String ("omit"|"same-origin"|"include")
    | "mode",`String ("cors"|"no-cors"|"same-origin")
    | "redirect",`String ("follow"|"error"|"manual")
    | "referrerPolicy",`String (""|"no-referrer"|"no-referrer-when-downgrade"|"origin"|
        "origin-when-cross-origin"|"same-origin"|"strict-origin"|"strict-origin-when-cross-origin"|"unsafe-url") -> true
    | ("timeout"|"delay"|"idleMs"|"polling"),value ->
      (match finite_number value with Some value -> value>=0. | None -> false)
    | ("clickCount"|"steps"),value ->
      (match finite_number value with Some value -> value>=0. && Float.floor value=value && value<=9007199254740991.
       | None -> false)
    | ("position"|"sourcePosition"|"targetPosition"),value -> position value
    | "headers",`Assoc values -> strings values
        && List.length values=List.length (List.sort_uniq String.compare (List.map fst values))
    | _,_ -> false in
  let* ()=if List.for_all (fun (name,value) -> valid name value) fields then Ok ()
    else Error "invalid native SDK option value" in
  match action,List.assoc_opt "scope" fields,List.assoc_opt "root" fields with
  | Snapshot,Some (`String "subtree"),Some (`String _) -> Ok raw
  | Snapshot,Some (`String "subtree"),None -> Error "subtree snapshot requires root from the same Page"
  | Snapshot,(None|Some _),Some _ -> Error "snapshot root requires subtree scope"
  | Snapshot,(None|Some _),None -> Ok raw
  | (Click _|Double_click _|Hover _|Drag_and_drop _|Mouse_click _|Mouse_move _|Mouse_wheel _
    |Fill _|Press _|Focus _|Reload|Keyboard_type _|Keyboard_insert_text _|Keyboard_paste _|Keyboard_press _
    |Select_option _|Goto _|Wait_for_url _|Wait_for_selector _|Wait_for_load_state _
    |Evaluate _|Wait_for_function _|Fetch _|Cancel_download _|Url|Title|Info|Events|Wait_for_timeout _),_,_ -> Ok raw
let fetch_save_name step = match step.action,step.options with
  | Fetch _,Some (`Assoc fields) ->
      (match List.assoc_opt "saveAs" fields with Some (`String value) -> Some value | None|Some _ -> None)
  | (Click _|Double_click _|Hover _|Drag_and_drop _|Mouse_click _|Mouse_move _|Mouse_wheel _
    |Fill _|Press _|Focus _|Reload|Keyboard_type _|Keyboard_insert_text _|Keyboard_paste _|Keyboard_press _
    |Select_option _|Goto _|Wait_for_url _|Wait_for_selector _|Wait_for_load_state _
    |Evaluate _|Wait_for_function _|Cancel_download _|Url|Title|Info|Snapshot|Events|Wait_for_timeout _),_
  | Fetch _,(None|Some (`Null|`Bool _|`Int _|`Intlit _|`Float _|`String _|`List _)) -> None
let step_of_json value =
  let* fields = object_fields ["method";"selector";"destination";"x";"y";"text";"html";"key";"url";
    "selectionJson";"state";"source";"argumentJson";"milliseconds";"options";"urlRegex";"downloadId"] value in
  let* method_ = text "method" fields in
  let arguments names = object_fields ("method" :: "options" :: names) value in
  let selector () = text "selector" fields in
  let* action = match method_ with
    | "click" | "dblclick" | "hover" ->
      let* _ = arguments ["selector"] in let* selector = selector () in
      (match method_ with "click" -> Ok (Click selector) | "dblclick" -> Ok (Double_click selector)
       | "hover" -> Ok (Hover selector) | _ -> Error "unknown native pointer method")
    | "dragAndDrop" ->
      let* _=arguments ["selector";"destination"] in
      let* selector=selector () in let* destination=text "destination" fields in
      Ok (Drag_and_drop {selector;destination})
    | "mouse.click"|"mouse.move"|"mouse.wheel" ->
      let* _=arguments ["x";"y"] in let* x=number "x" fields in let* y=number "y" fields in
      (match method_ with
       | "mouse.click" -> Ok (Mouse_click {x;y}) | "mouse.move" -> Ok (Mouse_move {x;y})
       | "mouse.wheel" -> Ok (Mouse_wheel {x;y}) | _ -> Error "unknown native mouse method")
    | "fill" ->
      let* _ = arguments ["selector";"text"] in let* selector = selector () in
      let* raw = required "text" fields in
      (match raw with `String text -> Ok (Fill {selector;text}) | _ -> Error "fill requires string text")
    | "press" -> let* _ = arguments ["selector";"key"] in
      let* selector = selector () in let* key = text "key" fields in Ok (Press {selector;key})
    | "focus" -> let* _ = arguments ["selector"] in
      let* selector = selector () in Ok (Focus selector)
    | "reload" -> let* _ = arguments [] in Ok Reload
    | "keyboard.type" | "keyboard.insertText" ->
      let* _ = arguments ["text"] in
      let* text = string_field "text" fields in
      (match method_ with
       | "keyboard.type" -> Ok (Keyboard_type text)
       | "keyboard.insertText" -> Ok (Keyboard_insert_text text)
       | _ -> Error "unknown native keyboard text method")
    | "keyboard.paste" ->
      let* _ = arguments ["text";"html"] in
      let* text = string_field "text" fields in
      let* html = match List.assoc_opt "html" fields with
        | None -> Ok None
        | Some (`String html) -> Ok (Some html)
        | Some _ -> Error "html must be a string" in
      Ok (Keyboard_paste {text;html})
    | "keyboard.press" ->
      let* _ = arguments ["key"] in
      let* key = text "key" fields in Ok (Keyboard_press key)
    | "selectOption" ->
      let* _ = arguments ["selector";"selectionJson"] in let* selector = selector () in
      let* raw=json_field "selectionJson" fields in let* selection=selection_of_json raw in
      Ok (Select_option {selector;selection})
    | "goto" -> let* _ = arguments ["url"] in let* raw = text "url" fields in
      let* url = url raw in Ok (Goto url)
    | "waitForURL" -> let* _ = arguments ["url";"urlRegex"] in
      let* matcher = url_matcher fields in Ok (Wait_for_url matcher)
    | "waitForSelector" -> let* _ = arguments ["selector";"state"] in
      let* selector = selector () in let* raw = text "state" fields in let* state = element_state raw in
      Ok (Wait_for_selector {selector;state})
    | "waitForLoadState" -> let* _ = arguments ["state"] in
      let* state=match List.assoc_opt "state" fields with None -> Ok None
        | Some _ -> let* raw=text "state" fields in Result.map Option.some (load_state raw) in
      Ok (Wait_for_load_state state)
    | "evaluate" ->
      let* _=arguments ["source";"argumentJson"] in
      let* code=page_code fields in Ok (Evaluate code)
    | "waitForFunction" ->
      let* _=arguments ["source";"argumentJson"] in
      let* code=page_code fields in
      Ok (Wait_for_function code)
    | "fetch" ->
      let* _=arguments ["url"] in
      let* raw=string_field "url" fields in
      let* url=match Uri.scheme (Uri.of_string raw) with None -> Ok raw
        | Some _ -> url raw in
      Ok (Fetch url)
    | "download.cancel" ->
      let* _=arguments ["downloadId"] in let* id=text "downloadId" fields in
      let* ()=match Uuidm.of_string id with
        | Some uuid when Uuidm.to_string uuid=id -> Ok ()
        | None|Some _ -> Error "downloadId must be a canonical UUID" in
      Ok (Cancel_download id)
    | "url"|"title"|"info"|"snapshot"|"events" ->
      let* _=arguments [] in
      (match method_ with
       | "url" -> Ok Url | "title" -> Ok Title | "info" -> Ok Info
       | "snapshot" -> Ok Snapshot | "events" -> Ok Events
       | _ -> Error "unknown native Page observation method")
    | "waitForTimeout" ->
      let* _=arguments ["milliseconds"] in let* milliseconds=number "milliseconds" fields in
      if milliseconds>=0. then Ok (Wait_for_timeout milliseconds)
      else Error "waitForTimeout milliseconds must be nonnegative"
    | _ -> Error "unsupported native Page method" in
  let* options=match List.assoc_opt "options" fields with None -> Ok None
    | Some value -> Result.map Option.some (options_of_json action value) in
  Ok {action;options}
let of_json value =
  let* fields = object_fields ["tabId";"expectedUrl";"steps";"snapshotScope";"maxChars"] value in
  let* tab_id = integer "tabId" fields in
  let* expected_url = text "expectedUrl" fields in
  let* max_chars = integer "maxChars" fields in
  let* () = if max_chars > 0 then Ok () else Error "maxChars must be positive" in
  let* snapshot_scope = match List.assoc_opt "snapshotScope" fields with
    | None | Some (`String "viewport") -> Ok Viewport
    | Some (`String "full_page") -> Ok Full_page
    | Some _ -> Error "workflow snapshotScope must be viewport or full_page" in
  let* raw = required "steps" fields in
  let* steps = match raw with
    | `List values ->
      let rec decode acc = function [] -> Ok (List.rev acc)
        | value :: rest -> let* step = step_of_json value in decode (step :: acc) rest in decode [] values
    | _ -> Error "steps must be a native Page call array" in
  Ok {tab_id;expected_url;steps;snapshot_scope;max_chars}
let is_effect = function
  | Click _ | Double_click _ | Hover _ | Drag_and_drop _ | Mouse_click _ | Mouse_move _ | Mouse_wheel _
  | Fill _ | Press _ | Focus _ | Reload
  | Keyboard_type _ | Keyboard_insert_text _ | Keyboard_paste _ | Keyboard_press _
  | Select_option _ | Goto _ | Evaluate _ | Wait_for_function _ | Fetch _ | Cancel_download _ | Events -> true
  | Wait_for_url _ | Wait_for_selector _ | Wait_for_load_state _|Url|Title|Info|Snapshot|Wait_for_timeout _ -> false
let holds_input = function
  | Click _|Double_click _|Mouse_click _|Drag_and_drop _|Press _|Keyboard_press _|Keyboard_type _|Keyboard_paste _ -> true
  | Hover _|Mouse_move _|Mouse_wheel _|Fill _|Focus _|Reload
  | Keyboard_insert_text _|Select_option _|Goto _
  | Wait_for_url _|Wait_for_selector _|Wait_for_load_state _|Evaluate _|Wait_for_function _|Fetch _|Cancel_download _
  | Url|Title|Info|Snapshot|Events|Wait_for_timeout _ -> false
let method_name = function
  | Click _ -> "click" | Double_click _ -> "dblclick" | Hover _ -> "hover" | Fill _ -> "fill"
  | Press _ -> "press" | Select_option _ -> "selectOption" | Goto _ -> "goto" | Wait_for_url _ -> "waitForURL"
  | Focus _ -> "focus" | Reload -> "reload"
  | Keyboard_type _ -> "keyboard.type" | Keyboard_insert_text _ -> "keyboard.insertText"
  | Keyboard_paste _ -> "keyboard.paste" | Keyboard_press _ -> "keyboard.press"
  | Wait_for_selector _ -> "waitForSelector" | Wait_for_load_state _ -> "waitForLoadState"
  | Evaluate _ -> "evaluate" | Wait_for_function _ -> "waitForFunction" | Fetch _ -> "fetch"
  | Drag_and_drop _ -> "dragAndDrop"
  | Mouse_click _ -> "mouse.click" | Mouse_move _ -> "mouse.move" | Mouse_wheel _ -> "mouse.wheel"
  | Url -> "url" | Title -> "title" | Info -> "info" | Snapshot -> "snapshot" | Events -> "events"
  | Wait_for_timeout _ -> "waitForTimeout"
  | Cancel_download _ -> "download.cancel"
let string value = `String value
let code_fields = function
  | Expression source -> ["source",string source]
  | Call {source;argument} -> ["source",string source;"argumentJson",string (Yojson.Safe.to_string argument)]
let choice_to_json = function
  | Text value -> string value
  | Match {value;label;index} -> `Assoc (
      Option.to_list (Option.map (fun value -> "value",string value) value)
      @ Option.to_list (Option.map (fun value -> "label",string value) label)
      @ Option.to_list (Option.map (fun value -> "index",`Int value) index))
let selection_to_json = function
  | Clear -> `Null | One value -> choice_to_json value | Many values -> `List (List.map choice_to_json values)
let step_to_json {action;options} =
  let selector value = ["selector",string value] in
  let fields = match action with
    | Click s | Double_click s | Hover s | Focus s -> selector s
    | Drag_and_drop {selector=s;destination} -> selector s @ ["destination",string destination]
    | Mouse_click {x;y}|Mouse_move {x;y}|Mouse_wheel {x;y} -> ["x",`Float x;"y",`Float y]
    | Fill {selector=s;text} -> selector s @ ["text",string text]
    | Press {selector=s;key} -> selector s @ ["key",string key]
    | Cancel_download id -> ["downloadId",string id]
    | Reload|Url|Title|Info|Snapshot|Events -> []
    | Wait_for_timeout milliseconds -> ["milliseconds",`Float milliseconds]
    | Keyboard_type text | Keyboard_insert_text text -> ["text",string text]
    | Keyboard_paste {text;html} -> ["text",string text]
        @ Option.to_list (Option.map (fun html -> "html",string html) html)
    | Keyboard_press key -> ["key",string key]
    | Select_option {selector=s;selection} -> selector s @ ["selectionJson",string (Yojson.Safe.to_string (selection_to_json selection))]
    | Goto url | Wait_for_url (Glob url) -> ["url",string url]
    | Wait_for_url (Regexp {source;flags}) -> ["urlRegex",`Assoc (["source",string source]
        @ Option.to_list (Option.map (fun flags -> "flags",string flags) flags))]
    | Wait_for_selector {selector=s;state} -> selector s @ ["state",string (element_state_name state)]
    | Wait_for_load_state state -> Option.to_list (Option.map (fun state -> "state",string (load_state_name state)) state)
    | Evaluate code -> code_fields code
    | Wait_for_function code -> code_fields code
    | Fetch url -> ["url",string url] in
  `Assoc (["method",string (method_name action)] @ fields @ Option.to_list (Option.map (fun value -> "options",value) options))

let to_json {tab_id;expected_url;steps;snapshot_scope;max_chars} = `Assoc [
  "tabId",`Int tab_id;"expectedUrl",string expected_url;"steps",`List (List.map step_to_json steps);
  "snapshotScope",string (match snapshot_scope with Viewport -> "viewport" | Full_page -> "full_page");"maxChars",`Int max_chars]
