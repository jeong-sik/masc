(* Approval_config — pure data.  No I/O.  *)

type trust_level =
  | Observe      (* Allow all, log telemetry *)
  | Suggest      (* Auto-allow with confirmation suggestion telemetry *)
  | Auto_safe    (* Auto-allow for the given risk class *)
  | Enforced     (* Strict ask/deny — fail-closed default *)

type agent_overlay = {
  safe_trust : trust_level;
  audited_trust : trust_level;
  privileged_trust : trust_level;
}

type t = {
  defaults : agent_overlay;
  per_agent : (Agent_id.t * agent_overlay) list;
}

let trust_level_to_string = function
  | Observe -> "observe"
  | Suggest -> "suggest"
  | Auto_safe -> "auto_safe"
  | Enforced -> "enforced"

let normalize_level_token (raw : string) : string =
  String.lowercase_ascii (String.trim raw)

let trust_level_of_string (raw : string) : trust_level option =
  match normalize_level_token raw with
  | "observe"
  | "obs" ->
    Some Observe
  | "suggest"
  | "s" ->
    Some Suggest
  | "auto_safe"
  | "auto-safe"
  | "autosafe"
  | "allow" ->
    Some Auto_safe
  | "enforced"
  | "ask"
  | "strict"
  | "deny" ->
    Some Enforced
  | _ -> None

let agent_overlay_of_profile (raw : string) : agent_overlay option =
  match normalize_level_token raw with
  | "autonomous"
  | "observe" ->
    Some
      {
        safe_trust = Observe;
        audited_trust = Observe;
        privileged_trust = Observe;
      }
  | "enforced"
  | "enforced_all"
  | "strict"
  | "deny_all"
  | "all_enforced" ->
    Some
      {
        safe_trust = Enforced;
        audited_trust = Enforced;
        privileged_trust = Enforced;
      }
  | "permissive"
  | "permissive_default"
  | "perm" ->
    Some
      {
        safe_trust = Auto_safe;
        audited_trust = Enforced;
        privileged_trust = Enforced;
      }
  | "suggest" ->
    Some
      {
        safe_trust = Suggest;
        audited_trust = Suggest;
        privileged_trust = Suggest;
      }
  | "auto_safe"
  | "auto-safe"
  | "autosafe" ->
    Some
      {
        safe_trust = Auto_safe;
        audited_trust = Auto_safe;
        privileged_trust = Auto_safe;
      }
  | _ -> None

let enforced_all : agent_overlay =
  {
    safe_trust = Enforced;
    audited_trust = Enforced;
    privileged_trust = Enforced;
  }

let permissive_default : agent_overlay =
  {
    safe_trust = Auto_safe;
    audited_trust = Enforced;
    privileged_trust = Enforced;
  }

(* RFC-0254 §5.5: the overlay for an autonomous keeper lane.  Every risk
   class is [Observe] (allow + telemetry) because there is no human or
   resolver in the loop to answer an [Ask].  This does NOT loosen the
   catastrophic floor: [Approval_policy.decide] checks the trust-independent
   floor (destructive git, write-escape, catastrophic program) before
   consulting any trust level, so [Observe] here never re-enables a floor
   case. *)
let autonomous : agent_overlay =
  {
    safe_trust = Observe;
    audited_trust = Observe;
    privileged_trust = Observe;
  }

let empty : t = { defaults = enforced_all; per_agent = [] }

let lookup t ~actor =
  match List.assoc_opt actor t.per_agent with
  | Some overlay -> overlay
  | None -> t.defaults
