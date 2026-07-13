(** Turn context state and derived runtime JSON for keeper tool-call logs.

    RFC-0225 §3.3: the context lives in a per-run [cell] threaded from turn
    setup to every reader of the same run. The previous global table keyed
    by keeper name let concurrent runs of one keeper overwrite each other,
    so tool-call rows carried the wrong trace_id / keeper_turn_id. *)

type turn_context =
  { agent_name : string option
  ; lane : string option
  ; tool_choice : string option
  ; thinking_enabled : bool option
  ; thinking_budget : int option
  ; prompt_fingerprint : string option
  ; trace_id : string option
  ; session_id : string option
  ; generation : int option
  ; turn : int option
  ; keeper_turn_id : int option
  ; task_id : string option
  ; goal_ids : string list option
  ; sandbox_profile : string option
  ; sandbox_root : string option
  ; allowed_paths : string list option
  ; network_mode : string option
  ; runtime_profile : string option
  }

let empty_turn_context =
  { agent_name = None
  ; lane = None
  ; tool_choice = None
  ; thinking_enabled = None
  ; thinking_budget = None
  ; prompt_fingerprint = None
  ; trace_id = None
  ; session_id = None
  ; generation = None
  ; turn = None
  ; keeper_turn_id = None
  ; task_id = None
  ; goal_ids = None
  ; sandbox_profile = None
  ; sandbox_root = None
  ; allowed_paths = None
  ; network_mode = None
  ; runtime_profile = None
  }
;;

type cell = turn_context ref

let create_cell () : cell = ref empty_turn_context

let set_turn_context
      ~(cell : cell)
      ?agent_name
      ?lane
      ?tool_choice
      ?thinking_enabled
      ?thinking_budget
      ?prompt_fingerprint
      ?trace_id
      ?session_id
      ?generation
      ?turn
      ?keeper_turn_id
      ?task_id
      ?goal_ids
      ?sandbox_profile
      ?sandbox_root
      ?allowed_paths
      ?network_mode
      ?runtime_profile
      ()
  =
  cell
  := { agent_name
     ; lane
     ; tool_choice
     ; thinking_enabled
     ; thinking_budget
     ; prompt_fingerprint
     ; trace_id
     ; session_id
     ; generation
     ; turn
     ; keeper_turn_id
     ; task_id
     ; goal_ids
     ; sandbox_profile
     ; sandbox_root
     ; allowed_paths
     ; network_mode
     ; runtime_profile
     }
;;

let get_turn_context_record ~(cell : cell) () = !cell

let get_turn_context ~cell () =
  let ctx = get_turn_context_record ~cell () in
  ( ctx.lane
  , ctx.tool_choice
  , ctx.thinking_enabled
  , ctx.thinking_budget
  , ctx.prompt_fingerprint
  , ctx.trace_id
  , ctx.session_id
  , ctx.turn
  , ctx.keeper_turn_id
  , ctx.task_id
  , ctx.goal_ids
  , ctx.sandbox_profile
  , ctx.network_mode )
;;

let runtime_observability_contract_json_for_call ~keeper_name ~cell () =
  let ctx = get_turn_context_record ~cell () in
  Keeper_runtime_contract.runtime_observability_contract_json_from_fields
    ~keeper_name
    ?agent_name:ctx.agent_name
    ?trace_id:ctx.trace_id
    ?session_id:ctx.session_id
    ?generation:ctx.generation
    ?keeper_turn_id:ctx.keeper_turn_id
    ?task_id:ctx.task_id
    ?goal_ids:ctx.goal_ids
    ?sandbox_profile:ctx.sandbox_profile
    ?sandbox_root:ctx.sandbox_root
    ?allowed_paths:ctx.allowed_paths
    ?network_mode:ctx.network_mode
    ?runtime_profile:ctx.runtime_profile
    ()
;;

let action_radius_json_for_call
      ~cell
      ~tool_name
      ~input
      ~success
      ~duration_ms
      ?error
      ()
  =
  let ctx = get_turn_context_record ~cell () in
  Keeper_runtime_contract.action_radius_json
    ~tool_name
    ~input
    ~success
    ~duration_ms
    ?error
    ?sandbox_target:ctx.sandbox_profile
    ()
;;
