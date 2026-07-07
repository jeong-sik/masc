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

(* Body-aware disposition. [disposition_of] keys on the typed [Gh_verb.t] alone,
   but [Gh_verb.Api] (i.e. [gh api graphql ...]) is body-blind by design
   (RFC-0208: graphql method/body risk is irreducibly string-borne). W4/G-9
   demoted the durable-remote graphql create mutations (createRepository,
   createDiscussion, addDiscussionComment, …) from the R2 deny floor to R1, so
   the floor no longer denies them and the body-blind [Api] disposition would
   wrongly [Allow] them — while the typed [gh repo create] form
   [Requires_approval]. This entry point restores axis symmetry by inspecting the
   parsed graphql body (owned by [Shell_ir_risk]) for those fragments. Every
   other command delegates unchanged to [disposition_of]; the check is ADDITIVE
   (it only turns [Allowed] into [Requires_approval], never the reverse). *)
let disposition_of_words (words : string list) (v : Gh_verb.t) : disposition =
  match v.Gh_verb.family with
  | Gh_verb.Api when Shell_ir_risk.gh_api_graphql_creates_durable_remote words ->
    Requires_approval
  | Gh_verb.Api | Gh_verb.Pr | Gh_verb.Issue | Gh_verb.Repo | Gh_verb.Discussion
  | Gh_verb.Release | Gh_verb.Secret | Gh_verb.Ssh_key | Gh_verb.Workflow
  | Gh_verb.Auth | Gh_verb.Gist | Gh_verb.Ruleset | Gh_verb.Label | Gh_verb.Run
  | Gh_verb.Cache | Gh_verb.Project | Gh_verb.Other _ ->
    disposition_of v
;;

let rec arg_literal : Shell_ir.arg -> string option = function
  | Shell_ir.Lit (s, _) -> Some s
  | Shell_ir.Var _ -> None
  | Shell_ir.Concat parts ->
    let rec collect acc = function
      | [] -> Some (String.concat "" (List.rev acc))
      | Shell_ir.Lit (s, _) :: rest -> collect (s :: acc) rest
      | Shell_ir.Var _ :: _ -> None
      | Shell_ir.Concat nested :: rest ->
        (match collect [] nested with
         | Some s -> collect (s :: acc) rest
         | None -> None)
    in
    collect [] parts
;;

let rec arg_leading_literal : Shell_ir.arg -> string option = function
  | Shell_ir.Lit (s, _) -> Some s
  | Shell_ir.Var _ -> None
  | Shell_ir.Concat [] -> Some ""
  | Shell_ir.Concat (first :: _) -> arg_leading_literal first
;;

let arg_word (arg : Shell_ir.arg) : string =
  match arg_literal arg with
  | Some s -> s
  | None -> ""
;;

let is_graphql_api (v : Gh_verb.t) : bool =
  match v.Gh_verb.family, v.Gh_verb.action with
  | Gh_verb.Api, Some action -> String.equal (String.lowercase_ascii action) "graphql"
  | Gh_verb.Api, None -> false
  | ( Gh_verb.Pr | Gh_verb.Issue | Gh_verb.Repo | Gh_verb.Discussion
    | Gh_verb.Release | Gh_verb.Secret | Gh_verb.Ssh_key | Gh_verb.Workflow
    | Gh_verb.Auth | Gh_verb.Gist | Gh_verb.Ruleset | Gh_verb.Label
    | Gh_verb.Run | Gh_verb.Cache | Gh_verb.Project | Gh_verb.Other _ )
    , _ -> false
;;

let is_field_flag = function
  | "-f" | "-F" | "--field" | "--raw-field" -> true
  | _ -> false
;;

let strip_attached_field_flag tok =
  let lower = String.lowercase_ascii tok in
  let strip prefix =
    let n = String.length prefix in
    String.sub tok n (String.length tok - n)
  in
  if String.starts_with ~prefix:"--field=" lower then Some (strip "--field=")
  else if String.starts_with ~prefix:"--raw-field=" lower then
    Some (strip "--raw-field=")
  else if String.starts_with ~prefix:"-f" tok && not (String.equal tok "-f") then
    Some (strip "-f")
  else if String.starts_with ~prefix:"-F" tok && not (String.equal tok "-F") then
    Some (strip "-F")
  else None
;;

let field_prefix_may_be_query field_prefix =
  let lower = String.lowercase_ascii field_prefix in
  String.starts_with ~prefix:"query=" lower || not (String.contains lower '=')
;;

let opaque_field_arg_may_be_query (arg : Shell_ir.arg) : bool =
  match arg_literal arg with
  | Some _ -> false
  | None ->
    (match arg_leading_literal arg with
     | Some prefix -> field_prefix_may_be_query prefix
     | None -> true)
;;

let attached_opaque_field_may_be_query (arg : Shell_ir.arg) : bool =
  match arg_literal arg with
  | Some _ -> false
  | None ->
    (match arg_leading_literal arg with
     | Some prefix ->
       (match strip_attached_field_flag prefix with
        | Some field_prefix -> field_prefix_may_be_query field_prefix
        | None -> false)
     | None -> false)
;;

let graphql_query_body_is_opaque (args : Shell_ir.arg list) : bool =
  let rec scan = function
    | [] -> false
    | arg :: rest ->
      (match arg_literal arg with
       | Some tok when is_field_flag tok ->
         (match rest with
          | value :: tail -> opaque_field_arg_may_be_query value || scan tail
          | [] -> false)
       | Some _ | None -> attached_opaque_field_may_be_query arg || scan rest)
  in
  scan args
;;

let disposition_of_simple (simple : Shell_ir.simple) : disposition option =
  match Exec_program.known simple.Shell_ir.bin with
  | Some Exec_program.Gh ->
    let words =
      Exec_program.to_string simple.Shell_ir.bin
      :: List.map arg_word simple.Shell_ir.args
    in
    let verb = Gh_verb.classify words in
    if is_graphql_api verb && graphql_query_body_is_opaque simple.Shell_ir.args
    then Some Requires_approval
    else Some (disposition_of_words words verb)
  | Some _ | None -> None
[@@warning "-4"]
