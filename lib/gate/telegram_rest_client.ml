type error =
  | Invalid_request of string
  | Invalid_response of string
  | Transport_failed
  | Http_status of int
  | Api_error of {status:int; code:int; retry_after:int option; migrate_to_chat_id:int64 option}

let pp_error fmt = function
  | Invalid_request field -> Format.fprintf fmt "telegram invalid request: %s" field
  | Invalid_response field -> Format.fprintf fmt "telegram invalid response: %s" field
  | Transport_failed -> Format.pp_print_string fmt "telegram transport failed"
  | Http_status status -> Format.fprintf fmt "telegram HTTP %d" status
  | Api_error {status;code;retry_after;migrate_to_chat_id} ->
    Format.fprintf fmt "telegram API %d (HTTP %d, retry_after=%a, migrate_to_chat_id=%a)"
      code status (Format.pp_print_option Format.pp_print_int) retry_after
      (Format.pp_print_option (fun f v -> Format.fprintf f "%Ld" v)) migrate_to_chat_id

(* No derived printer or raw credential accessor. *)
type t = {token:string}
let create ~token =
  if String.trim token = "" then Error (Invalid_request "token") else Ok {token}

type user = {id:int64;is_bot:bool;first_name:string;username:string option}
type message = {
  chat_id:int64; message_id:int; message_thread_id:int option;
  from_user:user option; text:string option; caption:string option;
}
type update_kind = Message of message | Edited_message of message | Unsupported
type update = {update_id:int64;kind:update_kind}
type post = url:string -> body:string -> ((int * string),unit) result

let ( let* ) = Result.bind
let invalid field = Error (Invalid_response field)
let object_fields field = function `Assoc fields -> Ok fields | _ -> invalid field
let required field decode fields =
  match List.assoc_opt field fields with None -> invalid field | Some json -> decode field json
let optional field decode fields =
  match List.assoc_opt field fields with
  | None -> Ok None
  | Some json -> Result.map Option.some (decode field json)
let integer64 field = function
  | `Int n -> Ok (Int64.of_int n)
  | `Intlit n -> (match Int64.of_string_opt n with Some n -> Ok n | None -> invalid field)
  | _ -> invalid field
let nonnegative64 field json =
  let* n = integer64 field json in if n >= 0L then Ok n else invalid field
let nonnegative field = function `Int n when n >= 0 -> Ok n | _ -> invalid field
let string field = function `String s -> Ok s | _ -> invalid field
let boolean field = function `Bool b -> Ok b | _ -> invalid field
let user field json =
  let* fields = object_fields field json in
  let* id = required "id" nonnegative64 fields in
  let* is_bot = required "is_bot" boolean fields in
  let* first_name = required "first_name" string fields in
  let* username = optional "username" string fields in
  Ok {id;is_bot;first_name;username}
let message json =
  let* fields = object_fields "message" json in
  let* message_id = required "message_id" nonnegative fields in
  let* chat = required "chat" object_fields fields in
  let* chat_id = required "id" integer64 chat in
  let* message_thread_id = optional "message_thread_id" nonnegative fields in
  let* from_user = optional "from" user fields in
  let* text = optional "text" string fields in
  let* caption = optional "caption" string fields in
  Ok {chat_id;message_id;message_thread_id;from_user;text;caption}
let update json =
  let* fields = object_fields "update" json in
  let* update_id = required "update_id" nonnegative64 fields in
  let* kind = match List.assoc_opt "message" fields,List.assoc_opt "edited_message" fields with
    | Some json,None -> Result.map (fun m -> Message m) (message json)
    | None,Some json -> Result.map (fun m -> Edited_message m) (message json)
    | None,None -> Ok Unsupported
    | Some _,Some _ -> invalid "multiple update kinds" in
  Ok {update_id;kind}

