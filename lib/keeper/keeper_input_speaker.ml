type external_speaker =
  { channel : string
  ; user_id : string option
  ; user_name : string option
  }

type person =
  | Owner
  | Keeper of Keeper_identity.Keeper_id.t
  | External of external_speaker

type host_prompt =
  | Autonomous_wake of { answered_asks : person list }
  | Official_client_resume

type t =
  | Host_prompt of host_prompt
  | Person of person

type classification =
  | Absent
  | Present of t
  | Invalid of string
  | Duplicate

let equal_person left right =
  match left, right with
  | Owner, Owner -> true
  | Keeper left, Keeper right -> Keeper_identity.Keeper_id.equal left right
  | External left, External right ->
    String.equal left.channel right.channel
    && Option.equal String.equal left.user_id right.user_id
    && Option.equal String.equal left.user_name right.user_name
  | Owner, (Keeper _ | External _)
  | Keeper _, (Owner | External _)
  | External _, (Owner | Keeper _) -> false
;;

let equal left right =
  match left, right with
  | Person left, Person right -> equal_person left right
  | ( Host_prompt (Autonomous_wake { answered_asks = left })
    , Host_prompt (Autonomous_wake { answered_asks = right }) ) ->
    List.equal equal_person left right
  | Host_prompt Official_client_resume, Host_prompt Official_client_resume -> true
  | Host_prompt (Autonomous_wake _), Host_prompt Official_client_resume
  | Host_prompt Official_client_resume, Host_prompt (Autonomous_wake _)
  | Person _, Host_prompt _ | Host_prompt _, Person _ -> false
;;

let string_option_to_json = function
  | None -> `Null
  | Some value -> `String value
;;

let person_to_json = function
  | Owner -> `Assoc [ "kind", `String "owner" ]
  | Keeper keeper_id ->
    `Assoc
      [ "kind", `String "keeper"
      ; "keeper_id", `String (Keeper_identity.Keeper_id.to_string keeper_id)
      ]
  | External { channel; user_id; user_name } ->
    `Assoc
      [ "kind", `String "external"
      ; "channel", `String channel
      ; "user_id", string_option_to_json user_id
      ; "user_name", string_option_to_json user_name
      ]
;;

let to_json = function
  | Person person -> person_to_json person
  | Host_prompt (Autonomous_wake { answered_asks }) ->
    `Assoc
      [ "kind", `String "host_prompt"
      ; "host_prompt", `String "autonomous_wake"
      ; "answered_asks", `List (List.map person_to_json answered_asks)
      ]
  | Host_prompt Official_client_resume ->
    `Assoc
      [ "kind", `String "host_prompt"; "host_prompt", `String "official_client_resume" ]
;;

let ( let* ) = Result.bind

(* Exact field sets: a field this module does not write is a broken writer. *)
let fields_exactly expected = function
  | `Assoc fields ->
    let names = List.map fst fields |> List.sort String.compare in
    if List.equal String.equal names (List.sort String.compare expected)
    then Ok fields
    else
      Error
        (Printf.sprintf
           "input speaker fields [%s], expected [%s]"
           (String.concat "," names)
           (String.concat "," expected))
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "input speaker must be a JSON object"
;;

