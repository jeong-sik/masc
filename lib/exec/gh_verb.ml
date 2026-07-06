(* Gh_verb — typed capability identity for [gh] commands (RFC-0309 §3.1, W1).
   See gh_verb.mli for the design boundary. No risk dependency by design. *)

type gh_family =
  | Pr
  | Issue
  | Repo
  | Discussion
  | Release
  | Secret
  | Ssh_key
  | Workflow
  | Auth
  | Gist
  | Ruleset
  | Label
  | Run
  | Cache
  | Project
  | Api
  | Other of string

type t =
  { family : gh_family
  ; action : string option
  }

let family_token : gh_family -> string = function
  | Pr -> "pr"
  | Issue -> "issue"
  | Repo -> "repo"
  | Discussion -> "discussion"
  | Release -> "release"
  | Secret -> "secret"
  | Ssh_key -> "ssh-key"
  | Workflow -> "workflow"
  | Auth -> "auth"
  | Gist -> "gist"
  | Ruleset -> "ruleset"
  | Label -> "label"
  | Run -> "run"
  | Cache -> "cache"
  | Project -> "project"
  | Api -> "api"
  | Other s -> s
;;

let string_of_family = function
  | Other s -> "other:" ^ s
  | ( Pr | Issue | Repo | Discussion | Release | Secret | Ssh_key | Workflow
    | Auth | Gist | Ruleset | Label | Run | Cache | Project | Api ) as fam ->
    family_token fam
;;

(* The inverse of [family_token] for known families. [Other] is the
   fail-representable default so a new gh top-level area is never silently
   read as a known family. *)
let family_of_token (token : string) : gh_family =
  match String.lowercase_ascii token with
  | "pr" -> Pr
  | "issue" -> Issue
  | "repo" -> Repo
  | "discussion" -> Discussion
  | "release" -> Release
  | "secret" -> Secret
  | "ssh-key" -> Ssh_key
  | "workflow" -> Workflow
  | "auth" -> Auth
  | "gist" -> Gist
  | "ruleset" -> Ruleset
  | "label" -> Label
  | "run" -> Run
  | "cache" -> Cache
  | "project" -> Project
  | "api" -> Api
  | other -> Other other
;;

let is_flag (tok : string) : bool = String.length tok > 0 && tok.[0] = '-'

(* Drop leading flags, mirroring classify_repo_hosting_cli's boolean-default
   flag skip: any [-foo] is a value-less flag and does not consume the next
   token. Over-surfacing a value-taking flag's value as the next positional is
   accepted (the word-list floor owns adversarial flag injection). *)
let rec drop_flags = function
  | tok :: tl when is_flag tok -> drop_flags tl
  | rest -> rest
;;

let of_fields ~(subcommand : string) ~(action : string option) : t =
  { family = family_of_token subcommand; action }
;;

let classify (words : string list) : t =
  (* Tolerate a leading "gh" head so callers may pass either the full argv
     or the args after the program name. The head is the canonical program
     token ("gh"); matched as a literal pattern rather than a lowercased
     equality so this stays a boundary strip, not an enum-string classifier. *)
  let args =
    match words with
    | "gh" :: rest -> rest
    | _ -> words
  in
  match drop_flags args with
  | [] -> { family = Other ""; action = None }
  | subcommand :: after ->
    let family = family_of_token subcommand in
    let action =
      match drop_flags after with
      | [] -> None
      | act :: _ -> Some act
    in
    { family; action }
;;

let pp (fmt : Format.formatter) (v : t) : unit =
  Format.fprintf fmt "gh:%s%s" (string_of_family v.family)
    (match v.action with Some a -> ":" ^ a | None -> "")
;;
