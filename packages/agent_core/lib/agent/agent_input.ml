open Types
open Agent_types

let base_messages agent =
  match agent.state.messages with
  | [] -> agent.state.config.initial_messages
  | msgs -> msgs
;;

let sanitize_user_input_blocks =
  List.map (function
    | Text s -> Text (Llm_provider.Utf8_sanitize.sanitize s)
    | block -> block)
;;

let trace_prompt_of_blocks blocks =
  let parts =
    blocks
    |> List.filter_map (function
      | Text s -> Some (Llm_provider.Utf8_sanitize.sanitize s)
      | Image { media_type; data; _ } ->
        Some (Printf.sprintf "[image:%s data_chars=%d]" media_type (String.length data))
      | Document { media_type; data; _ } ->
        Some
          (Printf.sprintf "[document:%s data_chars=%d]" media_type (String.length data))
      | Audio { media_type; data; _ } ->
        Some (Printf.sprintf "[audio:%s data_chars=%d]" media_type (String.length data))
      | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _ | ToolResult _ ->
        None)
  in
  match String.concat "\n" parts with
  | "" -> "[multimodal input]"
  | text -> text
;;

let validate_user_input_blocks blocks =
  let unsupported =
    List.find_map
      (function
        | Text _ | Image _ | Document _ | Audio _ -> None
        | Thinking _ -> Some "Thinking"
        | ReasoningDetails _ -> Some "ReasoningDetails"
        | RedactedThinking _ -> Some "RedactedThinking"
        | ToolUse _ -> Some "ToolUse"
        | ToolResult _ -> Some "ToolResult")
      blocks
  in
  match unsupported with
  | None -> Ok ()
  | Some kind ->
    Error
      (Error.Config
         (Error.InvalidConfig
            { field = "user_blocks"
            ; detail =
                Printf.sprintf
                  "user input blocks may contain only Text, Image, Document, or Audio; \
                   got %s"
                  kind
            }))
;;

let append_user_input agent user_blocks =
  let user_msg =
    { role = User
    ; content = sanitize_user_input_blocks user_blocks
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  update_state agent (fun state ->
    { state with messages = Util.snoc (base_messages agent) user_msg });
  user_msg.content
;;

let resume_user_input agent user_blocks =
  let exact_input = sanitize_user_input_blocks user_blocks in
  (* Match the resume prompt against the run's ORIGINAL prompt, not the latest
     User message. [append_user_input] snocs the original prompt immediately
     after the seed messages ([config.initial_messages]), so it lives at index
     [List.length config.initial_messages] in [state.messages]. Context
     injection (Agent_turn.apply_context_injection) appends further User-role
     messages during a turn, so a reverse scan for the last User message can
     pick an injected message instead of the original prompt and falsely reject
     a valid resume.

     The positional anchor is [config.initial_messages], NOT [base_messages
     agent]: [base_messages] returns the whole [state.messages] once it is
     non-empty, which at resume is the full restored conversation — its length
     is not the prompt's index. [config.initial_messages] is the seed/history
     prefix the prompt was appended after, so its length is the prompt's index.

     No recorded prompt identity exists to match against (neither
     Checkpoint_types.t nor the durable execution journal stores the original
     input), so positional matching is the bounded, deterministic option. *)
  let base_len = List.length agent.state.config.initial_messages in
  match List.nth_opt agent.state.messages base_len with
  | Some { role = User; content; _ } when content = exact_input -> Ok exact_input
  | Some { role = User; _ } ->
    Error
      (Error.Config
         (Error.InvalidConfig
            { field = "execution_store.resume"
            ; detail =
                "resume input differs from the original User prompt in the restored \
                 Agent checkpoint"
            }))
  | Some _ | None ->
    Error
      (Error.Config
         (Error.InvalidConfig
            { field = "execution_store.resume"
            ; detail =
                "restored Agent checkpoint contains no original User prompt to resume"
            }))
;;
