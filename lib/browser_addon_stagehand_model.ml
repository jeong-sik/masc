module Model = Browser_stagehand_model
module Exact = Lane_addon_exact
module Wire = Browser_stagehand_wire
let ( let* ) = Result.bind
let output_name = "stagehand"
let schema = `Assoc ["type",`String "object";"properties",`Assoc [];"additionalProperties",`Bool true]
let refused message = {Wire.code=Wire.host_refused;message}
let model_refusal reason = Model.refusal_to_rpc_error reason
let text (message:Model.message) =
  let* blocks=List.fold_right (fun block acc -> let* rest=acc in match block with
    | Model.Text text -> Ok (text::rest)
    | Unserved kind -> Error (model_refusal (Content_not_served kind))) message.content (Ok []) in
  Ok (`Assoc ["role",`String (match message.role with User -> "user" | Assistant -> "assistant");
    "text",`String (String.concat "\n\n" blocks)])
let request params =
  let* parsed=Model.parse_params params |> Result.map_error (fun detail -> model_refusal (Params_malformed detail)) in
  let* schema=match parsed.generation with
    | Structured {schema;name=_} -> Ok schema
    | Text_generation -> Error (model_refusal (Generation_not_served Text_generation_requested))
    | Tool_generation {tool_names} -> Error (model_refusal (Generation_not_served (Tool_generation_requested {tool_names}))) in
  let* ()=match parsed.temperature,parsed.stop_sequences with
    | None,None -> Ok ()
    | Some _,(None|Some _) | None,Some _ ->
        Error (refused "the Add-on model route does not serve request temperature or stop sequences") in
  let* messages=List.fold_right (fun message acc -> let* rest=acc in let* message=text message in
    Ok (message::rest)) parsed.messages (Ok []) in
  let id=Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ())) in
  Exact.request_of_json (`Assoc (["kind",`String "exact_output";"request_id",`String id;
    "output",`String output_name;"schema",schema;"messages",`List messages]
    @ (match parsed.system_prompt with None -> [] | Some system -> ["system",`String system])))
    |> Result.map_error (fun detail -> refused ("invalid Add-on model request: " ^ detail))
let usage (value:Exact.usage) : Agent_core.Types.api_usage =
  {input_tokens=value.input_tokens;output_tokens=value.output_tokens;
   cache_creation_input_tokens=0;cache_read_input_tokens=0;cost_usd=None}
let generate owner params =
  let* request=request params in
  let* outcome=Browser_addon_owner.generate owner request |> Result.map_error (fun error ->
    let detail=match error with
      | Browser_addon_models.Retired -> "browser model owner retired"
      | Output_disabled _ -> "browser model output disabled"
      | Request_in_use -> "browser model request id already used"
      | Receipt_failed _ -> "browser model receipt could not be committed"
      | Invalid_result _ -> "browser model result was refused"
      | Schema_refused _ -> "browser model schema authority was refused" in
    refused detail) in
  match outcome with
  | Browser_addon_models.Final (Exact.Call_final (Answered {output;usage=counts;slot=_})) ->
      Ok (Model.answer_of_output ?usage:(Option.map usage counts) (Exact.checked_json output))
  | Final (Call_final (Invalid_output _)) -> Error (refused "model output did not pass the declared contract")
  | Final (Call_final (Input_refused _)) -> Error (refused "model provider refused this input")
  | Final Outcome_unknown -> Error (refused "model outcome is unknown; this call must not be replayed")
  | Final (Not_allowed _) -> Error (refused "model output authority was refused")
  | Final Request_id_reused -> Error (refused "model request identity was reused")
  | Exceeds_frame _ -> Error (refused "model result exceeds the private browser frame")
let for_owner owner = match Browser_addon_owner.model_output owner ~name:output_name with
  | None -> Ok None
  | Some output ->
      let* ()=match output.Lane_addon_types.request_schema with
        | Package_schema_only -> Error "Stagehand requires an explicit package request-schema grant"
        | Consumer_request_schema -> Ok () in
      let* actual=Lane_addon_action.canonical output.schema in
      let* expected=Lane_addon_action.canonical schema in
      if actual=expected then Ok (Some (generate owner))
      else Error "Stagehand model baseline differs from the consumer contract"
