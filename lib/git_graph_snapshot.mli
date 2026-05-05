(** Read-only Git graph snapshot for the dashboard Track 4 visualizer.

    This module never mutates refs and never fetches from the network. It only
    reads the local repository state through bounded argv-based git calls. *)

type repo_info =
  { id : string
  ; root : string
  ; label : string
  ; current_branch : string option
  ; head : string option
  ; dirty : bool
  ; conflict_count : int
  ; branch_count : int
  ; commit_count : int
  ; worktree_count : int
  }
[@@deriving yojson, show]

type agent_lane =
  { id : string
  ; label : string
  ; branch : string option
  ; worktree_path : string
  ; color : string
  }
[@@deriving yojson, show]

type graph_node =
  { id : string
  ; kind : string
  ; label : string
  ; repo_id : string
  ; agent_id : string option
  ; color : string option
  ; status : string
  ; conflict : bool
  ; sha : string option
  ; branch : string option
  ; detail : string option
  }
[@@deriving yojson, show]

type graph_edge =
  { id : string
  ; source : string
  ; target : string
  ; kind : string
  ; label : string option
  }
[@@deriving yojson, show]

type stats =
  { repo_count : int
  ; agent_count : int
  ; branch_count : int
  ; commit_count : int
  ; conflict_count : int
  ; dirty_count : int
  }
[@@deriving yojson, show]

type snapshot =
  { generated_at : string
  ; repos : repo_info list
  ; agents : agent_lane list
  ; nodes : graph_node list
  ; edges : graph_edge list
  ; stats : stats
  ; warnings : string list
  }
[@@deriving yojson, show]

type git_outputs =
  { repo_root : string
  ; head : string option
  ; short_head : string option
  ; current_branch : string option
  ; refs : string list
  ; commits : string list
  ; worktrees : string list
  ; status : string list
  ; merge_state : bool
  }

val snapshot_of_outputs :
  ?repo_id:string -> ?repo_label:string -> generated_at:string -> git_outputs -> snapshot
(** Pure converter used by tests and the HTTP capture path. *)

val empty_json : string -> Yojson.Safe.t
(** Empty dashboard graph response with one warning. *)

val dashboard_http_json :
  ?repo_id:string ->
  ?repo_label:string ->
  ?repo_root:string ->
  config:Coord.config ->
  limit:int ->
  unit ->
  Yojson.Safe.t
(** Capture the local repository graph for dashboard JSON responses. *)

type git_capture_hook =
  workdir:string -> string list -> (Unix.process_status * string) option

val set_git_capture_hook_for_tests : git_capture_hook -> unit
val clear_git_capture_hook_for_tests : unit -> unit
