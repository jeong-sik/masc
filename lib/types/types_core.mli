(** MASC MCP core domain types. *)

include module type of struct
  include Ids
end

val now_iso : unit -> string
val parse_iso8601_opt : string -> float option
val parse_iso8601 : ?default_time:float -> string -> float

type agent_status =
  | Active
  | Busy
  | Listening
  | Inactive
[@@deriving show { with_path = false }]

val agent_status_to_string : agent_status -> string
val string_of_agent_status : agent_status -> string
val all_agent_statuses : agent_status list
val valid_agent_status_strings : string list
val agent_status_of_string_opt : string -> agent_status option
val agent_status_of_string_r : string -> (agent_status, string) result
val agent_status_to_yojson : agent_status -> Yojson.Safe.t
val agent_status_of_yojson : Yojson.Safe.t -> (agent_status, string) result

type agent_meta =
  { session_id : string
  ; agent_type : string
  ; pid : int option [@default None]
  ; hostname : string option [@default None]
  ; tty : string option [@default None]
  ; worktree : string option [@default None]
  ; parent_task : string option [@default None]
  ; keeper_name : string option [@default None]
  ; keeper_id : string option [@default None]
  }
[@@deriving yojson { strict = false }, show]

type agent =
  { id : Agent_id.t option [@default None]
  ; name : string
  ; agent_type : string [@default "unknown"]
  ; status : agent_status
  ; capabilities : string list
  ; current_task : string option [@default None]
  ; joined_at : string
  ; last_seen : string
  ; meta : agent_meta option [@default None]
  }
[@@deriving show]

val agent_to_yojson : agent -> Yojson.Safe.t
val agent_of_yojson : Yojson.Safe.t -> (agent, string) result
val iso8601_of_unix_seconds : float -> string
val normalize_agent_last_seen : joined_at:Yojson.Safe.t option -> Yojson.Safe.t -> Yojson.Safe.t option
val short_json_repr : Yojson.Safe.t -> string

type room_info =
  { id : string
  ; name : string
  ; description : string option [@default None]
  ; created_at : string
  ; created_by : string option [@default None]
  ; agent_count : int [@default 0]
  ; task_count : int [@default 0]
  }
[@@deriving yojson { strict = false }, show]

type room_registry =
  { rooms : room_info list [@default []]
  ; default_room : string [@default "default"]
  ; current_room : string option [@default None]
  }
[@@deriving yojson { strict = false }, show]

type task_action =
  | Claim
  | Start
  | Done_action
  | Cancel
  | Release
  | Submit_for_verification
  | Approve_verification
  | Reject_verification
  | Submit_pr_evidence
[@@deriving show]

val task_action_of_string : string -> (task_action, string) result
val task_action_of_alias : string -> task_action option
val task_action_of_string_lenient : string -> (task_action, string) result
val task_action_to_string : task_action -> string
val all_task_actions : task_action list
val valid_task_action_strings : string list

type task_status =
  | Todo
  | Claimed of { assignee : string; claimed_at : string }
  | InProgress of { assignee : string; started_at : string }
  | AwaitingVerification of
      { assignee : string
      ; submitted_at : string
      ; verification_id : string
      ; deadline : string option
      }
  | Done of { assignee : string; completed_at : string; notes : string option }
  | Cancelled of { cancelled_by : string; cancelled_at : string; reason : string option }
[@@deriving show]

val task_status_to_string : task_status -> string
val string_of_task_status : task_status -> string
val task_status_icon : task_status -> string
val task_display_assignee : task_status -> string
val task_assignee_of_status : task_status -> string option
val task_status_is_terminal : task_status -> bool
val task_status_is_done : task_status -> bool
val all_task_status_names : string list
val valid_task_status_strings : string list
val task_status_to_yojson : task_status -> Yojson.Safe.t
val task_status_of_yojson : Yojson.Safe.t -> (task_status, string) result

type worktree_info =
  { branch : string
  ; path : string
  ; git_root : string
  ; repo_name : string
  }
[@@deriving show, yojson { strict = false }]

type task_execution_links =
  { operation_id : string option [@default None]
  ; session_id : string option [@default None]
  ; autoresearch_loop_id : string option [@default None]
  }
[@@deriving show, yojson { strict = false }]

type task_contract =
  { strict : bool [@default false]
  ; completion_contract : string list [@default []]
  ; required_tools : string list [@default []]
  ; required_evidence : string list [@default []]
  ; inspect_gate_evidence : string list [@default []]
  ; verify_gate_evidence : string list [@default []]
  ; links : task_execution_links
        [@default
          { operation_id = None; session_id = None; autoresearch_loop_id = None }]
  }
[@@deriving show, yojson { strict = false }]

type task_handoff_context =
  { summary : string [@default ""]
  ; reason : string option [@default None]
  ; next_step : string option [@default None]
  ; failure_mode : string option [@default None]
  ; evidence_refs : string list [@default []]
  ; updated_at : string option [@default None]
  ; updated_by : string option [@default None]
  }
[@@deriving show, yojson { strict = false }]

