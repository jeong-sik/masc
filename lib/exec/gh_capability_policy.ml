(* Gh_capability_policy — capability axis for gh verbs (RFC-0309 §3.3, W2).
   See gh_capability_policy.mli for the axis boundary and ordering notes. *)

type disposition =
  | Allowed
  | Requires_approval
  | Denied

type repo_create_visibility =
  | Public
  | Private
  | Internal

type repo_create_lifecycle =
  { add_readme : bool
  ; clone : bool
  ; push : bool
  ; source : string option
  ; remote : string option
  ; template : string option
  }

type repo_create_contract =
  { owner : string
  ; name : string
  ; visibility : repo_create_visibility
  ; lifecycle : repo_create_lifecycle
  }

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

let literal_arg_words (args : Shell_ir.arg list) : (string list, string list) result =
  let rec collect acc = function
    | [] -> Ok (List.rev acc)
    | arg :: rest ->
      (match arg_literal arg with
       | Some s -> collect (s :: acc) rest
       | None -> Error [ "nonliteral_args" ])
  in
  collect [] args
;;

let is_flag tok = String.length tok > 0 && tok.[0] = '-'

let split_eq tok =
  match String.index_opt tok '=' with
  | None -> None
  | Some idx ->
    let key = String.sub tok 0 idx in
    let value = String.sub tok (idx + 1) (String.length tok - idx - 1) in
    Some (key, value)
;;

let gh_global_value_flags = [ "--repo"; "-R"; "--hostname"; "-H" ]
let gh_global_bool_flags = [ "--help" ]

let rec next_gh_positional = function
  | [] -> None
  | tok :: rest when List.mem tok gh_global_value_flags ->
    (match rest with _ :: tail -> next_gh_positional tail | [] -> None)
  | tok :: rest
    when (match split_eq tok with
          | Some (key, _) -> List.mem key gh_global_value_flags
          | None -> false) ->
    next_gh_positional rest
  | tok :: rest when List.mem tok gh_global_bool_flags -> next_gh_positional rest
  | tok :: rest when is_flag tok -> next_gh_positional rest
  | tok :: rest -> Some (tok, rest)
;;

let repo_create_tail words =
  match next_gh_positional words with
  | Some (family, after_family) when String.equal (String.lowercase_ascii family) "repo" ->
    (match next_gh_positional after_family with
     | Some (action, after_action)
       when String.equal (String.lowercase_ascii action) "create" -> Some after_action
     | Some _ | None -> None)
  | Some _ | None -> None
;;

let repo_create_value_flags =
  [ "--description", "description"
  ; "-d", "description"
  ; "--gitignore", "gitignore"
  ; "-g", "gitignore"
  ; "--homepage", "homepage"
  ; "-h", "homepage"
  ; "--license", "license"
  ; "-l", "license"
  ; "--remote", "remote"
  ; "-r", "remote"
  ; "--source", "source"
  ; "-s", "source"
  ; "--team", "team"
  ; "-t", "team"
  ; "--template", "template"
  ; "-p", "template"
  ]
;;

let repo_create_bool_flags =
  [ "--add-readme"
  ; "--clone"
  ; "-c"
  ; "--disable-issues"
  ; "--disable-wiki"
  ; "--include-all-branches"
  ; "--push"
  ]
;;

let visibility_of_flag = function
  | "--public" -> Some Public
  | "--private" -> Some Private
  | "--internal" -> Some Internal
  | _ -> None
;;

type repo_create_parse_acc =
  { repo_name_arg : string option
  ; visibility_flags : repo_create_visibility list
  ; add_readme : bool
  ; clone : bool
  ; push : bool
  ; source : string option
  ; remote : string option
  ; template : string option
  ; errors : string list
  }

let empty_repo_create_acc =
  { repo_name_arg = None
  ; visibility_flags = []
  ; add_readme = false
  ; clone = false
  ; push = false
  ; source = None
  ; remote = None
  ; template = None
  ; errors = []
  }
;;

let record_repo_value acc field value =
  match field with
  | "source" -> { acc with source = Some value }
  | "remote" -> { acc with remote = Some value }
  | "template" -> { acc with template = Some value }
  | "description" | "gitignore" | "homepage" | "license" | "team" -> acc
  | _ -> acc
;;

let add_error acc err = { acc with errors = err :: acc.errors }

