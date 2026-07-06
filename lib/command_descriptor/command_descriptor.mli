(** Neutral shell command descriptor projection.

    This module intentionally does not depend on IDE storage. Tool execution
    can attach deterministic command metadata without knowing which consumer
    will render or persist it. *)

type t =
  | Gh_pr_create of { title : string; base : string; draft : bool }
  | Gh_pr_search of { query : string; state : string option }
  | Gh_pr_merge of { pr_number : int; squash : bool }
  | Gh_pr_comment of { pr_number : int; body : string }
  | Gh_pr_close of { pr_number : int }
  | Gh_pr_edit of { pr_number : int; title : string option }
  | Gh_pr_review of { pr_number : int }
  | Gh_issue_create of { title : string; body : string }
  | Gh_issue_close of { issue_number : int }
  | Git_push of { remote : string; branch : string; force : bool }
  | Git_commit of { message : string }
  | Gh_api_pr_create of { repo : string; title : string; base : string }
  | Gh_api_pr_merge of { repo : string; pr_number : int }
  | Gh_api_pr_comment of { repo : string; pr_number : int; body : string }
  | Pipe_chain of { first_cmd : string; last_cmd : string; length : int }
  | Generic

type pr_action_surface =
  | Gh_cli

type pr_action =
  | Create
  | Search
  | Merge
  | Comment
  | Close
  | Edit
  | Review
  | Reopen
  | Ready

type pr_action_event =
  { surface : pr_action_surface
  ; action : pr_action
  }

val to_json : t -> Yojson.Safe.t
val compute : Masc_exec.Shell_ir.t -> t
val pr_action_surface_to_string : pr_action_surface -> string
val pr_action_to_string : pr_action -> string
val pr_action_events_of_ir : Masc_exec.Shell_ir.t -> pr_action_event list
