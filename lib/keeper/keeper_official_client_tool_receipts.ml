type active =
  { block_index : int
  ; mutable invocation : Agent_core.Tool_contract.Invocation.t option
  }

type delivery =
  | Immediate
  | Held_until_released

type receipt =
  { block_index : int
  ; tool_call_id : string
  ; execution_id : Ids.Execution_id.t
  }

type state =
  | Holding of receipt list  (** newest first *)
  | Notifying of receipt Queue.t
  | Delivering of receipt Queue.t

type t =
  { active : (string, active) Hashtbl.t
  ; mutable state : state
  ; notify : block_index:int -> tool_call_id:string -> execution_id:Ids.Execution_id.t -> unit
  }

let create ~delivery ~notify =
  { active = Hashtbl.create 8
  ; state =
      (match delivery with
       | Immediate -> Delivering (Queue.create ())
       | Held_until_released -> Holding [])
  ; notify
  }

let start t ~call_id ~block_index =
  if Hashtbl.mem t.active call_id
  then failwith "official-client dynamic tool started again before its call ended"
  else Hashtbl.replace t.active call_id { block_index; invocation = None }

let finish t ~call_id =
  if Hashtbl.mem t.active call_id
  then Hashtbl.remove t.active call_id
  else failwith "official-client dynamic tool ended outside its producer block"

let deliver t { block_index; tool_call_id; execution_id } =
  t.notify ~block_index ~tool_call_id ~execution_id

let notify_pending t ~delivery pending =
    t.state <- Notifying pending;
    let rec drain () =
      if Queue.is_empty pending then t.state <- Delivering pending
      else
        let receipt = Queue.take pending in
        match deliver t receipt with
        | () -> drain ()
        | exception exn ->
          (* The current notification may already have side effects. Keep
             only unattempted receipts, including commits made reentrantly. *)
          t.state <-
            (match delivery with
             | Immediate -> Delivering pending
             | Held_until_released ->
               Holding (Queue.fold (fun held receipt -> receipt :: held) [] pending));
          raise exn
    in
    drain ()

let release t =
  match t.state with
  | Notifying _ -> ()
  | Delivering pending -> notify_pending t ~delivery:Immediate pending
  | Holding held ->
    let pending = Queue.of_seq (List.to_seq (List.rev held)) in
    notify_pending t ~delivery:Held_until_released pending

let bind t invocation =
  match
    Hashtbl.find_opt t.active (Agent_core.Tool_contract.Invocation.tool_use_id invocation)
  with
  | Some active ->
    (match active.invocation with
     | None -> active.invocation <- Some invocation
     | Some recorded when recorded == invocation -> ()
     | Some _ -> failwith "official-client producer block already owns another invocation")
  | None -> failwith "official-client invocation has no active producer block"

let committed t invocation =
  let tool_call_id = Agent_core.Tool_contract.Invocation.tool_use_id invocation in
  match Hashtbl.find_opt t.active tool_call_id with
  | Some ({ block_index; invocation = Some recorded } : active) when recorded == invocation ->
    (match Keeper_execution_join.peek ~invocation with
     | Some execution_id ->
       let receipt =
         { block_index
         ; tool_call_id
         ; execution_id = Ids.Execution_id.of_string execution_id
         }
       in
       (match t.state with
        | Delivering pending ->
          Queue.add receipt pending;
          notify_pending t ~delivery:Immediate pending
        | Notifying pending -> Queue.add receipt pending
        | Holding held -> t.state <- Holding (receipt :: held))
     | None -> ())
  | Some _ | None -> failwith "official-client receipt has no exact producer invocation"

let hooks t (original : Agent_core.Hooks.hooks) =
  let invoke hook event =
    match hook with
    | Some callback -> callback event
    | None -> Agent_core.Hooks.Continue
  in
  let after hook event =
    (* The log can commit before a later observer is cancelled. Keep receipt
       delivery protected while allowing the original hook to be interrupted. *)
    Eio_guard.protect
      ~finally:(fun () ->
        match event with
        | Agent_core.Hooks.PostToolUse { invocation; _ }
        | Agent_core.Hooks.PostToolUseFailure
            { invocation; stage = Agent_core.Hooks.Validation_before_execution; _ } ->
          committed t invocation
        | Agent_core.Hooks.PostToolUseFailure
            { stage = Agent_core.Hooks.Execution; _ } -> ()
        | _ -> ())
      (fun () -> invoke hook event)
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
