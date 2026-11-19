module Context = Keeper_librarian_context
module References = Set.Make (String)

type reader =
  { base_path : string
  ; keeper_name : string
  ; mutable meta : (Keeper_meta_contract.keeper_meta option, string) result option
  }

let reader ~base_path ~keeper_name = { base_path; keeper_name; meta = None }

(* Queue observers do not run through the Owner's profile refresh. Resolve
   the effective TOML aliases here rather than using its cached projection. *)
let effective_meta reader =
  match reader.meta with
  | Some result -> result
  | None ->
    let result =
      Keeper_meta_store.read_effective_meta
        (Workspace.default_config reader.base_path)
        reader.keeper_name
    in
    reader.meta <- Some result;
    result

let can_project reader (stimulus : Keeper_event_queue.stimulus) =
  match stimulus.payload with
  | Keeper_event_queue.Board_routing_pending _ -> false
  | Keeper_event_queue.Board_signal _ | Board_attention _ ->
    (match effective_meta reader with
     | Ok (Some meta) -> Keeper_board_audience.can_project_queued_stimulus ~meta stimulus
     | Ok None | Error _ -> false)
  | Keeper_event_queue.Bootstrap | Fusion_completed _ | Schedule_due _
  | Connector_attention _ | Hitl_resolved _ | Ask_answered _
  | Completion_authority_rejected _ | Task_outcome _ | Task_cancelled _
  | Workspace_message _ | Delegate_completed _ | Composition_completed _
  | Tool_result_ready _ | Owned_job_completed _ -> true

type withheld =
  | Board_source_unreadable
  | Event_source_undecodable

let shown reader (snapshot : Context.snapshot) =
  let sources, withheld =
    List.fold_left
      (fun (sources, withheld) (source : Context.source) ->
         match Context.stimulus_of_source source with
         | None -> source :: sources, withheld
         | Some (Error _) -> sources, Event_source_undecodable :: withheld
         | Some (Ok stimulus) ->
           if can_project reader stimulus
           then source :: sources, withheld
           else sources, Board_source_unreadable :: withheld)
      ([], [])
      snapshot.sources
  in
  let sources = List.rev sources in
  let allowed =
    List.fold_left
      (fun set (source : Context.source) -> References.add source.reference set)
      References.empty
      sources
  in
  let pockets =
    List.filter
      (fun (pocket : Context.pocket) ->
         List.for_all (fun reference -> References.mem reference allowed) pocket.sources)
      snapshot.pockets
  in
  { snapshot with sources; pockets }, List.rev withheld