let rec parse_repo_create_tail acc = function
  | [] -> acc
  | "--" :: rest ->
    List.fold_left
      (fun acc tok ->
         match acc.repo_name_arg with
         | None -> { acc with repo_name_arg = Some tok }
         | Some _ -> add_error acc ("extra_positional:" ^ tok))
      acc
      rest
  | tok :: rest ->
    (match visibility_of_flag tok with
     | Some visibility ->
       parse_repo_create_tail
         { acc with visibility_flags = visibility :: acc.visibility_flags }
         rest
     | None ->
       if List.mem tok repo_create_bool_flags then
         let acc =
           match tok with
           | "--add-readme" -> { acc with add_readme = true }
           | "--clone" | "-c" -> { acc with clone = true }
           | "--push" -> { acc with push = true }
           | "--disable-issues" | "--disable-wiki" | "--include-all-branches" ->
             acc
           | _ -> acc
         in
         parse_repo_create_tail acc rest
       else (
         match List.assoc_opt tok repo_create_value_flags with
         | Some field ->
           (match rest with
            | value :: tail ->
              parse_repo_create_tail (record_repo_value acc field value) tail
            | [] ->
              parse_repo_create_tail
                (add_error acc ("missing_flag_value:" ^ tok))
                [])
         | None ->
           (match split_eq tok with
            | Some (key, value) ->
              (match List.assoc_opt key repo_create_value_flags with
               | Some field ->
                 parse_repo_create_tail (record_repo_value acc field value) rest
               | None ->
                 if is_flag tok
                 then
                   parse_repo_create_tail
                     (add_error acc ("unknown_flag:" ^ key))
                     rest
                 else parse_repo_create_tail (add_error acc ("invalid_name:" ^ tok)) rest)
            | None ->
              if is_flag tok
              then
                parse_repo_create_tail (add_error acc ("unknown_flag:" ^ tok)) rest
              else (
                match acc.repo_name_arg with
                | None ->
                  parse_repo_create_tail { acc with repo_name_arg = Some tok } rest
                | Some _ ->
                  parse_repo_create_tail
                    (add_error acc ("extra_positional:" ^ tok))
                    rest))))
;;

let valid_repo_component s =
  let valid_char = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' -> true
    | _ -> false
  in
  String.length s > 0
  && not (String.equal s "." || String.equal s "..")
  && String.for_all valid_char s
;;

let unique_visibility flags =
  let add acc v = if List.mem v acc then acc else v :: acc in
  List.rev (List.fold_left add [] flags)
;;

let contract_from_acc acc : (repo_create_contract, string list) result =
  let errors = List.rev acc.errors in
  let errors, owner, name =
    match acc.repo_name_arg with
    | None -> "missing_name" :: "missing_owner" :: errors, None, None
    | Some repo_name ->
      (match String.split_on_char '/' repo_name with
       | [ owner; name ] ->
         let errors =
           (if valid_repo_component owner then errors else "invalid_owner" :: errors)
         in
         let errors =
           if valid_repo_component name then errors else "invalid_name" :: errors
         in
         errors, Some owner, Some name
       | [ _name_without_owner ] -> "missing_owner" :: errors, None, None
       | _ -> "invalid_name" :: errors, None, None)
  in
  let visibility_flags = unique_visibility acc.visibility_flags in
  let errors, visibility =
    match visibility_flags with
    | [] -> "missing_visibility" :: errors, None
    | [ visibility ] -> errors, Some visibility
    | _ -> "ambiguous_visibility" :: errors, None
  in
  match errors, owner, name, visibility with
  | [], Some owner, Some name, Some visibility ->
    Ok
      { owner
      ; name
      ; visibility
      ; lifecycle =
          { add_readme = acc.add_readme
          ; clone = acc.clone
          ; push = acc.push
          ; source = acc.source
          ; remote = acc.remote
          ; template = acc.template
          }
      }
  | errors, _, _, _ -> Error errors
;;

let repo_create_contract_of_gh_simple simple =
  match literal_arg_words simple.Shell_ir.args with
  | Error errors ->
    if repo_create_tail (List.map arg_word simple.Shell_ir.args) = None
    then None
    else Some (Error errors)
  | Ok words ->
    (match repo_create_tail words with
     | None -> None
     | Some tail ->
       Some (contract_from_acc (parse_repo_create_tail empty_repo_create_acc tail)))
;;

