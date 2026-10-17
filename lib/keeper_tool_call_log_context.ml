(** Turn context state and derived runtime JSON for keeper tool-call logs.

    RFC-0225 §3.3: the context lives in a per-run [cell] threaded from turn
    setup to every reader of the same run. The previous global table keyed
    by keeper name let concurrent runs of one keeper overwrite each other,
    so tool-call rows carried the wrong trace_id / keeper_turn_id. *)

type turn_context =
  { agent_name : string option
  ; turn_kind : Turn_record.turn_kind option
  ; lane : string option
  ; tool_choice : string option
  ; thinking_enabled : bool option
  ; prompt_fingerprint : string option
  ; trace_id : string option
  ; session_id : string option
  ; turn : int option
  ; keeper_turn_id : int option
  ; task_id : string option
  ; sandbox_profile : string option
  ; sandbox_root : string option
  ; sandbox_roots : string list option
  ; network_mode : string option
  ; runtime_profile : string option
  ; answer_source_ids : string list
  }

let empty_turn_context =
  { agent_name = None
  ; turn_kind = None
  ; lane = None
  ; tool_choice = None
  ; thinking_enabled = None
  ; prompt_fingerprint = None
  ; trace_id = None
  ; session_id = None
  ; turn = None
  ; keeper_turn_id = None
  ; task_id = None
  ; sandbox_profile = None
  ; sandbox_root = None
  ; sandbox_roots = None
  ; network_mode = None
  ; runtime_profile = None
  ; answer_source_ids = []
  }
;;

type cell = turn_context ref

let create_cell () : cell = ref empty_turn_context

let set_turn_context
      ~(cell : cell)
      ?agent_name
      ?turn_kind
      ?lane
      ?tool_choice
      ?thinking_enabled
      ?prompt_fingerprint
      ?trace_id
      ?session_id
      ?turn
      ?keeper_turn_id
      ?task_id
      ?sandbox_profile
      ?sandbox_root
      ?sandbox_roots
      ?network_mode
      ?runtime_profile
      ?(answer_source_ids = [])
      ()
  =
  cell
  := { agent_name
     ; turn_kind
     ; lane
     ; tool_choice
     ; thinking_enabled
     ; prompt_fingerprint
     ; trace_id
     ; session_id
     ; turn
     ; keeper_turn_id
     ; task_id
     ; sandbox_profile
     ; sandbox_root
     ; sandbox_roots
     ; network_mode
     ; runtime_profile
     ; answer_source_ids
     }
;;

let get_turn_context_record ~(cell : cell) () = !cell

let source_turn_ref (context : turn_context) =
  match context.trace_id, context.keeper_turn_id with
  | Some trace_id, Some absolute_turn ->
      (match Keeper_id.Trace_id.of_string trace_id with
       | Ok trace_id -> Some (Ids.Turn_ref.make
           ~trace_id:(Keeper_id.Trace_id.to_string trace_id) ~absolute_turn)
       | Error _ -> None)
  | Some _, None | None, _ -> None
;;

let get_turn_context ~cell () =
  let ctx = get_turn_context_record ~cell () in
  ( ctx.lane
  , ctx.tool_choice
  , ctx.thinking_enabled
  , ctx.prompt_fingerprint
  , ctx.trace_id
  , ctx.session_id
  , ctx.turn
  , ctx.keeper_turn_id
  , ctx.task_id
  , ctx.sandbox_profile
  , ctx.network_mode )
;;

let runtime_observability_contract_json_for_call ~keeper_name ~cell () =
  let ctx = get_turn_context_record ~cell () in
  Keeper_runtime_contract.runtime_observability_contract_json_from_fields
    ~keeper_name
    ?trace_id:ctx.trace_id
    ?session_id:ctx.session_id
    ?keeper_turn_id:ctx.keeper_turn_id
    ?task_id:ctx.task_id
    ?sandbox_profile:ctx.sandbox_profile
    ?sandbox_root:ctx.sandbox_root
    ?sandbox_roots:ctx.sandbox_roots
    ?network_mode:ctx.network_mode
    ?runtime_profile:ctx.runtime_profile
    ()
;;

let action_radius_json_for_call
      ~cell
      ~tool_name
      ~input
      ~duration_ms
      ?error
      ()
  =
  let ctx = get_turn_context_record ~cell () in
  Keeper_runtime_contract.action_radius_json
    ~tool_name
    ~input
    ~duration_ms
    ?error
    ?sandbox_target:ctx.sandbox_profile
    ()
;;