let kind_of = function
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields with
     | Some (`String kind) -> Ok kind
     | Some _ | None -> Error "input speaker kind must be a string")
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "input speaker must be a JSON object"
;;

let field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "input speaker %s is missing" name)
;;

let string_field name fields =
  let* value = field name fields in
  match value with
  | `String value -> Ok value
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ ->
    Error (Printf.sprintf "input speaker %s must be a string" name)
;;

let string_option_field name fields =
  let* value = field name fields in
  match value with
  | `Null -> Ok None
  | `String value -> Ok (Some value)
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ ->
    Error (Printf.sprintf "input speaker %s must be a string or null" name)
;;

let list_field name fields =
  let* value = field name fields in
  match value with
  | `List values -> Ok values
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ ->
    Error (Printf.sprintf "input speaker %s must be a list" name)
;;

let person_of_json json =
  let* kind = kind_of json in
  match kind with
  | "owner" ->
    let* _ = fields_exactly [ "kind" ] json in
    Ok Owner
  | "keeper" ->
    let* fields = fields_exactly [ "kind"; "keeper_id" ] json in
    let* raw = string_field "keeper_id" fields in
    (match Keeper_identity.Keeper_id.of_string raw with
     | Some keeper_id when String.equal (Keeper_identity.Keeper_id.to_string keeper_id) raw ->
       Ok (Keeper keeper_id)
     | Some _ | None -> Error "input speaker keeper_id is not a canonical Keeper id")
  | "external" ->
    let* fields = fields_exactly [ "kind"; "channel"; "user_id"; "user_name" ] json in
    let* channel = string_field "channel" fields in
    let* user_id = string_option_field "user_id" fields in
    let* user_name = string_option_field "user_name" fields in
    Ok (External { channel; user_id; user_name })
  | other -> Error (Printf.sprintf "input speaker person kind %S is unknown" other)
;;

let of_json json =
  let* kind = kind_of json in
  match kind with
  | "host_prompt" ->
    let* host_prompt =
      match json with
      | `Assoc fields -> string_field "host_prompt" fields
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
        Error "input speaker must be a JSON object"
    in
    (match host_prompt with
     | "official_client_resume" ->
       let* _ = fields_exactly [ "kind"; "host_prompt" ] json in
       Ok (Host_prompt Official_client_resume)
     | "autonomous_wake" ->
       let* fields = fields_exactly [ "kind"; "host_prompt"; "answered_asks" ] json in
       let* answered_asks = list_field "answered_asks" fields in
       let* answered_asks =
         List.fold_right
           (fun json acc ->
              let* acc = acc in
              let* person = person_of_json json in
              Ok (person :: acc))
           answered_asks
           (Ok [])
       in
       Ok (Host_prompt (Autonomous_wake { answered_asks }))
     | other -> Error (Printf.sprintf "input speaker host prompt %S is unknown" other))
  | "owner" | "keeper" | "external" ->
    let* person = person_of_json json in
    Ok (Person person)
  | other -> Error (Printf.sprintf "input speaker kind %S is unknown" other)
;;

let metadata speaker = [ Agent_core.Types.Input_speaker.entry (to_json speaker) ]

let classify metadata =
  match Agent_core.Types.Input_speaker.classify metadata with
  | Agent_core.Types.Input_speaker.Absent -> Absent
  | Agent_core.Types.Input_speaker.Duplicate -> Duplicate
  | Agent_core.Types.Input_speaker.Present json ->
    (match of_json json with
     | Ok speaker -> Present speaker
     | Error detail -> Invalid detail)
;;

let of_ask_responder (responder : Keeper_ask.responder) =
  match responder.Keeper_ask.surface with
  | Surface_ref.Dashboard _ -> Owner
  | ( Surface_ref.Discord _
    | Surface_ref.Slack _
    | Surface_ref.Webhook _
    | Surface_ref.Agent
    | Surface_ref.Broadcast
    | Surface_ref.Gate _ ) as surface ->
    External
      { channel = Surface_ref.lane_label surface
      ; user_id = responder.Keeper_ask.actor_id
      ; user_name = responder.Keeper_ask.display_name
      }
;;

let person_header_value = function
  | Owner -> "owner"
  | Keeper keeper_id ->
    Printf.sprintf "keeper:%S" (Keeper_identity.Keeper_id.to_string keeper_id)
  | External { channel; user_id; user_name } ->
    let optional name = function
      | None -> []
      | Some value -> [ Printf.sprintf "%s=%S" name value ]
    in
    Printf.sprintf
      "external{%s}"
      (String.concat
         ","
         ((Printf.sprintf "channel=%S" channel :: optional "user_id" user_id)
          @ optional "user_name" user_name))
;;

let header_value = function
  | Absent -> "unknown"
  | Present (Person person) -> person_header_value person
  | Present (Host_prompt (Autonomous_wake { answered_asks = [] })) ->
    "host:autonomous_wake"
  | Present (Host_prompt (Autonomous_wake { answered_asks })) ->
    Printf.sprintf
      "host:autonomous_wake(answered_asks=%s)"
      (String.concat "," (List.map person_header_value answered_asks))
  | Present (Host_prompt Official_client_resume) -> "host:official_client_resume"
  | Invalid detail -> Printf.sprintf "invalid(%S)" detail
  | Duplicate -> "duplicate"
;;
