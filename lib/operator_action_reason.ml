open Result.Syntax

type cause =
  | Shutdown_fenced_backlog of { count : int; keepers : (string * int) list option; complete : bool }
  | Other_reported

type t = { component : string; reason : string; cause : cause }
let other ~component ~reason = { component; reason; cause = Other_reported }
let diagnostic item = item.component ^ ":" ^ item.reason
let shutdown_fenced_backlog ~count ~keepers ~complete =
  { component = "keeper_event_queue"; reason = Printf.sprintf "shutdown_fenced_backlog=%d" count
  ; cause = Shutdown_fenced_backlog {count; keepers; complete} }
let equal (left : t) right = left = right
let int = function `Int n when n >= 0 -> Ok n | _ -> Error "expected a nonnegative count"
let bool = function `Bool value -> Ok value | _ -> Error "expected a boolean"
let context = "operator action"
let field name decode = Candle_json.field ~context name decode
let finish = Candle_json.finish ~context
let owner ~allow_metadata json =
  let* fields = Candle_json.object_fields ~context json in
  let* keeper, fields = field "keeper_name" Candle_json.as_non_blank fields in
  let* count, fields = field "pending_count" int fields in
  let+ () = if allow_metadata then Ok () else finish fields in keeper, count
let valid_keepers ~count keepers =
  let rec loop remaining seen = function
    | [] -> remaining = 0
    | (keeper, n) :: rest ->
        n > 0 && n <= remaining && not (List.mem keeper seen)
        && loop (remaining - n) (keeper :: seen) rest
  in loop count [] keepers
let queue_keepers ~count json =
  match Candle_json.as_list (owner ~allow_metadata:true) json with
  | Ok keepers when valid_keepers ~count keepers -> Some keepers
  | Ok _ | Error _ -> None
let to_json item =
  let optional encode = function None -> `Null | Some value -> encode value in
  let kind, fields = match item.cause with
    | Shutdown_fenced_backlog {count; keepers; complete} ->
        "shutdown_fenced_backlog",
        ["count", `Int count; "counts_complete", `Bool complete;
         "keepers", optional (fun rows -> `List (List.map (fun (keeper, n) ->
           `Assoc ["keeper_name", `String keeper; "pending_count", `Int n]) rows)) keepers]
    | Other_reported -> "reported", []
  in `Assoc (["schema", `String "masc.operator_action.v1";
               "kind", `String kind; "component", `String item.component; "reason", `String item.reason] @ fields)
let of_json json =
  let* fields = Candle_json.object_fields ~context json in
  let* schema, fields = field "schema" Candle_json.as_string fields in
  let* () = if schema = "masc.operator_action.v1" then Ok () else Error "unknown operator-action schema" in
  let* kind, fields = field "kind" Candle_json.as_string fields in
  let* component, fields = field "component" Candle_json.as_non_blank fields in
  let* reason, fields = field "reason" Candle_json.as_string fields in
  let* item, fields = match kind with
    | "shutdown_fenced_backlog" ->
        let* count, fields = field "count" int fields in
        let* complete, fields = field "counts_complete" bool fields in
        let* keepers, fields = field "keepers"
            (Candle_json.as_nullable (Candle_json.as_list (owner ~allow_metadata:false))) fields in
        let* () = if count > 0 && Option.fold ~none:true ~some:(valid_keepers ~count) keepers then Ok ()
          else Error "invalid fenced-backlog ownership" in
        Ok (shutdown_fenced_backlog ~count ~keepers ~complete, fields)
    | "reported" -> Ok (other ~component ~reason, fields)
    | _ -> Ok (other ~component ~reason, [])
  in
  let* () = finish fields in
  if String.equal item.component component && String.equal item.reason reason then Ok item
  else Error "operator action diagnostic disagrees with its cause"
let read_collection ~diagnostics json =
  let* items = Candle_json.as_list of_json json in
  if List.map diagnostic items <> diagnostics then
    Error "operator action collection disagrees with its diagnostics"
  else Ok items
