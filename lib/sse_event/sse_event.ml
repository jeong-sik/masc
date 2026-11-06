module Types = Sse_event_t
module Json = Sse_event_j

(** Encode the typed [agent_failed] payload independently from its delivery
    envelope. *)
let agent_failed_payload
      ~(agent_name : string)
      ~(task_id : string)
      ~(elapsed_s : float)
      ~(error : string)
      ~(error_domain : string)
      ~(error_code : string)
      ~(error_retryable : bool)
      ~(error_detail : Yojson.Safe.t)
  : Yojson.Safe.t
  =
  let p : Sse_event_t.agent_failed_payload =
    { agent_name
    ; task_id
    ; elapsed_s
    ; error
    ; error_domain
    ; error_code
    ; error_retryable
    ; error_detail
    }
  in
  Yojson.Safe.from_string (Sse_event_j.string_of_agent_failed_payload p)
;;
