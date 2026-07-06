(* Gh_capability_policy — capability axis for gh verbs (RFC-0309 §3.3, W2).
   See gh_capability_policy.mli for the axis boundary and ordering notes. *)

type disposition =
  | Allowed
  | Requires_approval
  | Denied

let string_of_disposition = function
  | Allowed -> "allowed"
  | Requires_approval -> "requires_approval"
  | Denied -> "denied"
;;

(* Actions on a durable-remote family that only read or act locally — they do
   NOT touch the durable remote surface, so they are not a capability decision.
   [clone] copies to local disk; [view]/[list] read. *)
let local_or_read_repo_action = function
  | "clone" | "view" | "list" -> true
  | _ -> false
;;

(* G-4 externality axis, risk-independent. Keyed on the whole verb: only a
   MUTATING action on a durable-remote family counts. *)
let creates_durable_remote_surface (v : Gh_verb.t) : bool =
  match v.Gh_verb.family, v.Gh_verb.action with
  | (Gh_verb.Repo | Gh_verb.Discussion), Some action ->
    not (local_or_read_repo_action action)
  | (Gh_verb.Repo | Gh_verb.Discussion), None -> false
  | ( ( Gh_verb.Pr | Gh_verb.Issue | Gh_verb.Release | Gh_verb.Secret
      | Gh_verb.Ssh_key | Gh_verb.Workflow | Gh_verb.Auth | Gh_verb.Gist
      | Gh_verb.Ruleset | Gh_verb.Label | Gh_verb.Run | Gh_verb.Cache
      | Gh_verb.Project | Gh_verb.Api | Gh_verb.Other _ )
    , _ ) ->
    false
;;

let disposition_of (v : Gh_verb.t) : disposition =
  match v.Gh_verb.family with
  (* Unrecognized area: a human adjudicates. Never silently allowed. This is
     the capability-axis counterpart of risk_of_gh_verb's Other -> R2
     fail-close: on the risk axis Other floors, on the capability axis it asks. *)
  | Gh_verb.Other _ -> Requires_approval
  | Gh_verb.Pr | Gh_verb.Issue | Gh_verb.Repo | Gh_verb.Discussion
  | Gh_verb.Release | Gh_verb.Secret | Gh_verb.Ssh_key | Gh_verb.Workflow
  | Gh_verb.Auth | Gh_verb.Gist | Gh_verb.Ruleset | Gh_verb.Label | Gh_verb.Run
  | Gh_verb.Cache | Gh_verb.Project | Gh_verb.Api ->
    (match Shell_ir_risk.risk_of_gh_verb v with
     | Shell_ir_risk.R2_Irreversible | Shell_ir_risk.Destructive_protected ->
       Denied
     | Shell_ir_risk.R0_Read -> Allowed
     | Shell_ir_risk.R1_Reversible_mutation ->
       if creates_durable_remote_surface v then Requires_approval else Allowed)
;;
