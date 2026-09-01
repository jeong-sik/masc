type capability = Invoke_turn

type target = Keeper of Keeper_id.Keeper_name.t

type request =
  { target : target
  ; prompt : string
  }

type direct_message =
  { request : request
  ; direct_reply : bool
  ; turn_instructions : string option
  ; surface_context : Yojson.Safe.t option
  ; channel_session_key : string option
  ; channel : string
  ; user_blocks : Keeper_multimodal_input.user_input_block list
  ; attachments : Keeper_chat_store.attachment list
  ; user_agent_core_blocks : Agent_core.Types.content_block list option
  }

type request_error =
  | Invalid_target of string
  | Empty_prompt
  | Invalid_multimodal_input of string
  | Invalid_wire_value of
      { field : string
      ; expected : string
      }

let ( let* ) = Result.bind

(* [expected] is read by a model deciding what to send next, so it is written
   in the vocabulary [Agent_core.Tool_input_validation] already uses on the
   schema layer: MISSING names an absent field and its type, "wrong type"
   names what arrived. (That layer also answers enum/const violations with
   "invalid value"; every check in this module is a JSON type check, so
   "wrong type" remains the whole vocabulary it needs.) A payload that clears
   the schema and fails here used to answer in a second vocabulary ("must be
   required field"), which named the rule rather than the correction -- live
   logs carry a Keeper trying target.agent, target.keeper_name, then
   target.keeper, one call each. *)
let invalid_wire_value ~field ~expected =
  Error (Invalid_wire_value { field; expected })
;;

let wrong_type ~field ~expected ~got =
  invalid_wire_value
    ~field
    ~expected:(Printf.sprintf "wrong type - expected: %s, got: %s" expected got)
;;

let received_kind (json : Yojson.Safe.t) =
  match json with
  | `Assoc _ -> "object"
  | `List _ -> "array"
  | `String value -> Printf.sprintf "string(%S)" value
  | `Int _ | `Intlit _ -> "integer"
  | `Float _ -> "number"
  | `Bool _ -> "boolean"
  | `Null -> "null"
;;

let object_fields ~field = function
  | `Assoc fields -> Ok fields
  | other -> wrong_type ~field ~expected:"object" ~got:(received_kind other)
;;

let exact_fields ~field ~allowed fields =
  let keys = List.map fst fields in
  if List.length keys <> List.length (List.sort_uniq String.compare keys)
  then invalid_wire_value ~field ~expected:"object with unique fields"
  else
    match List.find_opt (fun key -> not (List.mem key allowed)) keys with
    | None -> Ok ()
    | Some key ->
      (* [allowed] is the answer the caller is looking for, and dropping it
         made the rejection unactionable: live logs carry a Keeper trying
         target.agent, then target.keeper_name, then target.keeper, one per
         call, against an allowed list of kind and name. Naming the accepted
         fields turns three round trips into one. *)
      invalid_wire_value
        ~field:(field ^ "." ^ key)
        ~expected:
          (Printf.sprintf "UNKNOWN FIELD (accepted: %s)"
             (String.concat ", " allowed))
;;

let required_field ?(kind = "string") ~field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None ->
    invalid_wire_value
      ~field:(field ^ "." ^ name)
      ~expected:(Printf.sprintf "MISSING (required: %s)" kind)
;;

let string_value ~field = function
  | `String value -> Ok value
  | other -> wrong_type ~field ~expected:"string" ~got:(received_kind other)
;;

let target_of_json json =
  let* fields = object_fields ~field:"target" json in
  let* () = exact_fields ~field:"target" ~allowed:[ "kind"; "name" ] fields in
  let* kind = required_field ~field:"target" "kind" fields in
  let* kind = string_value ~field:"target.kind" kind in
  let* name = required_field ~field:"target" "name" fields in
  let* name = string_value ~field:"target.name" name in
  if not (String.equal kind "keeper")
  then invalid_wire_value ~field:"target.kind" ~expected:"keeper"
  else
    Keeper_id.Keeper_name.of_string name
    |> Result.map (fun name -> Keeper name)
    |> Result.map_error (fun reason -> Invalid_target reason)
;;

let capability_of_json ~field = function
  | `String value when String.equal value "invoke_turn" -> Ok Invoke_turn
  | _ -> invalid_wire_value ~field ~expected:"invoke_turn"
;;

(* [capability] has one legal value, so a submitter cannot choose it -- it can
   only restate it or get it wrong. Every one of the week's 29 [delegate]
   rejections was this field: 22 said "task_assignment" and 7 said
   "claim_and_execute", which are descriptions of the prompt, not capabilities
   the contract offers. A field named [capability] reads as a menu.

   Absent now resolves to the single value. An explicit wrong one is still
   refused, so this admits nothing new -- it stops requiring a restatement. If a
   second capability is ever added, this default becomes a real choice and has
   to be revisited here, which is why it is written as an explicit arm rather
   than folded into [capability_of_json]. *)
let optional_capability_of_json ~field = function
  | None -> Ok Invoke_turn
  | Some json -> capability_of_json ~field json
;;

let request ~keeper_name ~prompt =
  let* keeper_name =
    Keeper_id.Keeper_name.of_string keeper_name
    |> Result.map_error (fun reason -> Invalid_target reason)
  in
  if String.equal prompt ""
  then Error Empty_prompt
  else Ok { target = Keeper keeper_name; prompt }
;;

let nonempty_trimmed_option = function
  | None -> None
  | Some value ->
    let value = String.trim value in
    if String.equal value "" then None else Some value
;;

let direct_message
      ~keeper_name
      ~prompt
      ~direct_reply
      ?turn_instructions
      ?surface_context
      ?channel_session_key
      ~channel
      ~user_blocks
      ~attachments
      ()
  =
  let* request = request ~keeper_name ~prompt in
  let* surface_context =
    match surface_context with
    | None -> Ok None
    | Some (`Assoc _ as context) -> Ok (Some context)
    | Some _ -> invalid_wire_value ~field:"surface_context" ~expected:"object"
  in
  let* user_agent_core_blocks =
    Keeper_multimodal_input.to_agent_core_blocks ~attachments user_blocks
    |> Result.map
         (function
           | [] -> None
           | blocks -> Some blocks)
    |> Result.map_error (fun reason -> Invalid_multimodal_input reason)
  in
  Ok
    { request
    ; direct_reply
    ; turn_instructions = nonempty_trimmed_option turn_instructions
    ; surface_context
    ; channel_session_key = nonempty_trimmed_option channel_session_key
    ; channel = String.trim channel
    ; user_blocks
    ; attachments
    ; user_agent_core_blocks
    }
