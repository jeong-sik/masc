let supported_protocol_major = 2
let protocol_version = Printf.sprintf "%d.0.0" supported_protocol_major
let send_to_host_binding = "__stagehandSendToHost"
let receive_from_host_function = "__stagehandReceiveFromHost"
let client_name = "masc"

let deliver_expression message =
  Printf.sprintf "void globalThis.%s(%s); true" receive_from_host_function
    (Yojson.Safe.to_string (`String message))
;;

let runtime_marker_global = "__stagehand_runtime"

(* Answers at once; the host polls it. Where CDP evaluates in the extension's
   service worker there is no setTimeout (Chrome for Testing 154,
   2026-09-24), so the page cannot wait by itself. *)
let readiness_expression =
  Printf.sprintf {|({ receiver: typeof globalThis.%s === "function", marker: globalThis.%s ?? null })|}
    receive_from_host_function runtime_marker_global
;;

type marker = { protocol_version : string; runtime_version : string }
type readiness = Not_ready | Ready of marker

let ( let* ) = Result.bind
let field key = function `Assoc fields -> List.assoc_opt key fields | _ -> None

let string_at path json =
  let rec walk json = function
    | [] -> (match json with `String value -> Ok value | _ -> Error (String.concat "." path ^ " is not a string"))
    | key :: rest -> (match field key json with Some next -> walk next rest | None -> Error (String.concat "." path ^ " is missing"))
  in
  walk json path
;;

let marker_of_json json =
  let* protocol_version = string_at [ "protocolVersion" ] json in
  let* runtime_version = string_at [ "serverInfo"; "version" ] json in
  Ok { protocol_version; runtime_version }
;;

(* Ready once the receiver is installed and the marker set; the runtime
   installs the receiver first. *)
let readiness_of_json json =
  match field "receiver" json, field "marker" json with
  | Some (`Bool true), Some (`Assoc _ as marker) -> Result.map (fun marker -> Ready marker) (marker_of_json marker)
  | Some (`Bool (true | false)), Some `Null | Some (`Bool false), Some (`Assoc _) -> Ok Not_ready
  | (Some _ | None), (Some _ | None) -> Error "the readiness check answered without receiver and marker"
;;

let is_digit = function '0' .. '9' -> true | _ -> false

(* Digits only: int_of_string_opt would also read "0x2", "+2" or "2_0". *)
let protocol_major marker =
  match String.split_on_char '.' marker.protocol_version with
  | leading :: _ when leading <> "" && String.for_all is_digit leading -> Ok (int_of_string leading)
  | _ :: _ | [] -> Error ("protocol version " ^ marker.protocol_version ^ " has no numeric major")
;;

(* Chrome ids are 32 letters from a to p. *)
let extension_id_length = 32

let extension_id_of_real_path path =
  let hex = Digestif.SHA256.(to_hex (digest_string path)) in
  String.init extension_id_length (fun i ->
    Char.chr (Char.code 'a' + int_of_string ("0x" ^ String.make 1 hex.[i])))
;;

type id = Int_id of int | String_id of string
type rpc_error = { code : int; message : string }

let method_not_found = -32601
let host_refused = -32000

type extension_request =
  | Llm_generate of { id : id; params : Yojson.Safe.t }
  | Unsupported_request of { id : id; method_ : string }

type extension_notification =
  | Log of Yojson.Safe.t option
  | Page_event of Yojson.Safe.t option
  | Unsupported_notification of { method_ : string }

type incoming =
  | Response of { id : id; result : (Yojson.Safe.t, rpc_error) result }
  | Request of extension_request
  | Notification of extension_notification

let request_of ~id method_ params =
  match method_, params with
  | "llm.generate", Some params -> Ok (Llm_generate { id; params })
  | "llm.generate", None -> Error "llm.generate without params"
  | _, (Some _ | None) -> Ok (Unsupported_request { id; method_ })
;;

let notification_of method_ params =
  match method_ with
  | "stagehand.log" -> Log params
  | "page.event" | "page.cdp_event" -> Page_event params
  | _ -> Unsupported_notification { method_ }
;;

let decode payload =
  match Yojson.Safe.from_string payload with
  | exception Yojson.Json_error detail -> Error ("invalid Stagehand JSON: " ^ detail)
  | json ->
    let id =
      match field "id" json with
      | Some (`Int n) -> Some (Int_id n)
      | Some (`String s) -> Some (String_id s)
      | Some _ | None -> None
    in
    let params = field "params" json in
    (match field "method" json, id with
     | Some (`String method_), Some id -> Result.map (fun request -> Request request) (request_of ~id method_ params)
     | Some (`String method_), None -> Ok (Notification (notification_of method_ params))
     | None, Some id ->
       (match field "result" json, field "error" json with
        | Some result, None -> Ok (Response { id; result = Ok result })
        | None, Some error ->
          (match field "code" error, field "message" error with
           | Some (`Int code), Some (`String message) -> Ok (Response { id; result = Error { code; message } })
           | _ -> Error "Stagehand error response without an integer code and a message")
        | Some _, Some _ | None, None -> Error "Stagehand response without exactly one of result and error")
     | Some _, _ | None, None -> Error "Stagehand message is neither a request, a notification nor a response")
;;

type call =
  | Init of { client_version : string; browser_cdp_url : string }
  | Close
  | Act of { page_id : string; instruction : string }
  | Observe of { page_id : string; instruction : string option }
  | Extract of { page_id : string; instruction : string; schema : Yojson.Safe.t option }
  | Context_pages
  | Context_active_page
  | Page_goto of { page_id : string; url : string }
  | Page_screenshot of { page_id : string }
  | Page_evaluate of { page_id : string; expression : string }
  | Page_click of { page_id : string; x : float; y : float }
  | Page_scroll of { page_id : string; x : float; y : float; delta_x : float; delta_y : float }
  | Page_drag_and_drop of { page_id : string; from_x : float; from_y : float; to_x : float; to_y : float }

let method_name = function
  | Init _ -> "stagehand.init"
  | Close -> "stagehand.close"
  | Act _ -> "stagehand.act"
  | Observe _ -> "stagehand.observe"
  | Extract _ -> "stagehand.extract"
  | Context_pages -> "context.pages"
  | Context_active_page -> "context.active_page"
  | Page_goto _ -> "page.goto"
  | Page_screenshot _ -> "page.screenshot"
  | Page_evaluate _ -> "page.evaluate"
  | Page_click _ -> "page.click"
  | Page_scroll _ -> "page.scroll"
  | Page_drag_and_drop _ -> "page.drag_and_drop"
;;

let optional key = function None -> [] | Some value -> [ key, value ]
let page page_id = [ "page_id", `String page_id ]

let call_params = function
  | Init { client_version; browser_cdp_url } ->
    `Assoc
      [ "protocol_version", `String protocol_version
      ; "client_info", `Assoc [ "name", `String client_name; "version", `String client_version ]
      ; (* Every model call comes back to the host as llm.generate. *)
        "model", `Assoc [ "source", `String "client" ]
      ; "browser_cdp_url", `String browser_cdp_url
      ]
  | Close | Context_pages | Context_active_page -> `Assoc []
  | Act { page_id; instruction } -> `Assoc (page page_id @ [ "instruction", `String instruction ])
  | Observe { page_id; instruction } ->
    `Assoc (page page_id @ optional "instruction" (Option.map (fun text -> `String text) instruction))
  | Extract { page_id; instruction; schema } ->
    `Assoc (page page_id @ [ "instruction", `String instruction ] @ optional "schema" schema)
  | Page_goto { page_id; url } -> `Assoc (page page_id @ [ "url", `String url ])
  | Page_screenshot { page_id } -> `Assoc (page page_id)
  | Page_evaluate { page_id; expression } -> `Assoc (page page_id @ [ "expression", `String expression ])
  | Page_click { page_id; x; y } -> `Assoc (page page_id @ [ "x", `Float x; "y", `Float y ])
  | Page_scroll { page_id; x; y; delta_x; delta_y } ->
    `Assoc (page page_id @ [ "x", `Float x; "y", `Float y; "delta_x", `Float delta_x; "delta_y", `Float delta_y ])
  | Page_drag_and_drop { page_id; from_x; from_y; to_x; to_y } ->
    `Assoc (page page_id @ [ "from_x", `Float from_x; "from_y", `Float from_y; "to_x", `Float to_x; "to_y", `Float to_y ])
;;

let uses_model = function
  | Act _ | Observe _ | Extract _ -> true
  | Init _ | Close | Context_pages | Context_active_page | Page_goto _ | Page_screenshot _ | Page_evaluate _
  | Page_click _ | Page_scroll _ | Page_drag_and_drop _ -> false
;;

let jsonrpc = "jsonrpc", `String "2.0"
let id_json = function Int_id n -> `Int n | String_id s -> `String s

let encode_call ~id call =
  Yojson.Safe.to_string
    (`Assoc [ jsonrpc; "id", `Int id; "method", `String (method_name call); "params", call_params call ])
;;

let encode_reply ~id result =
  let body =
    match result with
    | Ok value -> [ "result", value ]
    | Error { code; message } -> [ "error", `Assoc [ "code", `Int code; "message", `String message ] ]
  in
  Yojson.Safe.to_string (`Assoc ([ jsonrpc; "id", id_json id ] @ body))
;;
