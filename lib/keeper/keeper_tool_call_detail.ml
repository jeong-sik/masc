type t =
  { tool_name : string
  ; provider : string
  ; execution_outcome : Tool_result.tool_call_outcome
      (** Wire observation captured at the tool hook boundary. Durable audit
          is written separately by [Keeper_tool_call_log]. *)
  ; typed_outcome : Keeper_tool_outcome.t option
  ; latency_ms : float
  ; task_id : string option
  ; route_evidence : Yojson.Safe.t option
  ; input_fingerprint : string option
  ; output_fingerprint : string option
  }