;;

let direct_message_with_keeper_name message keeper_name =
  direct_message
    ~keeper_name
    ~prompt:message.request.prompt
    ~direct_reply:message.direct_reply
    ?turn_instructions:message.turn_instructions
    ?surface_context:message.surface_context
    ?channel_session_key:message.channel_session_key
    ~channel:message.channel
    ~user_blocks:message.user_blocks
    ~attachments:message.attachments
    ()
;;

let direct_message_request message = message.request
let direct_message_target_name message =
  match message.request.target with
  | Keeper name -> Keeper_id.Keeper_name.to_string name
;;
let direct_message_prompt message = message.request.prompt
let direct_message_direct_reply message = message.direct_reply
let direct_message_turn_instructions message = message.turn_instructions
let direct_message_surface_context message = message.surface_context
let direct_message_channel_session_key message = message.channel_session_key
let direct_message_channel message = message.channel
let direct_message_user_blocks message = message.user_blocks
let direct_message_attachments message = message.attachments
let direct_message_user_agent_core_blocks message = message.user_agent_core_blocks

let request_of_json json =
  let* fields = object_fields ~field:"delegate" json in
  let* () =
    exact_fields
      ~field:"delegate"
      ~allowed:[ "target"; "capability"; "prompt" ]
      fields
  in
  let* target_json = required_field ~field:"delegate" "target" fields in
  let* target = target_of_json target_json in
  (* The wire field is validated and not carried: an explicit wrong value is
     refused here. *)
  let* (Invoke_turn : capability) =
    optional_capability_of_json
      ~field:"delegate.capability"
      (List.assoc_opt "capability" fields)
  in
  let* prompt_json = required_field ~field:"delegate" "prompt" fields in
  let* prompt = string_value ~field:"delegate.prompt" prompt_json in
  if String.equal prompt "" then Error Empty_prompt else Ok { target; prompt }
;;

let request_error_to_string = function
  | Invalid_target reason -> reason
  | Empty_prompt -> "message is required"
  | Invalid_multimodal_input reason -> reason
  | Invalid_wire_value { field; expected } ->
    Printf.sprintf "%S: %s" field expected
;;

let target_name_of_target = function
  | Keeper name -> Keeper_id.Keeper_name.to_string name
;;

let target_name (request : request) =
  target_name_of_target request.target
;;

let prompt (request : request) = request.prompt
