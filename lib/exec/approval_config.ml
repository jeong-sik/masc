(* Approval_config — pure data.  No I/O.  *)

type trust_level =
  | Observe (* Allow all, log telemetry *)
  | Suggest (* Auto-allow with confirmation suggestion telemetry *)
  | Auto_safe (* Auto-allow for the given risk class *)
  | Enforced (* Strict ask/deny — fail-closed default *)

let trust_level_to_string = function
  | Observe -> "observe"
  | Suggest -> "suggest"
  | Auto_safe -> "auto_safe"
  | Enforced -> "enforced"
;;

type agent_overlay =
  { safe_trust : trust_level
  ; audited_trust : trust_level
  ; privileged_trust : trust_level
  }

type t =
  { defaults : agent_overlay
  ; per_agent : (string * agent_overlay) list
  }

let enforced_all : agent_overlay =
  { safe_trust = Enforced; audited_trust = Enforced; privileged_trust = Enforced }
;;

let strict_default = enforced_all

let permissive_default : agent_overlay =
  { safe_trust = Auto_safe; audited_trust = Enforced; privileged_trust = Enforced }
;;

let empty : t = { defaults = strict_default; per_agent = [] }

let lookup t ~actor =
  match List.assoc_opt actor t.per_agent with
  | Some overlay -> overlay
  | None -> t.defaults
;;
