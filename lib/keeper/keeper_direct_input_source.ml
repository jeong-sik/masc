type host_cue = Autonomous_wake | Official_client_resume
type source =
  | Keeper of Keeper_identity.Keeper_id.t
  | Local_request
  | External of Keeper_input_speaker.external_speaker
  | Host_cue of host_cue
type t = { operation_id : Keeper_chat_operation.Operation_id.t; source : source }

let of_admitted_input ~operation_id ~speaker =
  let source = match speaker with
    | Keeper_input_speaker.Person (Keeper_input_speaker.Keeper keeper_id) -> Keeper keeper_id
    | Keeper_input_speaker.Person Keeper_input_speaker.Owner -> Local_request
    | Keeper_input_speaker.Person (Keeper_input_speaker.External speaker) -> External speaker
    | Keeper_input_speaker.Host_prompt (Keeper_input_speaker.Autonomous_wake _) -> Host_cue Autonomous_wake
    | Keeper_input_speaker.Host_prompt Keeper_input_speaker.Official_client_resume -> Host_cue Official_client_resume in
  { operation_id; source }
;;

let source_json = function
  | Keeper keeper_id ->
    Keeper_input_speaker.to_json (Keeper_input_speaker.Person (Keeper_input_speaker.Keeper keeper_id))
  | Local_request -> `Assoc [ "kind", `String "local_request" ]
  | External speaker ->
    Keeper_input_speaker.to_json (Keeper_input_speaker.Person (Keeper_input_speaker.External speaker))
  | Host_cue cue ->
    `Assoc
      [ "kind", `String "host_prompt"
      ; "host_prompt", `String (match cue with
          | Autonomous_wake -> "autonomous_wake"
          | Official_client_resume -> "official_client_resume")
      ]
;;

let render source =
  let source_json =
    `Assoc
      [ "operation_id", `String (Keeper_chat_operation.Operation_id.to_string source.operation_id)
      ; "speaker", source_json source.source
      ]
    |> Yojson.Safe.to_string
  in
  let key = Prompt_names.keeper_context_direct_input_source in
  match Prompt_registry.render_prompt_template key [ "source_json", source_json ] with
  | Ok text -> text
  | Error detail -> key ^ ": " ^ detail
;;