let repo_create_contract_of_known simple = function
  | Exec_program.Gh -> repo_create_contract_of_gh_simple simple
  | Exec_program.Ls
  | Exec_program.Cat
  | Exec_program.Pwd
  | Exec_program.Echo
  | Exec_program.Head
  | Exec_program.Tail
  | Exec_program.Rg
  | Exec_program.Grep
  | Exec_program.Find
  | Exec_program.Which
  | Exec_program.Test
  | Exec_program.Basename
  | Exec_program.Dirname
  | Exec_program.Stat
  | Exec_program.Du
  | Exec_program.Df
  | Exec_program.Sort
  | Exec_program.Uniq
  | Exec_program.Wc
  | Exec_program.Cut
  | Exec_program.Tr
  | Exec_program.File
  | Exec_program.Printf
  | Exec_program.Date
  | Exec_program.Env
  | Exec_program.Printenv
  | Exec_program.Hostname
  | Exec_program.Whoami
  | Exec_program.Uname
  | Exec_program.Ps
  | Exec_program.Tty
  | Exec_program.Cp
  | Exec_program.Mv
  | Exec_program.Ln
  | Exec_program.Touch
  | Exec_program.Tee
  | Exec_program.Awk
  | Exec_program.Xargs
  | Exec_program.Git
  | Exec_program.Docker
  | Exec_program.Curl
  | Exec_program.Wget
  | Exec_program.Ssh
  | Exec_program.Scp
  | Exec_program.Tar
  | Exec_program.Rsync
  | Exec_program.Make
  | Exec_program.Cmake
  | Exec_program.Dune_local_sh
  | Exec_program.Diff
  | Exec_program.Patch
  | Exec_program.Mkdir
  | Exec_program.Npm
  | Exec_program.Node
  | Exec_program.Npx
  | Exec_program.Yarn
  | Exec_program.Pnpm
  | Exec_program.Pip
  | Exec_program.Python
  | Exec_program.Python3
  | Exec_program.Pytest
  | Exec_program.Pyright
  | Exec_program.Ruff
  | Exec_program.Opam
  | Exec_program.Ocamlfind
  | Exec_program.Tsc
  | Exec_program.Cargo
  | Exec_program.Rustc
  | Exec_program.Go
  | Exec_program.Gofmt
  | Exec_program.Gradle
  | Exec_program.Java
  | Exec_program.Javac
  | Exec_program.Mvn
  | Exec_program.Ninja
  | Exec_program.Sed
  | Exec_program.Uv
  | Exec_program.Glab
  | Exec_program.Terminal_notifier
  | Exec_program.Osascript
  | Exec_program.Play
  | Exec_program.Rec
  | Exec_program.Ffplay
  | Exec_program.Mpg123
  | Exec_program.Open
  | Exec_program.Psql
  | Exec_program.Mysql
  | Exec_program.Mariadb
  | Exec_program.Cockroach
  | Exec_program.Sudo
  | Exec_program.Su
  | Exec_program.Chmod
  | Exec_program.Chown
  | Exec_program.Rm
  | Exec_program.Dd
  | Exec_program.Mkfs
  | Exec_program.Shutdown
  | Exec_program.Reboot
  | Exec_program.Halt
  | Exec_program.Poweroff -> None
;;

let repo_create_contract_of_simple simple =
  match Exec_program.known simple.Shell_ir.bin with
  | None -> None
  | Some known -> repo_create_contract_of_known simple known
;;

let repo_create_contract_rule_of_simple simple =
  match repo_create_contract_of_simple simple with
  | Some (Error errors) ->
    Some ("gh_repo_create_contract:" ^ String.concat "," errors)
  | Some (Ok _) | None -> None
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

let is_external_field_flag = function
  | "-F" | "--field" -> true
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

let strip_attached_external_field_flag tok =
  let lower = String.lowercase_ascii tok in
  let strip prefix =
    let n = String.length prefix in
    String.sub tok n (String.length tok - n)
  in
  if String.starts_with ~prefix:"--field=" lower then Some (strip "--field=")
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
   -F/--field value beginning with '@' from that file ('@-' = stdin). The
   mutation text is therefore not in argv, so the literal body scanners
   ([body_contains_r2_mutation]/[gh_api_graphql_creates_durable_remote]) cannot
   see it and would R0-Allow it. This is the literal-argv counterpart of the
   Var/Concat opacity above; both mark the body opaque so the capability axis
   asks. The file is NEVER read (no TOCTOU).

   [-f/--raw-field] is intentionally excluded here: gh treats [@...] as a raw
   static string for that flag family, not as file/stdin input. *)
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
    (match strip_attached_external_field_flag tok with
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
             || (is_external_field_flag tok
                 && separate_field_value_is_external_query value)
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
    (match repo_create_contract_rule_of_simple simple with
     | Some _ -> Some Denied
     | None ->
    let words =
      Exec_program.to_string simple.Shell_ir.bin
      :: List.map arg_word simple.Shell_ir.args
    in
    let verb = Gh_verb.classify words in
    if is_graphql_api verb && graphql_query_body_is_opaque simple.Shell_ir.args
    then Some Requires_approval
    else Some (disposition_of_words words verb))
  | Some _ | None -> None
[@@warning "-4"]
