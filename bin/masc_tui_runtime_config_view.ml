type routing_state = Routing_active | Routing_applied
type keeper_state = Not_configured | Pending_restart | Applied | Preempted_by_env | Mixed | Invalid_configuration
type severity = Error_issue | Warning_issue
type issue_kind = Invalid_schema_version | Unknown_key | Type_mismatch | Out_of_range
type issue = { key : string; kind : issue_kind; severity : severity; detail : string }
type validation =
  | Parse_error of string
  | Checked of {
      valid : bool; schema_version : int; current_schema_version : int;
      forward_schema : bool; issues : issue list;
    }
type metadata = {
  source_revision : string;
  validation : validation;
  routing : routing_state;
  routing_requires_restart : bool;
  keeper : keeper_state;
  keeper_requires_restart : bool;
  configured_count : int;
  pending_keys : string list;
  applied_keys : string list;
  preempted_keys : string list;
}
type reading = { path : string; source_text : string; metadata : metadata }
type tone = Neutral | Good | Warning | Bad

let ( let* ) = Result.bind
let field key = function
  | `Assoc fields -> (match List.filter (fun (name, _) -> name = key) fields with
      | [(_, value)] -> Ok value | [] -> Error ("missing " ^ key)
      | _ -> Error ("duplicate " ^ key))
  | _ -> Error "expected configuration response object"
let string = function `String value -> Ok value | _ -> Error "expected string"
let boolean = function `Bool value -> Ok value | _ -> Error "expected boolean"
let integer = function `Int value -> Ok value | _ -> Error "expected integer"
let get parse key json = let* value = field key json in parse value
let list parse = function
  | `List rows ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | row :: rest -> let* value = parse row in loop (value :: acc) rest
      in loop [] rows
  | _ -> Error "expected array"
let routing = function
  | `String "active" -> Ok Routing_active | `String "applied" -> Ok Routing_applied
  | _ -> Error "unknown routing application state"
let keeper = function
  | `String "not_configured" -> Ok Not_configured
  | `String "pending_restart" -> Ok Pending_restart
  | `String "applied" -> Ok Applied
  | `String "preempted_by_env" -> Ok Preempted_by_env
  | `String "mixed" -> Ok Mixed
  | `String "invalid" -> Ok Invalid_configuration
  | _ -> Error "unknown Keeper application state"
let severity = function
  | `String "error" -> Ok Error_issue | `String "warning" -> Ok Warning_issue
  | _ -> Error "unknown validation severity"
let issue_kind = function
  | `String "invalid_schema_version" -> Ok Invalid_schema_version
  | `String "unknown_key" -> Ok Unknown_key
  | `String "type_mismatch" -> Ok Type_mismatch
  | `String "out_of_range" -> Ok Out_of_range
  | _ -> Error "unknown validation issue kind"
let issue json =
  let* key = get string "key" json in
  let* kind = get issue_kind "kind" json in
  let* severity = get severity "severity" json in
  let* detail = get string "detail" json in
  Ok { key; kind; severity; detail }

let validation json =
  let* valid = get boolean "valid" json in
  let* issues = get (list issue) "issues" json in
  let parse_error = match json with
    | `Assoc fields -> List.filter (fun (key, _) -> key = "parse_error") fields
    | _ -> []
  in
  match parse_error with
  | [(_, `String detail)] when not valid && issues = [] -> Ok (Parse_error detail)
  | _ :: _ -> Error "invalid TOML parse error projection"
  | [] ->
      let* schema_version = get integer "schema_version" json in
      let* current_schema_version = get integer "current_schema_version" json in
      let* forward_schema = get boolean "forward_schema" json in
      if valid = List.exists (fun issue -> issue.severity = Error_issue) issues
      then Error "validation result contradicts its error issues"
      else Ok (Checked { valid; schema_version; current_schema_version; forward_schema; issues })

let decode json =
  let* ok = get boolean "ok" json in
  if not ok then Error "runtime config read failed" else
  let* path = get string "path" json in
  let* source_text = get string "source_text" json in
  let* source_revision = get string "source_revision" json in
  let* () = if source_revision = "" then Error "empty source revision" else Ok () in
  let* validation = get validation "validation" json in
  let* application = field "application" json in
  let* routing_json = field "routing" application in
  let* routing = get routing "status" routing_json in
  let* routing_requires_restart = get boolean "requires_restart" routing_json in
  let* keeper_json = field "keeper_overlay" application in
  let* keeper = get keeper "status" keeper_json in
  let* keeper_requires_restart = get boolean "requires_restart" keeper_json in
  let* configured_count = get integer "configured_count" keeper_json in
  let* () = if configured_count < 0 then Error "negative configured count" else Ok () in
  let* pending_keys = get (list string) "pending_keys" keeper_json in
  let* applied_keys = get (list string) "applied_keys" keeper_json in
  let* preempted_keys = get (list string) "preempted_keys" keeper_json in
  (* The server derives both projections from pending_keys. Accepting them
     independently could show 'restart not required' over unapplied settings. *)
  let pending = pending_keys <> [] in
  let* () =
    if keeper_requires_restart <> pending || (keeper = Pending_restart) <> pending
    then Error "Keeper restart status contradicts pending settings"
    else Ok ()
  in
  Ok { path; source_text; metadata = {
    source_revision; validation; routing; routing_requires_restart; keeper; keeper_requires_restart;
    configured_count; pending_keys; applied_keys; preempted_keys;
  } }

let routing_label = function Routing_active -> "active" | Routing_applied -> "applied"
let keeper_label = function
  | Not_configured -> "not configured" | Pending_restart -> "pending restart"
  | Applied -> "applied" | Preempted_by_env -> "preempted by environment" | Mixed -> "mixed"
  | Invalid_configuration -> "invalid configuration"
let issue_kind_label = function
  | Invalid_schema_version -> "invalid schema" | Unknown_key -> "unknown key"
  | Type_mismatch -> "type mismatch" | Out_of_range -> "out of range"
let restart metadata = metadata.routing_requires_restart || metadata.keeper_requires_restart
let validation_line = function
  | Parse_error _ -> Bad, "Validation: invalid TOML"
  | Checked report ->
      let count severity = List.length (List.filter (fun issue -> issue.severity = severity) report.issues) in
      (if report.valid then (if count Warning_issue = 0 then Good else Warning) else Bad),
      Printf.sprintf "Validation: %s · %d error(s), %d warning(s)"
        (if report.valid then "valid" else "invalid") (count Error_issue) (count Warning_issue)
let summary_lines metadata =
  let attention = restart metadata || metadata.preempted_keys <> [] in
  [ Neutral, "Source revision: " ^ metadata.source_revision;
    validation_line metadata.validation;
    (if metadata.keeper = Invalid_configuration then Bad else if attention then Warning else Neutral),
      Printf.sprintf "Routing %s · Keeper %s · restart %s"
        (routing_label metadata.routing) (keeper_label metadata.keeper)
        (if restart metadata then "required" else "not required") ]
let detail_lines metadata =
  let keys label tone values =
    if values = [] then [] else List.map (fun key -> tone, label ^ ": " ^ key) values
  in
  let validation = match metadata.validation with
    | Parse_error detail -> [Bad, "TOML parse error: " ^ detail]
    | Checked report ->
        [ (if report.forward_schema then Warning else Neutral),
          Printf.sprintf "Schema: %d · current %d%s" report.schema_version report.current_schema_version
            (if report.forward_schema then " · future schema" else "") ]
        @ List.map (fun issue ->
            (match issue.severity with Error_issue -> Bad | Warning_issue -> Warning),
            Printf.sprintf "%s · %s: %s" issue.key (issue_kind_label issue.kind) issue.detail) report.issues
  in
  summary_lines metadata
  @ [ (if metadata.routing_requires_restart then Warning else Neutral),
      "Routing restart: " ^ (if metadata.routing_requires_restart then "required" else "not required");
      (if metadata.keeper_requires_restart then Warning else Neutral),
      "Keeper restart: " ^ (if metadata.keeper_requires_restart then "required" else "not required") ]
  @ [Neutral, Printf.sprintf "Keeper settings configured: %d" metadata.configured_count]
  @ keys "Pending restart" Warning metadata.pending_keys
  @ keys "Preempted by environment" Warning metadata.preempted_keys
  @ validation
  @ keys "Applied" Neutral metadata.applied_keys