type task =
  { id : string
  ; title : string
  ; description : string
  ; task_status : task_status [@key "status"]
  ; priority : int [@default 3]
  ; files : string list [@default []]
  ; created_at : string
  ; created_by : string option [@default None]
  ; worktree : worktree_info option [@default None]
  ; goal_id : string option [@default None]
  ; stage : Task_stage.t option [@default None]
  ; contract : task_contract option [@default None]
  ; handoff_context : task_handoff_context option [@default None]
  ; cycle_count : int [@default 0]
  ; do_not_reclaim_reason : string option [@default None]
  }
[@@deriving show]

val task_to_yojson : task -> Yojson.Safe.t
val task_of_yojson : Yojson.Safe.t -> (task, string) result

type message =
  { seq : int
  ; from_agent : string [@key "from"]
  ; msg_type : string [@key "type"] [@default "broadcast"]
  ; content : string
  ; mention : string option [@default None]
  ; timestamp : string
  ; trace_context : string option [@default None]
  ; expires_at : float option [@default None]
  ; relevance : string [@default "medium"]
  }
[@@deriving yojson { strict = false }, show]

type room_state =
  { protocol_version : string
  ; project : string
  ; started_at : string
  ; message_seq : int
  ; active_agents : string list
  ; paused : bool [@default false]
  ; pause_reason : string option [@default None]
  ; paused_by : string option [@default None]
  ; paused_at : string option [@default None]
  ; search_strategy_default : string option [@default None]
  ; speculation_enabled : bool [@default false]
  ; speculation_budget : int option [@default None]
  }
[@@deriving yojson { strict = false }, show]

type tempo_mode =
  | Normal
  | Slow
  | Fast
  | Paused
[@@deriving show { with_path = false }]

val tempo_mode_to_string : tempo_mode -> string
val string_of_tempo_mode : tempo_mode -> string
val tempo_mode_of_string : string -> (tempo_mode, string) result
val tempo_mode_to_yojson : tempo_mode -> Yojson.Safe.t
val tempo_mode_of_yojson : Yojson.Safe.t -> (tempo_mode, string) result

type tempo_config =
  { mode : tempo_mode
  ; delay_ms : int
  ; reason : string option
  ; set_by : string option
  ; set_at : string option
  }
[@@deriving show]

val default_tempo_config : tempo_config
val tempo_config_to_yojson : tempo_config -> Yojson.Safe.t
val tempo_config_of_yojson : Yojson.Safe.t -> (tempo_config, string) result

type backlog =
  { tasks : task list
  ; last_updated : string
  ; version : int
  }
[@@deriving show]

val backlog_to_yojson : backlog -> Yojson.Safe.t
val backlog_of_yojson : Yojson.Safe.t -> (backlog, string) result

type a2a_task_status =
  | A2APending
  | A2ARunning
  | A2ACompleted
  | A2AFailed
  | A2ACanceled
[@@deriving show { with_path = false }]

val a2a_task_status_to_string : a2a_task_status -> string
val a2a_task_status_of_string : string -> (a2a_task_status, string) result
val a2a_task_status_to_yojson : a2a_task_status -> Yojson.Safe.t
val a2a_task_status_of_yojson : Yojson.Safe.t -> (a2a_task_status, string) result

type portal_state =
  | PortalOpen
  | PortalClosed
[@@deriving show { with_path = false }]

val portal_state_to_string : portal_state -> string
val portal_state_of_string : string -> (portal_state, string) result
val portal_state_to_yojson : portal_state -> Yojson.Safe.t
val portal_state_of_yojson : Yojson.Safe.t -> (portal_state, string) result

type a2a_task =
  { a2a_id : string [@key "id"]
  ; from_agent : string [@key "from"]
  ; to_agent : string [@key "to"]
  ; a2a_message : string [@key "message"]
  ; a2a_status : a2a_task_status [@key "status"]
  ; a2a_result : string option [@key "result"] [@default None]
  ; created_at : string [@key "createdAt"]
  ; updated_at : string [@key "updatedAt"]
  }
[@@deriving show]

val a2a_task_to_yojson : a2a_task -> Yojson.Safe.t
val a2a_task_of_yojson : Yojson.Safe.t -> (a2a_task, string) result

type portal =
  { portal_from : string [@key "from"]
  ; portal_target : string [@key "target"]
  ; portal_opened_at : string [@key "openedAt"]
  ; portal_status : portal_state [@key "status"]
  ; task_count : int [@key "taskCount"]
  }
[@@deriving show]

val portal_to_yojson : portal -> Yojson.Safe.t
val portal_of_yojson : Yojson.Safe.t -> (portal, string) result

type sse_session =
  { agent_name : string
  ; connected_at : string
  ; last_activity : float
  ; is_listening : bool
  }
[@@deriving show]

type tool_result =
  { success : bool
  ; message : string
  ; data : Yojson.Safe.t option [@default None]
  }
[@@deriving show]

val tool_result_to_yojson : tool_result -> Yojson.Safe.t

type tool_schema =
  { name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  }

type claim_next_result =
  | Claim_next_claimed of
      { task_id : string
      ; title : string
      ; priority : int
      ; released_task_id : string option
      ; message : string
      }
  | Claim_next_no_unclaimed
  | Claim_next_no_eligible of { excluded_count : int }
  | Claim_next_error of string
