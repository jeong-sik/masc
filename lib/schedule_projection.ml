(* TEL-OK: pure schedule read-model projection; schedule tool/runner handlers own
   execution telemetry. *)

type attention_action =
  | Dispatch_ready

let attention_action_to_string = function
  | Dispatch_ready -> "dispatch_ready"
;;
