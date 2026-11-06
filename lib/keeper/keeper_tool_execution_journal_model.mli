(** The values the journal keeps for a prepared run, and how they are encoded,
    compared and checked.

    [binding] is the async request and generation that own the run.
    [occurrence] is one planned node with its execution and [launch_mode],
    [node_record] says whether it is attempted or settled, and [child_link]
    ties it to the child run it submitted. [resolution],
    [resolution_observation] and [resolution_report] record how an operator
    ended a continuation. [state] is what the journal file holds and [t] is an
    open journal. [worker], [attempt], [child_submission], [continuation],
    [request_observation] and [readiness] are what a caller holds while it
    works on one.

    [binding_json], [resolution_to_json], [resolution_observation_to_json],
    [resolution_report_to_json], [request_observation_to_json],
    [occurrence_json], [child_link_json] and [completed_json] encode these
    values, and [binding_of_json], [resolution_of_json], [occurrence_of_json]
    and [completed_of_json] decode them. [same_binding], [same_owner],
    [same_occurrence], [same_node_identity], [same_children] and
    [same_request_observation] compare them. [occurrence_of_record] and
    [request_observation_resolution] read one part of a value.
    [child_binding_matches] and [child_occurrence_matches] check a child link
    against a composition or an occurrence. [child_intent_proven] asks whether
    the children hold a link for an occurrence, and [child_ack_proven] whether
    that link was also accepted.
    [Keeper_tool_execution_journal] includes this module. *)

open Keeper_tool_execution_journal_types

type binding = {request_id : string; generation : int}

type launch_mode = Initial_launch | Existing_only

type occurrence =
  { node_id : Keeper_tool_plan.Node_id.t; tool_name : string; input : Yojson.Safe.t;
    input_sha : string; owner : binding; sequence : int;
    execution_id : Ids.Execution_id.t; tool_use_id : string; readonly : bool;
    launch_invocation : launch_invocation option; launch_mode : launch_mode }

type node_record =
  | Attempting of occurrence
  | Settled of occurrence * completed * Tool_result.failure_effect_disposition option
      * Keeper_composition_dependency.t option

type child_link =
  { occurrence : occurrence
  ; result_node_id : Keeper_tool_plan.Node_id.t
  ; child_source : source
  ; accepted : Keeper_composition_dependency.composition option
  }

type resolution_decision = Reject | Cancel

type resolution =
  { owner : binding; decision : resolution_decision; requested_by : string
  ; reason : string; resolved_at : float; expected_version : string
  ; marker_version : string }

type resolution_observation =
  { request : Keeper_msg_async.entry; version : string; resolution : resolution option }

type resolution_report =
  { resolution : resolution; marker_retired : bool; retirement_error : error option }

type state =
  { source : source; source_sha : string; source_observation : source_observation option; owner : binding option
  ; prior_owners : (binding * node_record Map.Make(String).t) list; nodes : node_record Map.Make(String).t
  ; children : child_link Map.Make(String).t; resolution : resolution option }

type t = {base_path : string; root : string; path : string; immutable_source : source; source_sha : string;
          immutable_observation : source_observation option}

type request_observation =
  { journal : t; request_entry : Keeper_msg_async.entry; observed_owner : binding
  ; observed_resolution : resolution option; journal_version : string; observed_at : float }

type worker = {journal : t; binding : binding}

type attempt = {worker : worker; occurrence : occurrence}

type child_submission = {attempt : attempt; link : child_link}

type continuation =
  { journal : t; expected_owner : binding
  ; terminal_entry : Keeper_msg_async.entry
  ; predecessor_terminals : Keeper_msg_async.entry list
  ; suspended_nodes : node_record Map.Make(String).t
  ; suspended_children : child_link Map.Make(String).t
  ; dependencies : Keeper_composition_dependency.t list }

type readiness = Waiting_for_results | Results_ready

val binding_json :
  binding ->
  Yojson.Safe.t

val binding_of_json : Yojson.Safe.t -> binding

val same_binding : binding -> binding -> bool

val same_owner : binding option -> binding option -> bool

val resolution_to_json : resolution -> Yojson.Safe.t

val resolution_of_json : Yojson.Safe.t -> resolution

val resolution_observation_to_json : resolution_observation -> Yojson.Safe.t

val resolution_report_to_json : resolution_report -> Yojson.Safe.t

val request_observation_to_json : request_observation -> Yojson.Safe.t

val request_observation_resolution : request_observation -> resolution option

val same_request_observation : request_observation -> request_observation -> bool

val occurrence_of_record : node_record -> occurrence

val occurrence_json :
  occurrence -> Yojson.Safe.t

val occurrence_of_json : Yojson.Safe.t -> occurrence

val same_occurrence : occurrence -> occurrence -> bool

val same_node_identity :
  occurrence ->
  node_id:Keeper_tool_plan.Node_id.t -> tool_name:string -> input:Yojson.Safe.t -> bool

val child_link_json :
  child_link -> Yojson.Safe.t

val same_children : child_link Map.Make(String).t -> child_link Map.Make(String).t -> bool

val child_binding_matches : child_link -> Keeper_composition_dependency.composition -> bool

val child_occurrence_matches : child_link -> occurrence -> bool

val child_intent_proven : child_link Map.Make(String).t -> occurrence -> bool

val child_ack_proven : child_link Map.Make(String).t -> occurrence -> bool

val completed_json :
  completed ->
  Yojson.Safe.t

val completed_of_json :
  Yojson.Safe.t -> completed
