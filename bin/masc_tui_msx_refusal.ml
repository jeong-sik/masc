(* A refused MSX answer as the one sentence a person reads. The routes refuse
   in [Msx_wire]'s body, so the terminal reads that body with the same codec
   and branches on the code, not on the words. The code names what the
   operator may do next; the server's message, when it sent one, says why.
   A body that is not an MSX refusal gives [None], and the caller keeps its
   own wording for it. *)
let refusal_lead = function
  | Msx_wire.Activity_disabled -> "MSX is off"
  | Msx_wire.Activity_unobserved -> "MSX activity is not available"
  | Msx_wire.Workspace_precondition_failed -> "the server is another workspace"
  | Msx_wire.Worker_unavailable -> "the MSX worker is not running, nothing was sent"
  | Msx_wire.Outcome_unknown -> "the MSX worker's answer was lost, so the call may have run"

let refusal_sentence body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error _ -> None
  | json ->
      (match Msx_wire.decode json with
       | Error _ -> None
       | Ok { code; message } ->
           (match Option.map refusal_lead code, message with
            | Some lead, Some message -> Some (lead ^ ": " ^ message)
            | Some lead, None -> Some lead
            | None, Some message -> Some message
            | None, None -> None))
