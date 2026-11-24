(* The durable observation codec follows the SDK result type. Re-exporting
   its constructors makes a new SDK outcome a compile-time codec obligation. *)
module Outcome = struct
  type failure = Llm_provider.Types.tool_failure_provenance =
    { failure_kind : Llm_provider.Types.tool_failure_kind
    ; error_class : Llm_provider.Types.tool_error_class option
    }
  [@@deriving yojson]

  type t = Llm_provider.Types.tool_result_outcome =
    | Tool_succeeded
    | Tool_failed of failure
  [@@deriving yojson]
end

type t =
  | Tool_requested of { call_id : string; name : string }
  | Tool_result_recorded of
      { call_id : string
      ; name : string option
      ; outcome : Outcome.t
      }
  | Assistant_said of string
[@@deriving yojson]

let of_messages messages =
  let module P = Llm_provider.Tool_result_projection in
  let of_block (role : Agent_core.Types.role) (block, name) =
    match block with
    | Llm_provider.Types.ToolUse { id; name; _ } when role = Assistant ->
      Some (Tool_requested { call_id = id; name })
    | ToolResult { tool_use_id; outcome; _ } when role = Tool ->
      Some (Tool_result_recorded { call_id = tool_use_id; name; outcome })
    | Text s when role = Assistant && String.trim s <> "" -> Some (Assistant_said s)
    | Text _ | ToolUse _ | ToolResult _ | ToolReference _ | Thinking _ | RedactedThinking _
    | ReasoningDetails _ | Image _ | Audio _ | Document _ -> None
  in
  match P.of_messages messages with
  | Ok resolved ->
    List.concat_map
      (fun msg -> List.filter_map (of_block (P.original_message msg).role) (P.content msg))
      (P.messages resolved)
  | Error _ ->
    (* Incomplete or ambiguous history can still prove which blocks arrived.
       The ID alone cannot attribute a result to a named handler. *)
    List.concat_map
      (fun (msg : Agent_core.Types.message) ->
         List.filter_map (fun block -> of_block msg.role (block, None)) msg.content)
      messages
;;

let redact f = function
  | Tool_requested { call_id; name } -> Tool_requested { call_id = f call_id; name = f name }
  | Tool_result_recorded { call_id; name; outcome } ->
    Tool_result_recorded { call_id = f call_id; name = Option.map f name; outcome }
  | Assistant_said text -> Assistant_said (f text)
;;

let render observation =
  (* JSON strings keep embedded newlines or quotes inside their source row. *)
  let quote s = Yojson.Safe.to_string (`String s) in
  match observation with
  | Tool_requested { call_id; name } ->
    Printf.sprintf "tool requested %s (call %s)" (quote name) (quote call_id)
  | Tool_result_recorded { call_id; name; outcome } ->
    let source = Option.fold ~none:"unmatched ToolResult" ~some:quote name in
    let status =
      match outcome with
      | Tool_succeeded -> "reported success"
      | Tool_failed { failure_kind; error_class } ->
        let detail =
          match failure_kind with
          | Writer_exited_tool_error -> "writer exited before return, effect unknown"
          | (Validation_error | Recoverable_tool_error | Non_retryable_tool_error
            | Reported_tool_error | Unattributed_tool_error) as kind ->
            Llm_provider.Types.show_tool_failure_kind kind
        in
        let cls =
          Option.fold ~none:"" ~some:(fun c -> ", " ^ Llm_provider.Types.show_tool_error_class c)
            error_class
        in
        Printf.sprintf "recorded failure (%s%s)" detail cls
    in
    Printf.sprintf "tool result %s (call %s): %s" source (quote call_id) status
  | Assistant_said text -> "assistant said " ^ quote text
;;
