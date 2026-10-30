open Result.Syntax

type declared_progress = Progress | No_progress | Failed
type t =
  { attribution : Agent_observation.attribution
  ; turn_ref : Ids.Turn_ref.t
  ; declared_progress : declared_progress option
  }

let fields expected = function
  | `Assoc fields
    when List.sort String.compare (List.map fst fields)
         = List.sort String.compare expected -> Ok fields
  | `Assoc _ -> Error "tool observation has missing, duplicate or unknown fields"
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "tool observation must be an object"

let string name fields =
  match List.assoc name fields with
  | `String value -> Ok value
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ ->
    Error "tool observation field must be a string"

let optional_string name fields =
  match List.assoc name fields with
  | `Null -> Ok None
  | `String value -> Ok (Some value)
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ ->
    Error "tool observation field must be a string or null"

let invalid_word = function
  | Agent_observation.Code_address.Empty_codebase -> "empty_codebase"
  | Malformed_codebase -> "malformed_codebase"
  | Empty_path -> "empty_path"
  | Absolute_path -> "absolute_path"
  | Malformed_path -> "malformed_path"
  | Unnormalized_path -> "unnormalized_path"

let invalid_of_word = function
  | "empty_codebase" -> Ok Agent_observation.Code_address.Empty_codebase
  | "malformed_codebase" -> Ok Agent_observation.Code_address.Malformed_codebase
  | "empty_path" -> Ok Agent_observation.Code_address.Empty_path
  | "absolute_path" -> Ok Agent_observation.Code_address.Absolute_path
  | "malformed_path" -> Ok Agent_observation.Code_address.Malformed_path
  | "unnormalized_path" -> Ok Agent_observation.Code_address.Unnormalized_path
  | _ -> Error "unknown tool observation address rejection"

let reason_json reason =
  let open Agent_observation.Unattributed in
  let kind, detail = match reason with
    | Unparseable_remote_url remote -> "unparseable_remote_url", Some remote
    | Unmintable invalid -> "unmintable", Some (invalid_word invalid)
    | (Blank_remote_url | Checkout_unavailable | Origin_missing
      | Origin_lookup_timed_out | Origin_lookup_failed | Unregistered_origin
      | Ambiguous_origin | Unregistered_path | Repository_catalog_unavailable) as reason ->
      reason_to_string reason, None
  in
  `Assoc [ "kind", `String kind
         ; "detail", (match detail with None -> `Null | Some value -> `String value) ]

let reason_of_json json =
  let* fields = fields [ "kind"; "detail" ] json in
  let* kind = string "kind" fields in
  let* detail = optional_string "detail" fields in
  let open Agent_observation.Unattributed in
  match kind, detail with
  | "blank_remote_url", None -> Ok Blank_remote_url
  | "unparseable_remote_url", Some remote -> Ok (Unparseable_remote_url remote)
  | "checkout_unavailable", None -> Ok Checkout_unavailable
  | "origin_missing", None -> Ok Origin_missing
  | "origin_lookup_timed_out", None -> Ok Origin_lookup_timed_out
  | "origin_lookup_failed", None -> Ok Origin_lookup_failed
  | "unregistered_origin", None -> Ok Unregistered_origin
  | "ambiguous_origin", None -> Ok Ambiguous_origin
  | "unregistered_path", None -> Ok Unregistered_path
  | "repository_catalog_unavailable", None -> Ok Repository_catalog_unavailable
  | "unmintable", Some detail ->
    let* invalid = invalid_of_word detail in Ok (Unmintable invalid)
  | _, (None | Some _) -> Error "invalid tool observation attribution reason"

let attribution_json = function
  | Agent_observation.Pathless -> `Assoc [ "kind", `String "pathless" ]
  | File (Addressed { address; checkout }) ->
    `Assoc [ "kind", `String "addressed"
           ; "codebase", `String (Agent_observation.Code_address.codebase address)
           ; "path", `String (Agent_observation.Code_address.path address)
           ; "checkout", (match checkout with None -> `Null | Some value -> `String value) ]
  | File (Unaddressed { reason; attempted_path }) ->
    `Assoc [ "kind", `String "unaddressed"; "reason", reason_json reason
           ; "attempted_path", `String attempted_path ]

let attribution_of_json json =
  let* kind = match json with
    | `Assoc fields ->
      (match List.assoc_opt "kind" fields with
       | Some (`String kind) -> Ok kind
       | Some _ | None -> Error "tool observation attribution kind is required")
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Error "tool observation attribution must be an object"
  in
  match kind with
  | "pathless" ->
    let* _ = fields [ "kind" ] json in Ok Agent_observation.Pathless
  | "addressed" ->
    let* fields = fields [ "kind"; "codebase"; "path"; "checkout" ] json in
    let* codebase = string "codebase" fields in
    let* path = string "path" fields in
    let* checkout = optional_string "checkout" fields in
    let* address = Agent_observation.Code_address.v ~codebase ~path
      |> Result.map_error Agent_observation.Code_address.invalid_to_string in
    Ok (Agent_observation.File (Addressed { address; checkout }))
  | "unaddressed" ->
    let* fields = fields [ "kind"; "reason"; "attempted_path" ] json in
    let* reason = reason_of_json (List.assoc "reason" fields) in
    let* attempted_path = string "attempted_path" fields in
    Ok (Agent_observation.File (Unaddressed { reason; attempted_path }))
  | _ -> Error "unknown tool observation attribution kind"

let declared_progress_word = function
  | Progress -> "progress"
  | No_progress -> "no_progress"
  | Failed -> "error"

let to_yojson observation =
  `Assoc [ "attribution", attribution_json observation.attribution
         ; "turn_ref", Ids.Turn_ref.to_yojson observation.turn_ref
         ; "declared_progress", (match observation.declared_progress with
             | None -> `Null | Some value -> `String (declared_progress_word value)) ]

let of_yojson json =
  let* fields = fields [ "attribution"; "turn_ref"; "declared_progress" ] json in
  let* attribution = attribution_of_json (List.assoc "attribution" fields) in
  let* turn_ref = Ids.Turn_ref.of_yojson (List.assoc "turn_ref" fields)
    |> Result.map_error (fun _ -> "tool observation turn reference is invalid") in
  let* declared_progress = match List.assoc "declared_progress" fields with
    | `Null -> Ok None
    | `String "progress" -> Ok (Some Progress)
    | `String "no_progress" -> Ok (Some No_progress)
    | `String "error" -> Ok (Some Failed)
    | `String _ | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ ->
      Error "invalid tool observation progress declaration"
  in
  Ok { attribution; turn_ref; declared_progress }

let addressed observation = match observation.attribution with
  | Agent_observation.File (Addressed addressed) -> Some addressed
  | File (Unaddressed _) | Pathless -> None

let of_row = function
  | `Assoc fields ->
    (match List.filter (fun (name, _) -> String.equal name "tool_observation") fields with
     | [] -> Ok None
     | [ _, json ] -> Result.map Option.some (of_yojson json)
     | _ :: _ :: _ -> Error "duplicate tool observation")
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "tool-call row must be an object"
