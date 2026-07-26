type t = Goal_store.Phase.t

type view = Goal_store.Phase.view =
  | Executing
  | Blocked
  | Paused
  | Completed
  | Dropped

type nonterminal = Goal_store.Phase.nonterminal =
  | N_executing
  | N_blocked
  | N_paused
  | N_dropped

let view = Goal_store.Phase.view
let to_string = Goal_store.Phase.to_string
let view_to_string = Goal_store.Phase.view_to_string
let of_string = Goal_store.Phase.view_of_string
let parse = Goal_store.Phase.parse_view
let to_yojson phase = Goal_store.Phase.view_to_yojson (view phase)
let view_to_yojson = Goal_store.Phase.view_to_yojson
let of_yojson = Goal_store.Phase.view_of_yojson
let all = Goal_store.Phase.all_views
let nonterminal_to_view = Goal_store.Phase.nonterminal_to_view
let executing = Goal_store.Phase.executing
let blocked = Goal_store.Phase.blocked
let paused = Goal_store.Phase.paused
let dropped = Goal_store.Phase.dropped
let is_executing = Goal_store.Phase.is_executing
let is_blocked = Goal_store.Phase.is_blocked
let is_paused = Goal_store.Phase.is_paused
let is_completed = Goal_store.Phase.is_completed
let is_dropped = Goal_store.Phase.is_dropped
let admits_self_directed_progress = Goal_store.Phase.admits_self_directed_progress

type action = Goal_store.Phase.action =
  | Request_complete
  | Pause
  | Resume
  | Block
  | Unblock
  | Drop
  | Reopen

let action_to_string = Goal_store.Phase.action_to_string
let action_of_string = Goal_store.Phase.action_of_string
let parse_action = Goal_store.Phase.parse_action
let all_actions = Goal_store.Phase.all_actions

type transition_outcome = Goal_store.Phase.transition_outcome =
  | Move_to of nonterminal
  | Complete

let decide_transition = Goal_store.Phase.decide_transition
