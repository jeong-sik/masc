type element_state = Attached | Detached | Visible | Hidden
type load_state = Dom_content_loaded | Load | Network_idle
type selection = One of string | Many of string list
type clipboard_content = { text : string; html : string option }
type page_code = Expression of string | Call of { source : string; argument : Yojson.Safe.t }
type fetch_options = Yojson.Safe.t
type action =
  | Click of string | Double_click of string | Hover of string
  | Fill of { selector : string; text : string }
  | Press of { selector : string; key : string }
  | Focus of string | Reload
  | Keyboard_type of string | Keyboard_insert_text of string
  | Keyboard_paste of clipboard_content | Keyboard_press of string
  | Select_option of { selector : string; selection : selection }
  | Goto of string | Wait_for_url of string
  | Wait_for_selector of { selector : string; state : element_state }
  | Wait_for_load_state of load_state
  | Evaluate of page_code
  | Wait_for_function of { code : page_code; polling_ms : int option }
  | Fetch of { url : string; options : fetch_options }
type step = { action : action; timeout_ms : int option }
type snapshot_scope = Viewport | Full_page
type t = { tab_id : int; expected_url : string; steps : step list;
  snapshot_scope : snapshot_scope; max_chars : int }
let ( let* ) = Result.bind
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
let page_code fields =
  let* source=text "source" fields in
  match List.assoc_opt "argumentJson" fields with
  | None -> Ok (Expression source)
  | Some (`String json) ->
    (match Yojson.Safe.from_string json with
     | argument when json_argument argument -> Ok (Call {source;argument})
     | _ -> Error "argumentJson must contain finite JSON values without duplicate fields"
     | exception Yojson.Json_error _ -> Error "argumentJson must encode one JSON value")
  | Some _ -> Error "argumentJson must be a JSON-encoded string"
let fetch_options value =
  let* fields=object_fields ["method";"headers";"body";"cache";"credentials";"integrity";
    "keepalive";"mode";"redirect";"referrer";"referrerPolicy"] value in
  let strings fields = List.for_all (function _,`String _ -> true | _,_ -> false) fields in
  let rec validate = function
    | [] -> Ok value
    | (name,raw)::rest ->
      let valid=match name,raw with
        | ("method"|"body"|"integrity"|"referrer"),`String _ -> true
        | "keepalive",`Bool _ -> true
        | "headers",`Assoc values -> strings values
            && List.length values=List.length (List.sort_uniq String.compare (List.map fst values))
        | "cache",`String ("default"|"no-store"|"reload"|"no-cache"|"force-cache"|"only-if-cached")
        | "credentials",`String ("omit"|"same-origin"|"include")
        | "mode",`String ("cors"|"no-cors"|"same-origin")
        | "redirect",`String ("follow"|"error"|"manual")
        | "referrerPolicy",`String (""|"no-referrer"|"no-referrer-when-downgrade"|"origin"|
            "origin-when-cross-origin"|"same-origin"|"strict-origin"|"strict-origin-when-cross-origin"|"unsafe-url") -> true
        | _,_ -> false in
      if valid then validate rest else Error ("invalid native fetch option " ^ name) in
  validate fields