let api_result ~status ~body =
  let successful_http = status >= 200 && status < 300 in
  match Gate_rest_json.parse ~context:"telegram" body with
  | Error _ -> if successful_http then invalid "JSON" else Error (Http_status status)
  | Ok parsed ->
    let* fields = object_fields "envelope" (Gate_rest_json.to_yojson parsed) in
    let* ok = required "ok" boolean fields in
    if ok then
      if successful_http then required "result" (fun _ json -> Ok json) fields
      else Error (Http_status status)
    else
      let* code = required "error_code" nonnegative fields in
      let* parameters = optional "parameters" object_fields fields in
      let* retry_after,migrate_to_chat_id = match parameters with
        | None -> Ok (None,None)
        | Some fields ->
          let* retry = optional "retry_after" nonnegative fields in
          let* migrate = optional "migrate_to_chat_id" integer64 fields in
          Ok (retry,migrate) in
      Error (Api_error {status;code;retry_after;migrate_to_chat_id})

let parse_updates_response ~status ~body =
  let* json = api_result ~status ~body in
  match json with
  | `List entries ->
    let rec collect previous acc = function
      | [] -> Ok (List.rev acc)
      | json :: rest ->
        let* entry = update json in
        if Option.fold ~none:false ~some:(fun n -> entry.update_id <= n) previous
        then invalid "update order"
        else collect (Some entry.update_id) (entry :: acc) rest in
    collect None [] entries
  | _ -> invalid "updates"
let parse_message_response ~status ~body =
  let* json = api_result ~status ~body in message json

let call ?post ?clock ?timeout_sec client method_name fields parse =
  let url = "https://api.telegram.org/bot" ^ Uri.pct_encode ~component:(`Custom (`Path,"",":/")) client.token ^ "/" ^ method_name in
  let body = Yojson.Safe.to_string (`Assoc fields) in
  let result = match post with
    | Some post -> post ~url ~body
    | None ->
      Masc_http_client.post_sync ?clock ?timeout_sec ~url
        ~headers:["Content-Type","application/json"] ~body ()
      |> Result.map_error (fun _ -> ()) in
  match result with
  | Error () -> Error Transport_failed
  | Ok (status,body) -> parse ~status ~body

let int64_json n = `Intlit (Int64.to_string n)
let add_optional key encode value fields =
  match value with None -> fields | Some value -> fields @ [key,encode value]
let get_updates ?post ?clock ?timeout_sec client ?offset ~poll_timeout_sec () =
  if poll_timeout_sec < 0 then Error (Invalid_request "poll_timeout_sec")
  else if Option.fold ~none:false ~some:(fun n -> n < 0L) offset
  then Error (Invalid_request "offset")
  else
    let timeout_sec = match timeout_sec with Some _ -> timeout_sec
      | None -> Some (float_of_int poll_timeout_sec +. Masc_http_client.default_request_timeout_sec) in
    let fields = ["timeout",`Int poll_timeout_sec;
      "allowed_updates",`List [`String "message";`String "edited_message"]]
      |> add_optional "offset" int64_json offset in
    call ?post ?clock ?timeout_sec client "getUpdates" fields parse_updates_response
let send_message ?post ?clock ?(timeout_sec=Masc_http_client.default_request_timeout_sec)
    client ~chat_id ?message_thread_id ?reply_to_message_id ~text () =
  if Option.fold ~none:false ~some:(fun n -> n <= 0) message_thread_id
     || Option.fold ~none:false ~some:(fun n -> n <= 0) reply_to_message_id
  then Error (Invalid_request "message coordinates")
  else if text = "" then Error (Invalid_request "text")
  else
    let fields = ["chat_id",int64_json chat_id;"text",`String text]
      |> add_optional "message_thread_id" (fun n -> `Int n) message_thread_id
      |> add_optional "reply_parameters" (fun n -> `Assoc ["message_id",`Int n]) reply_to_message_id in
    call ?post ?clock ~timeout_sec client "sendMessage" fields parse_message_response
let edit_message_text ?post ?clock ?(timeout_sec=Masc_http_client.default_request_timeout_sec)
    client ~chat_id ~message_id ~text () =
  if message_id <= 0 then Error (Invalid_request "message_id")
  else if text = "" then Error (Invalid_request "text")
  else call ?post ?clock ~timeout_sec client "editMessageText"
    ["chat_id",int64_json chat_id;"message_id",`Int message_id;"text",`String text]
    parse_message_response
