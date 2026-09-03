type terminal_boundary_outcome =
  | Terminal_completed
  | Durable_stimulus_deferred
  | Terminal_failed of
      { failure_class : Tool_result.tool_failure_class
      ; effect_disposition : Tool_result.failure_effect_disposition
      ; diagnostic : string
      }

type host_stop =
  | Repeated_tool_call of
      { tool_name : string
      ; repeated_count : int
      }
  | Terminal_tool_boundary of
      { tool_name : string
      ; outcome : terminal_boundary_outcome
      }

type dynamic_tool_result =
  { success : bool
  ; content : string
  ; abort_turn : host_stop option
  }

type dynamic_tool =
  { name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  ; call : call_id:string -> Yojson.Safe.t -> dynamic_tool_result
  }

let dynamic_tool_bytes tools =
  List.fold_left
    (fun acc tool ->
       acc
       + String.length tool.name
       + String.length tool.description
       + String.length (Yojson.Safe.to_string tool.input_schema))
    0
    tools
;;