let step_of_json value =
  let* fields = object_fields ["method";"selector";"text";"html";"key";"url";"value";"values";"state";"timeoutMs";
    "source";"argumentJson";"pollingMs";"fetchOptions"] value in
  let* method_ = text "method" fields in
  let arguments names = object_fields ("method" :: "timeoutMs" :: names) value in
  let selector () = text "selector" fields in
  let* timeout_ms = match List.assoc_opt "timeoutMs" fields with
    | None -> Ok None
    | Some _ -> Result.map Option.some (integer "timeoutMs" fields) in
  let* action = match method_ with
    | "click" | "dblclick" | "hover" ->
      let* _ = arguments ["selector"] in let* selector = selector () in
      (match method_ with "click" -> Ok (Click selector) | "dblclick" -> Ok (Double_click selector)
       | "hover" -> Ok (Hover selector) | _ -> Error "unknown native pointer method")
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
      let* _ = object_fields ["method";"text"] value in
      let* text = string_field "text" fields in
      (match method_ with
       | "keyboard.type" -> Ok (Keyboard_type text)
       | "keyboard.insertText" -> Ok (Keyboard_insert_text text)
       | _ -> Error "unknown native keyboard text method")
    | "keyboard.paste" ->
      let* _ = object_fields ["method";"text";"html"] value in
      let* text = string_field "text" fields in
      let* html = match List.assoc_opt "html" fields with
        | None -> Ok None
        | Some (`String html) -> Ok (Some html)
        | Some _ -> Error "html must be a string" in
      Ok (Keyboard_paste {text;html})
    | "keyboard.press" ->
      let* _ = object_fields ["method";"key"] value in
      let* key = text "key" fields in Ok (Keyboard_press key)
    | "selectOption" ->
      let* _ = arguments ["selector";"value";"values"] in let* selector = selector () in
      let* selection = match List.assoc_opt "value" fields, List.assoc_opt "values" fields with
        | Some (`String value), None -> Ok (One value)
        | None, Some (`List values) ->
          let rec decode seen = function
            | [] -> Ok (Many (List.rev seen))
            | `String value :: rest when not (List.mem value seen) -> decode (value :: seen) rest
            | _ -> Error "values must contain distinct strings" in decode [] values
        | _ -> Error "selectOption requires value or values" in
      Ok (Select_option {selector;selection})
    | "goto" -> let* _ = arguments ["url"] in let* raw = text "url" fields in
      let* url = url raw in Ok (Goto url)
    | "waitForURL" -> let* _ = arguments ["url"] in let* url = text "url" fields in Ok (Wait_for_url url)
    | "waitForSelector" -> let* _ = arguments ["selector";"state"] in
      let* selector = selector () in let* raw = text "state" fields in let* state = element_state raw in
      Ok (Wait_for_selector {selector;state})
    | "waitForLoadState" -> let* _ = arguments ["state"] in let* raw = text "state" fields in
      let* state = load_state raw in
      Ok (Wait_for_load_state state)
    | "evaluate" ->
      let* _=object_fields ["method";"source";"argumentJson"] value in
      let* code=page_code fields in Ok (Evaluate code)
    | "waitForFunction" ->
      let* _=arguments ["source";"argumentJson";"pollingMs"] in
      let* code=page_code fields in
      let* polling_ms=match List.assoc_opt "pollingMs" fields with
        | None -> Ok None | Some _ -> Result.map Option.some (integer "pollingMs" fields) in
      Ok (Wait_for_function {code;polling_ms})
    | "fetch" ->
      let* _=arguments ["url";"fetchOptions"] in
      let* raw=text "url" fields in let* url=url raw in
      let* options=fetch_options (match List.assoc_opt "fetchOptions" fields with None -> `Assoc [] | Some value -> value) in
      Ok (Fetch {url;options})
    | _ -> Error "unsupported native Page method" in
  Ok {action;timeout_ms}
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
  | Click _ | Double_click _ | Hover _ | Fill _ | Press _ | Focus _ | Reload
  | Keyboard_type _ | Keyboard_insert_text _ | Keyboard_paste _ | Keyboard_press _
  | Select_option _ | Goto _ | Evaluate _ | Wait_for_function _ | Fetch _ -> true
  | Wait_for_url _ | Wait_for_selector _ | Wait_for_load_state _ -> false
let method_name = function
  | Click _ -> "click" | Double_click _ -> "dblclick" | Hover _ -> "hover" | Fill _ -> "fill"
  | Press _ -> "press" | Select_option _ -> "selectOption" | Goto _ -> "goto" | Wait_for_url _ -> "waitForURL"
  | Focus _ -> "focus" | Reload -> "reload"
  | Keyboard_type _ -> "keyboard.type" | Keyboard_insert_text _ -> "keyboard.insertText"
  | Keyboard_paste _ -> "keyboard.paste" | Keyboard_press _ -> "keyboard.press"
  | Wait_for_selector _ -> "waitForSelector" | Wait_for_load_state _ -> "waitForLoadState"
  | Evaluate _ -> "evaluate" | Wait_for_function _ -> "waitForFunction" | Fetch _ -> "fetch"
let string value = `String value
let code_fields = function
  | Expression source -> ["source",string source]
  | Call {source;argument} -> ["source",string source;"argumentJson",string (Yojson.Safe.to_string argument)]
let step_to_json {action;timeout_ms} =
  let selector value = ["selector",string value] in
  let fields = match action with
    | Click s | Double_click s | Hover s | Focus s -> selector s
    | Fill {selector=s;text} -> selector s @ ["text",string text]
    | Press {selector=s;key} -> selector s @ ["key",string key]
    | Reload -> []
    | Keyboard_type text | Keyboard_insert_text text -> ["text",string text]
    | Keyboard_paste {text;html} -> ["text",string text]
        @ Option.to_list (Option.map (fun html -> "html",string html) html)
    | Keyboard_press key -> ["key",string key]
    | Select_option {selector=s;selection} -> selector s @
      (match selection with One value -> ["value",string value] | Many values -> ["values",`List (List.map string values)])
    | Goto url | Wait_for_url url -> ["url",string url]
    | Wait_for_selector {selector=s;state} -> selector s @ ["state",string (element_state_name state)]
    | Wait_for_load_state state -> ["state",string (load_state_name state)]
    | Evaluate code -> code_fields code
    | Wait_for_function {code;polling_ms} -> code_fields code
        @ Option.to_list (Option.map (fun value -> "pollingMs",`Int value) polling_ms)
    | Fetch {url;options} -> ["url",string url;"fetchOptions",options] in
  `Assoc (["method",string (method_name action)] @ fields @ Option.to_list (Option.map (fun n -> "timeoutMs",`Int n) timeout_ms))

let to_json {tab_id;expected_url;steps;snapshot_scope;max_chars} = `Assoc [
  "tabId",`Int tab_id;"expectedUrl",string expected_url;"steps",`List (List.map step_to_json steps);
  "snapshotScope",string (match snapshot_scope with Viewport -> "viewport" | Full_page -> "full_page");"maxChars",`Int max_chars]
