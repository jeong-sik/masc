(** Turn context state and derived runtime JSON for keeper tool-call logs. *)

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
  ; approval_mode : string option
  ; tool_surface_class : string option
  ; visible_tool_count : int option
  ; required_tools : string list option
  ; required_tool_candidates : string list option
  ; missing_required_tools : string list option
  ; cascade_profile : string option
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
  ; approval_mode = None
  ; tool_surface_class = None
  ; visible_tool_count = None
  ; required_tools = None
  ; required_tool_candidates = None
  ; missing_required_tools = None
  ; cascade_profile = None
  }
;;

let pending_turn_context : (string, turn_context) Hashtbl.t = Hashtbl.create 8

let set_turn_context
      ~keeper_name
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
      ?approval_mode
      ?tool_surface_class
      ?visible_tool_count
      ?required_tools
      ?required_tool_candidates
      ?missing_required_tools
      ?cascade_profile
      ()
  =
  Hashtbl.replace
    pending_turn_context
    keeper_name
    { agent_name
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
    ; approval_mode
    ; tool_surface_class
    ; visible_tool_count
    ; required_tools
    ; required_tool_candidates
    ; missing_required_tools
    ; cascade_profile
    }
;;

let get_turn_context_record ~keeper_name () =
  match Hashtbl.find_opt pending_turn_context keeper_name with
  | Some ctx -> ctx
  | None -> empty_turn_context
;;

let get_turn_context ~keeper_name () =
  let ctx = get_turn_context_record ~keeper_name () in
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
  , ctx.network_mode
  , ctx.approval_mode )
;;

let optional_model model =
  match model with
  | Some value when String.trim value <> "" -> Some value
  | _ -> None
;;

let runtime_contract_json_for_call ~keeper_name ?model () =
  let ctx = get_turn_context_record ~keeper_name () in
  Keeper_runtime_contract.runtime_contract_json_from_fields
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
    ?approval_mode:ctx.approval_mode
    ?tool_surface_class:ctx.tool_surface_class
    ?visible_tool_count:ctx.visible_tool_count
    ?required_tools:ctx.required_tools
    ?required_tool_candidates:ctx.required_tool_candidates
    ?missing_required_tools:ctx.missing_required_tools
    ?model:(optional_model model)
    ?cascade_profile:ctx.cascade_profile
    ()
;;

let action_radius_json_for_call
      ~keeper_name
      ~tool_name
      ~input
      ~success
      ~duration_ms
      ?error
      ()
  =
  let ctx = get_turn_context_record ~keeper_name () in
  Keeper_runtime_contract.action_radius_json
    ~tool_name
    ~input
    ~success
    ~duration_ms
    ?error
    ?sandbox_target:ctx.sandbox_profile
    ()
;;

let reset_for_testing () = Hashtbl.reset pending_turn_context
