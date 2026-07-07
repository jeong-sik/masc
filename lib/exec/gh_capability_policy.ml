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
  match Shell_ir_risk.classify_gh_verb v with
  (* Unrecognized top-level area: a human adjudicates. Never silently allowed. *)
  | Shell_ir_risk.Gh_unrecognized_family -> Requires_approval
  (* Known mutating-capable family with an action that is neither a known read
     nor a table mutation (e.g. [gh repo upsert-magic]). Closing this is the
     point of the fix: instead of auto-running as an R0 read, it asks. *)
  | Shell_ir_risk.Gh_unrecognized_action -> Requires_approval
  (* Reads and bare invocations: allowed. *)
  | Shell_ir_risk.Gh_read -> Allowed
  (* Irreversible mutations are also risk-floored (R2/Destructive): denied. *)
  | Shell_ir_risk.Gh_irreversible_mutation -> Denied
  (* Reversible mutation: approval only when it touches a durable remote
     surface (repo/discussion mutating action); otherwise allowed. *)
  | Shell_ir_risk.Gh_reversible_mutation ->
    if creates_durable_remote_surface v then Requires_approval else Allowed
  (* [gh api]: the capability axis defers to risk (string-borne). A read-shaped
     api call is Allowed; a destructive -X/graphql is R2 and denied by the floor
     and by risk_of_gh_verb via the word-list, handled in the risk projection. *)
  | Shell_ir_risk.Gh_string_borne ->
    (match Shell_ir_risk.risk_of_gh_verb v with
     | Shell_ir_risk.R2_Irreversible | Shell_ir_risk.Destructive_protected ->
       Denied
     | Shell_ir_risk.R1_Reversible_mutation -> Requires_approval
     | Shell_ir_risk.R0_Read -> Allowed)
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

(* A [query] field whose value is read from an EXTERNAL source: gh reads a
   -f/-F/--field value beginning with '@' from that file ('@-' = stdin). The
   mutation text is therefore not in argv, so the literal body scanners
   ([body_contains_r2_mutation]/[gh_api_graphql_creates_durable_remote]) cannot
   see it and would R0-Allow it. This is the literal-argv counterpart of the
   Var/Concat opacity above; both mark the body opaque so the capability axis
   asks. The file is NEVER read (no TOCTOU). *)
let field_value_is_external_query field_prefix =
  String.starts_with ~prefix:"query=@" (String.lowercase_ascii field_prefix)
;;

let separate_field_value_is_external_query (arg : Shell_ir.arg) : bool =
  match arg_literal arg with
  | Some value -> field_value_is_external_query value
  | None -> false
;;

let attached_field_is_external_query (arg : Shell_ir.arg) : bool =
  match arg_literal arg with
  | Some tok ->
    (match strip_attached_field_flag tok with
     | Some field_prefix -> field_value_is_external_query field_prefix
     | None -> false)
  | None -> false
;;

(* [gh api graphql --input FILE] (or [--input -]) delivers the whole request
   body — including the graphql [query] — from a file or stdin. As with the '@'
   sigil, the mutation text never reaches argv, so treat its presence as an
   opaque body. Matches both the separate ([--input file]) and attached
   ([--input=file]) forms. *)
let arg_is_input_flag (arg : Shell_ir.arg) : bool =
  match arg_leading_literal arg with
  | Some tok ->
    let lower = String.lowercase_ascii tok in
    String.equal lower "--input" || String.starts_with ~prefix:"--input=" lower
  | None -> false
;;

let graphql_query_body_is_opaque (args : Shell_ir.arg list) : bool =
  let rec scan = function
    | [] -> false
    | arg :: rest ->
      if arg_is_input_flag arg then true
      else (
        match arg_literal arg with
        | Some tok when is_field_flag tok ->
          (match rest with
           | value :: tail ->
             opaque_field_arg_may_be_query value
             || separate_field_value_is_external_query value
             || scan tail
           | [] -> false)
        | Some _ | None ->
          attached_opaque_field_may_be_query arg
          || attached_field_is_external_query arg
          || scan rest)
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
