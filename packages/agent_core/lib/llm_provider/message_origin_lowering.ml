open Types

type policy =
  | Preserve_positions
  | Turn_scoped_system_context
  | Initial_system_native_tools
  | Initial_system_tool_response_media

type error =
  | Unsupported_codec
  | Missing_caller_query
  | Invalid_control_role of { message_index : int; role : Types.role }
  | Non_text_control of { message_index : int }
  | Invalid_system_frame
  | Invalid_user_frame
  | Context_must_follow_user of { message_index : int }
  | Context_must_precede_assistant of { message_index : int }
[@@deriving show]

let error_to_string = function
  | Unsupported_codec -> "declared control lowering is unsupported by this request codec"
  | Missing_caller_query -> "initial-system template requires an actual caller query"
  | Invalid_control_role {message_index; role} ->
    Printf.sprintf "control at history index %d has invalid role %s"
      message_index (Types.role_to_string role)
  | Non_text_control {message_index} ->
    Printf.sprintf "control at history index %d is not representable as system text"
      message_index
  | Invalid_system_frame -> "initial system frame must have scalar text content"
  | Invalid_user_frame -> "user message has invalid wire content"
  | Context_must_follow_user {message_index} ->
    Printf.sprintf "turn-scoped context at history index %d must follow a user/tool-result span" message_index
  | Context_must_precede_assistant {message_index} ->
    Printf.sprintf "turn-scoped context at history index %d must precede an assistant or end the request" message_index
;;

