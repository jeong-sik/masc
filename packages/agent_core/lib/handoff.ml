(** Sub-agent delegation and handoff.
    Inspired by Anthropic SDK's AgentDefinition + Task tool
    and Google ADK's Root/Sub-agent pattern.

    To avoid a circular dependency with Agent, this module owns the target
    type and constructs a normal tool from a caller-supplied delegate closure. *)

(** Handoff target definition *)
type handoff_target =
  { name : string
  ; description : string
  ; config : Types.agent_config
  ; tools : Tool.t list
  }

(** Result of a handoff execution *)
type handoff_result =
  { target_name : string
  ; response : Types.api_response
  }

(** Delegate function type -- provided by Agent at runtime.
    Takes switch, target definition, and user prompt.
    Returns the sub-agent's API response or an error. *)
type delegate_fn =
  sw:Eio.Switch.t
  -> handoff_target
  -> string
  -> (Types.api_response, Error.sdk_error) result

(** Create a handoff tool visible to the LLM.
    [delegate] is the real execution closure. The target name is the exact tool
    name; no prefix, alias, or post-execution interception is involved. *)
let make_handoff_tool ~(delegate : string -> Types.tool_result) (target : handoff_target)
  : Tool.t
  =
  let handler input : Types.tool_result =
    match input with
    | `Assoc fields ->
      (match List.assoc_opt "prompt" fields with
       | Some (`String prompt) -> delegate prompt
       | Some value ->
         Error
           { message =
               Printf.sprintf
                 "handoff prompt must be a string, got %s"
                 (Tool_input_validation.describe_json_value value)
           ; recoverable = true
           ; error_class = Some Types.Deterministic
           }
       | None ->
         Error
           { message = "handoff prompt is required"
           ; recoverable = true
           ; error_class = Some Types.Deterministic
           })
    | input ->
      Error
        { message =
            Printf.sprintf
              "handoff input must be an object, got %s"
              (Tool_input_validation.describe_json_value input)
        ; recoverable = true
        ; error_class = Some Types.Deterministic
        }
  in
  Tool.create
    ~name:target.name
    ~description:(Printf.sprintf "Hand off to %s: %s" target.name target.description)
    ~parameters:
      [ { Types.name = "prompt"
        ; description = "Instructions for the sub-agent"
        ; param_type = Types.String
        ; required = true
        }
      ]
    handler
;;

let inline_test_target =
  { name = "researcher"
  ; description = "Research"
  ; config = Types.default_config ~model:"test-model"
  ; tools = []
  }
;;

let%test "make_handoff_tool uses exact target name and real delegate" =
  let seen = ref None in
  let tool =
    make_handoff_tool
      ~delegate:(fun prompt ->
        seen := Some prompt;
        Ok { Types.content = "delegated"; _meta = None })
      inline_test_target
  in
  tool.schema.name = "researcher"
  && Tool.execute tool (`Assoc [ "prompt", `String "inspect" ])
     = Ok { Types.content = "delegated"; _meta = None }
  && !seen = Some "inspect"
;;

let%test "make_handoff_tool rejects missing prompt without invoking delegate" =
  let invoked = ref false in
  let tool =
    make_handoff_tool
      ~delegate:(fun _ ->
        invoked := true;
        Ok { Types.content = "unexpected"; _meta = None })
      inline_test_target
  in
  match Tool.execute tool (`Assoc []) with
  | Error { recoverable = true; error_class = Some Types.Deterministic; _ } ->
    not !invoked
  | Ok _ | Error _ -> false
;;
