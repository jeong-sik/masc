(** Transcript evidence retained in an anchor. A result records the ToolResult
    outcome. File contents, execution receipts and other effect evidence remain
    in the archived turn. Tool names on results require occurrence correlation. *)
type t =
  | Tool_requested of { call_id : string; name : string }
  | Tool_result_recorded of
      { call_id : string
      ; name : string option
      ; outcome : Llm_provider.Types.tool_result_outcome
      }
  | Assistant_said of string
[@@deriving yojson]

val of_messages : Agent_core.Types.message list -> t list
val redact : (string -> string) -> t -> t
val render : t -> string
