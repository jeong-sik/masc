type active =
  { call_id : string
  ; block_index : int
  ; mutable invocation : Agent_core.Tool_contract.Invocation.t option
  }

type t =
  { mutable active : active option
  ; notify : block_index:int -> tool_call_id:string -> execution_id:Ids.Execution_id.t -> unit
  }

let create ~notify = { active = None; notify }

let start t ~call_id ~block_index =
  match t.active with
  | Some _ -> failwith "Codex dynamic tool started before the previous call ended"
  | None -> t.active <- Some { call_id; block_index; invocation = None }

let finish t ~call_id =
  match t.active with
  | Some active when String.equal active.call_id call_id -> t.active <- None
  | Some _ | None -> failwith "Codex dynamic tool ended outside its producer block"

let bind t invocation =
  match t.active with
  | Some active
    when String.equal active.call_id
           (Agent_core.Tool_contract.Invocation.tool_use_id invocation) ->
    (match active.invocation with
     | None -> active.invocation <- Some invocation
     | Some recorded when recorded == invocation -> ()
     | Some _ -> failwith "Codex producer block already owns another invocation")
  | Some _ | None -> failwith "Codex invocation has no active producer block"

let committed t invocation =
  match t.active with
  | Some ({ invocation = Some recorded; _ } as active) when recorded == invocation ->
    (match Keeper_execution_join.peek ~invocation with
     | Some execution_id ->
       t.notify ~block_index:active.block_index ~tool_call_id:active.call_id
         ~execution_id:(Ids.Execution_id.of_string execution_id)
     | None -> ())
  | Some _ | None -> failwith "Codex receipt has no exact producer invocation"

let hooks t (original : Agent_core.Hooks.hooks) =
  let invoke hook event =
    match hook with
    | Some callback -> callback event
    | None -> Agent_core.Hooks.Continue
  in
  let after hook event =
    let result = invoke hook event in
    (match event with
     | Agent_core.Hooks.PostToolUse { invocation; _ }
     | Agent_core.Hooks.PostToolUseFailure { invocation; stage = Agent_core.Hooks.Validation_before_execution; _ } -> committed t invocation
     | Agent_core.Hooks.PostToolUseFailure { stage = Agent_core.Hooks.Execution; _ } -> ()
     | _ -> ());
    result
  in
  { original with
    pre_tool_use = Some (fun event ->
      (match event with
       | Agent_core.Hooks.PreToolUse { invocation; _ } -> bind t invocation
       | _ -> ());
      invoke original.pre_tool_use event)
  ; post_tool_use = Some (after original.post_tool_use)
  ; post_tool_use_failure = Some (after original.post_tool_use_failure)
  }