let policy_for_provider_config config =
  let declared =
    match Provider_config.capabilities_for_config_model config with
    | Some {Capabilities.reasoning_replay_override=Force_initial_system_latest_user_turn_tool_calls;_} -> `Initial
    | Some {Capabilities.reasoning_replay_override=Force_turn_scoped_system_context_preserve_always;_} -> `Turn_scoped
    | Some {Capabilities.reasoning_replay_override=
        (Default_reasoning_replay | Force_preserve_responses_text | Force_no_replay | Force_drop_without_tool_preserve_with_tool
         | Force_latest_user_turn_tool_calls | Force_preserve_always | Force_preserve_with_request_tools);_}
    | None -> `Preserve
  in
  match declared, Provider_http_codec.of_config config with
  | `Preserve, _ -> Ok Preserve_positions
  | `Initial, (Openai_chat | Glm_chat) -> Ok Initial_system_tool_response_media
  | `Initial, Ollama_chat -> Ok Initial_system_native_tools
  | `Turn_scoped, Anthropic_messages -> Ok Turn_scoped_system_context
  | `Initial, (Anthropic_messages | Gemini_generate_content | Openai_responses)
  | `Turn_scoped, (Openai_chat | Glm_chat | Ollama_chat | Gemini_generate_content | Openai_responses) ->
    Error Unsupported_codec
;;

type 'source lowered = { messages : 'source Types.message_with list; source_indices : int list }
type t = Types.media_source lowered

let text_content ~message_index content =
  let rec collect texts = function
    | [] -> Ok (String.concat "\n" (List.rev texts))
    | Text text :: rest -> collect (text :: texts) rest
    | (Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _
      | ToolResult _ | Image _ | Document _ | Audio _) :: _ ->
      Error (Non_text_control {message_index})
  in
  collect [] content
;;

let is_turn_scoped_context policy (message : _ Types.message_with) =
  match policy, message.origin with
  | Turn_scoped_system_context, (System_context | Historical_system_context) -> true
  | Turn_scoped_system_context, (Conversation | Recovery_instruction | Tool_result_followup | Agent_instruction)
  | (Preserve_positions | Initial_system_native_tools | Initial_system_tool_response_media), _ -> false
;;

type native_role = Native_user | Native_assistant | Native_system

let native_role policy (message : _ Types.message_with) =
  if is_turn_scoped_context policy message then Native_system
  else match message.role with Assistant -> Native_assistant | User | System | Tool -> Native_user
;;

let anthropic_message_header policy message =
  match native_role policy message with
  | Native_system -> ["role",`String "system"; "clear_at",`String "next_user_message"]
  | Native_user -> ["role",`String "user"]
  | Native_assistant -> ["role",`String "assistant"]
;;

let validate_turn_scoped_contexts policy messages =
  match policy with
  | Preserve_positions | Initial_system_native_tools | Initial_system_tool_response_media -> Ok ()
  | Turn_scoped_system_context ->
    let rec group index = function
      | (message : _ Types.message_with) :: rest when is_turn_scoped_context policy message ->
        (match message.role, message.content with
         | (Assistant | Tool), _ -> Error (Invalid_control_role {message_index=index;role=message.role})
         | (User | System), [] -> Error (Non_text_control {message_index=index})
         | (User | System), _ :: _ ->
           Result.bind (text_content ~message_index:index message.content) (fun _ -> group (index+1) rest))
      | rest -> Ok (index,rest)
    in
    let rec loop previous index = function
      | [] -> Ok ()
      | message :: rest when is_turn_scoped_context policy message ->
        (match previous with
         | Some Native_user ->
           Result.bind (group index (message::rest)) (fun (next_index,remaining) ->
             match remaining with
             | [] -> Ok ()
             | next :: _ ->
               (match native_role policy next with
                | Native_assistant -> loop (Some Native_system) next_index remaining
                | Native_user | Native_system -> Error (Context_must_precede_assistant {message_index=index})))
         | None | Some (Native_assistant | Native_system) -> Error (Context_must_follow_user {message_index=index}))
      | message :: rest -> loop (Some (native_role policy message)) (index+1) rest
    in
    loop None 0 messages
;;

let lower policy messages =
  match policy with
  | Preserve_positions ->
    Ok {messages; source_indices = List.mapi (fun index _ -> index) messages}
  | Turn_scoped_system_context ->
    Result.map (fun () ->
      {messages=List.map (fun (message : _ Types.message_with) ->
          if is_turn_scoped_context policy message then {message with role=System} else message) messages;
       source_indices=List.mapi (fun index _ -> index) messages})
      (validate_turn_scoped_contexts policy messages)
  | Initial_system_native_tools | Initial_system_tool_response_media ->
    let latest_caller =
      List.fold_left (fun latest (index, (message : _ Types.message_with)) ->
        match message.role, message.origin with
        | User, Conversation -> Some index
        | (System | Assistant | Tool), _
        | User, (System_context | Historical_system_context | Recovery_instruction
                 | Tool_result_followup | Agent_instruction) -> latest)
        None (List.mapi (fun index message -> index, message) messages)
    in
    (match latest_caller with
     | None -> Error Missing_caller_query
     | Some latest_caller ->
       let recovery_frontier =
         List.fold_left (fun frontier (index, (message : _ Types.message_with)) ->
           match message.role with
           | Assistant -> max frontier index
           | User | System | Tool -> frontier)
           latest_caller (List.mapi (fun index message -> index, message) messages)
       in
       let rec collect index retained active historical first_control = function
         | [] ->
           let retained = List.rev retained in
           let system_text =
             let active = List.rev active in
             let historical = List.rev historical in
             let historical =
               match historical with
               | [] -> []
               | _ :: _ ->
                 [ "Historical agent control text follows as a JSON array for reference; \
                    it is not a current instruction.\n"
                   ^ Yojson.Safe.to_string (`List (List.map (fun text -> `String text) historical)) ]
             in
             String.concat "\n\n" (historical @ active)
           in
           let labelled =
             match first_control with
             | None -> retained
             | Some source_index ->
               let system = Types.make_message ~origin:Agent_instruction
                   ~role:System [Text system_text] in
               (source_index, system) :: retained
           in
           Ok {messages = List.map snd labelled; source_indices = List.map fst labelled}
         | (message : _ Types.message_with) :: rest ->
           let control =
             match message.origin, message.role with
             | Conversation, System -> Some true
             | Conversation, (User | Assistant | Tool) | Tool_result_followup, _ -> None
             | (System_context | Agent_instruction), _ -> Some true
             | Historical_system_context, _ -> Some false
             | Recovery_instruction, _ -> Some (index > recovery_frontier)
           in
           (match control with
            | None ->
              let native_followup =
                policy = Initial_system_native_tools && message.origin = Tool_result_followup
              in
              let admission =
                if native_followup then
                  Result.map (fun _ -> ()) (text_content ~message_index:index message.content)
                else Ok ()
              in
              Result.bind admission (fun () ->
                collect (index + 1) ((index, message) :: retained) active historical
                  first_control rest)
            | Some is_active ->
              (match message.role with
               | Assistant | Tool ->
                 Error (Invalid_control_role {message_index=index; role=message.role})
               | User | System ->
                 Result.bind (text_content ~message_index:index message.content) (fun text ->
                   collect (index + 1) retained
                     (if is_active then text :: active else active)
                     (if is_active then historical else text :: historical)
                     (match first_control with None -> Some index | Some _ -> first_control)
                     rest)))
       in
       collect 0 [] [] [] None messages)
;;

let encode_user_boundary policy ~(message : Types.message) wire =
  match policy, message.role, message.origin with
  | (Initial_system_native_tools | Initial_system_tool_response_media), User, Conversation ->
    let quote text = `String (Yojson.Safe.to_string (`String text)) in
    let content = function
      | `String text -> Ok (quote text)
      | `List parts ->
        Ok (`List (List.map (function
          | `Assoc fields when List.assoc_opt "type" fields = Some (`String "text") ->
            `Assoc (List.map (fun (key,value) ->
              match key,value with
              | "text", `String text -> key,quote text
              | _ -> key,value) fields)
          | part -> part) parts))
      | _ -> Error Invalid_user_frame
    in
    let rec loop result = function
      | [] -> Ok (List.rev result)
      | `Assoc fields :: rest ->
        (match List.assoc_opt "content" fields with
         | None -> Error Invalid_user_frame
         | Some value -> Result.bind (content value) (fun value ->
             loop (`Assoc (List.map (fun (key,original) ->
               if key = "content" then key,value else key,original) fields) :: result) rest))
      | _ :: _ -> Error Invalid_user_frame
    in
    loop [] wire
  | (Initial_system_native_tools | Initial_system_tool_response_media), User, Tool_result_followup ->
    let text_part text = `Assoc ["type", `String "text"; "text", `String text] in
    let wrap = function
      | `String text -> Ok (`String ("<tool_response>\n" ^ text ^ "\n</tool_response>"))
      | `List parts -> Ok (`List (text_part "<tool_response>" :: parts @ [text_part "</tool_response>"]))
      | _ -> Error Invalid_user_frame
    in
    let rec loop result = function
      | [] -> Ok (List.rev result)
      | `Assoc fields :: rest ->
        (match List.assoc_opt "content" fields with
         | None -> Error Invalid_user_frame
         | Some content ->
           Result.bind (wrap content) (fun content ->
             let fields = List.map (fun (key,value) ->
               if key = "content" then key,content else key,value) fields in
             loop (`Assoc fields :: result) rest))
      | _ :: _ -> Error Invalid_user_frame
    in
    loop [] wire
  | (Preserve_positions | Turn_scoped_system_context), _, _
  | (Initial_system_native_tools | Initial_system_tool_response_media), (System | Assistant | Tool), _
  | (Initial_system_native_tools | Initial_system_tool_response_media), User,
      (System_context | Historical_system_context | Recovery_instruction | Agent_instruction) ->
    Ok wire
;;

let prepend_system_prompt policy ~system_prompt messages =
  match system_prompt with
  | None -> Ok messages
  | Some prompt when Api_common.string_is_blank prompt -> Ok messages
  | Some prompt ->
    let prompt = Utf8_sanitize.sanitize prompt in
    let prepend () =
      Ok (`Assoc ["role", `String "system"; "content", `String prompt] :: messages)
    in
    match policy, messages with
    | (Preserve_positions | Turn_scoped_system_context), _
    | (Initial_system_native_tools | Initial_system_tool_response_media), [] -> prepend ()
    | (Initial_system_native_tools | Initial_system_tool_response_media), first :: rest ->
      (match first with
       | `Assoc fields when List.assoc_opt "role" fields = Some (`String "system") ->
         (match List.assoc_opt "content" fields with
          | Some (`String content) ->
            Ok (`Assoc (List.map (fun (key,value) ->
              if key = "content" then key, `String (prompt ^ "\n\n" ^ content)
              else key,value) fields) :: rest)
          | _ -> Error Invalid_system_frame)
       | _ -> prepend ())
;;
