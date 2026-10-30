type t =
  | Operation_queued
  | Durable_stimulus_arrived
  | Repeated_tool_call of
      { tool_name : string
      ; repeated_count : int
      }
  | Repeated_assistant_text of { repeated_count : int }
