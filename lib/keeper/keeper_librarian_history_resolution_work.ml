module Intent = Keeper_librarian_history_resolution_intent
module Resolution = Keeper_librarian_history_resolution
module Fence = Keeper_librarian_history_resolution_state
module Lineage = Keeper_librarian_history_resolution_lineage
module Request = Keeper_librarian_durable_request
module Source = Keeper_librarian_durable_capture
module Owner = Lane_addon_tool_request_owner
module Durable_owner = Keeper_librarian_durable_owner
module Store = Lane_addon_store
module Current = Keeper_memory_os_current
module Progress = Lane_addon_request_progress
module Edge = Keeper_librarian_durable_edge
module Cursor = Keeper_external_read_cursor
open Result.Syntax
type error = Intent.error
type submission = {intent:Intent.t;reobserved:bool}
type completion = Not_observed | Memory_committed of {request_id:string} | Completion_unavailable of string
type atom_range = {trace_id:string;history_start_boundary_line:int;start_atom:int;end_atom:int}
type official_range = {after_boundary_line:int;selected_through:int;selected_count:int}
type original_range = {atom:atom_range option;official:official_range option}
type observation = {intents:Intent.t list;fence:Fence.t option;completion:completion;
  original_range:(original_range,string) result}
let io work = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ work
let unavailable result = Result.map_error (fun detail -> Intent.Unavailable detail) result
let require condition message = if condition then Ok () else Error message
let submit ~config ~keeper_name ~request_id ~expected ~actor ~reason ~now =
  try let+ intent,reobserved=Intent.submit ~config ~keeper_name ~request_id ~expected ~actor ~reason ~now in
    {intent;reobserved}
  with Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Error (Intent.Publication_uncertain (Printexc.to_string exn))
let original ~config ~keeper_name ~store intent =
  let* parent=Owner.load ~store ~scope:intent.Intent.scope ~request_id:intent.original_request_id
    |> Result.map_error Owner.error_to_string in
  let* parent=Option.to_result ~none:"Resolution original is absent" parent in
  let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path in
  let* owner=Request.observe_record_owner ~base_path:config.base_path ~keepers_dir parent in
  let* ()=require (Request.keeper_id owner=keeper_name) "Resolution original belongs to another Keeper" in
  let+ request=Request.restore ~owner parent in parent,request
let fence_matches intent fence =
  require (fence.Fence.scope=intent.Intent.scope && fence.request_id=intent.original_request_id
    && fence.expected=intent.expected && fence.actor=intent.actor && fence.reason=intent.reason)
    "Existing history fence belongs to another resolution"
type child_source = Replayable of Source.t | Unreplayable of string
let prepare_child ~config ~keeper_name ~store intent =
  let* parent,request=io (fun () -> original ~config ~keeper_name ~store intent) |> unavailable in
  let* source=io (fun () ->
    Keeper_librarian_durable_source_lock.with_original_snapshot ~request (fun ~messages:_ ->
      let* fence=Lineage.fenced_original ~store ~request ~original:parent in
      let* fence=Option.to_result ~none:"Resolution fence disappeared" fence in
      let* ()=fence_matches intent fence in
      let owner=Request.physical_owner request in
      let keepers_dir=Request.keepers_dir owner in
      let* anchor=Current.capture_program_anchor ~keepers_dir ~keeper_id:keeper_name in
      let* ()=Request.confirm_owner request in
      let snapshot=Current.program_anchor_snapshot anchor in
      let expected_revision=Option.map (fun (snapshot:Current.t) -> snapshot.revision) snapshot in
      let current=Option.map (fun (snapshot:Current.t) ->
        ({Keeper_librarian.facts=snapshot.facts}:Keeper_librarian.current_selection)) snapshot in
      match Source.with_current ~expected_revision ~current (Request.source request) with
      | Error error -> Ok (Unreplayable (Source.error_to_string error))
      | Ok source ->
      let runtime_keepers_dir=Request.runtime_keepers_dir owner in
      let* expected=Cursor.observe ~runtime_keepers_dir ~keeper_name in
      if Cursor.observation_offset expected<>Cursor.observation_offset (Source.external_before source) then
        Ok (Unreplayable "Original external offset changed before continuation")
      else
      let+ ()=Cursor.restore_original_preparation ~runtime_keepers_dir ~keeper_name
        ~expected ~original:(Source.external_prepared source) in Replayable source)) |> unavailable in
  match source with
  | Unreplayable detail ->
    io (fun () -> Intent.refuse ~store ~expected:intent (Intent.No_longer_eligible detail))
  | Replayable source ->
  let* source_lines=io (fun () ->
    Keeper_memory_source_current.read_budget_lines
      ~keepers_dir:(Request.keepers_dir (Request.physical_owner request)) ~keeper_id:keeper_name)
    |> unavailable in
  let* preparation=Keeper_librarian_runtime.prepare_durable ~now:(Time_compat.now ()) ~source_lines
    (Source.input source) |> unavailable in
  Edge.with_destination ~config ~reserved:(Edge.reserved ()) (fun destination ->
    let* child=io (fun () -> Request.create ~request_id:(Request.fresh_request_id (Request.physical_owner request))
      ~predecessor:{Request.request_id=parent.request_id;request_digest=parent.request_digest}
      ~owner:(Request.physical_owner request) ~destination ~source ~preparation ()) in
    Ok (io (fun () -> Intent.intend_child ~store ~expected:intent child)))
    |> unavailable |> Result.join
(* An original as the pass reads it here: its record and the index in that
   record's summary. The owner the index names is observed live. *)
let observed_index ~config ~keeper_name ~foreign record =
  let* index=Request.index_of_summary record in
  let base_path=config.Workspace.base_path in
  let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let* owner=Request.observe_index_owner ~base_path ~keepers_dir index in
  let* ()=require (Request.keeper_id owner=keeper_name) foreign in
  let+ ()=Request.confirm_index_source_root index in index
let load_record ~store ~scope ~request_id ~absent =
  let* record=Owner.load_record ~store ~scope ~request_id |> Result.map_error Owner.error_to_string in
  Option.to_result ~none:absent record
(* The parent's body is not read: its fence and the child's lineage are
   checked on the two records and their indexes. Only a child whose record is
   absent is made, from the body its intent staged. *)
let recover_child ~config ~keeper_name ~store intent =
  let module Record=Owner.Record in
  let* parent,parent_index=io (fun () ->
    let* parent=load_record ~store ~scope:intent.Intent.scope ~request_id:intent.original_request_id
      ~absent:"Resolution original is absent" in
    let+ index=observed_index ~config ~keeper_name ~foreign:"Resolution original belongs to another Keeper" parent in
    parent,index) |> unavailable in
  let* fence=io (fun () -> Lineage.fenced_record ~store ~record:parent ~index:parent_index) |> unavailable in
  let* fence=Option.to_result ~none:(Intent.Unavailable "Resolution fence disappeared") fence in
  let* ()=fence_matches intent fence |> unavailable in
  let* intended=Option.to_result ~none:(Intent.Conflict "Resolution has no child publication intent") (Intent.child intent) in
  let* observed=io (fun () -> Owner.load_record ~store ~scope:intent.scope ~request_id:intended.request_id
    |> Result.map_error Owner.error_to_string) |> unavailable in
  let* child=match observed,intent.phase with
    | None,Intent.Child_intended _ ->
      (* The intent staged this body before it named the child. A missing or
         changed body is an error; the child is never made again. *)
      let* request=io (fun () ->
        let* json=Owner.load_successor_request ~store ~scope:intent.scope
          {Progress.request_id=intended.request_id;request_digest=intended.request_digest}
          |> Result.map_error Owner.error_to_string in
        Request.of_json ~owner:parent_index.owner json) |> unavailable in
      let+ child=Durable_owner.retain ~store request
        |> Result.map_error (fun error -> Intent.Unavailable (Durable_owner.error_to_string error)) in
      Owner.listed child
    | Some child,(Child_intended _ | Child_confirmed _) -> Ok child
    | None,Child_confirmed _ -> Error (Intent.Unavailable "Acknowledged resolution child disappeared")
    | (None | Some _),(Requested | Refused _ | Fenced) -> Error (Intent.Conflict "Resolution has no child publication intent") in
  let* index=io (fun () ->
    let* index=observed_index ~config ~keeper_name ~foreign:"Resolution child belongs to another Keeper" child in
    let* ()=require (Record.request_id child=intended.request_id && Record.request_digest child=intended.request_digest)
      "Published resolution child differs from its durable intent" in
    let* ()=require (index.owner=parent_index.owner) "Resolution child changed its original owner" in
    (* The record names a child only by ID and digest, so the child itself
       says whose child it is. *)
    let+ ()=match index.predecessor with
      | Some predecessor ->
        require (predecessor.request_id=Record.request_id parent
          && predecessor.request_digest=Record.request_digest parent)
          "Resolution child has another original predecessor"
      | None -> Error "Resolution child has no original predecessor" in
    index) |> unavailable in
  match intent.phase with
  | Child_intended _ ->
    (* The acknowledgement is written once. The child's body is read here so
       the index just checked is the body's before the intent says so. *)
    let* ()=io (fun () ->
      let* original=Owner.load_listed ~store child |> Result.map_error Owner.error_to_string in
      let+ _=Request.restore ~owner:index.owner original in ()) |> unavailable in
    io (fun () -> Intent.confirm_child ~store ~expected:intent child) |> Result.map (fun _ -> ())
  | Child_confirmed _ ->
    io (fun () -> Lineage.confirm_predecessor_record ~store ~require_confirmed:true child index) |> unavailable
  | Requested | Refused _ | Fenced -> Error (Intent.Conflict "Resolution child phase changed")
(* Descends by record and index. A fenced original leads to its resolution
   child; an unfenced one is read, body and all, only once its progress says
   it settled. *)
let find_completed ~config ~keeper_name ~store ~child_id =
  let rec descend seen id =
    let* ()=require (not (List.mem id seen)) "Resolution completion ancestry contains a cycle" in
    let* record,index=io (fun () ->
      let* scope=Request.scope_of_request_id id in
      let* record=load_record ~store ~scope ~request_id:id ~absent:"Resolution child is absent" in
      let+ index=observed_index ~config ~keeper_name ~foreign:"Resolution child belongs to another Keeper" record in
      record,index) in
    (* Every original the descent reaches has its lineage confirmed, fenced
       or not: from its record and index while no body is needed, from the
       body where one is read anyway. *)
    let by_record ()=io (fun () -> Lineage.confirm_predecessor_record ~store ~require_confirmed:true record index) in
    let* fence=io (fun () -> Lineage.fenced_record ~store ~record ~index) in
    match fence with
    | Some _ ->
      let* ()=by_record () in
      let* next=io (fun () -> Lineage.confirmed_resolution_child ~store ~record ~index) in
      (match next with None -> Ok None | Some next -> descend (id::seen) next)
    | None ->
    match Progress.phase (Owner.Record.progress record) with
    | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
    | Rejected _ | Subdividing _ | Subdivided _ -> let+ ()=by_record () in None
    | Finished _ | Conflicted _ ->
    let* original,request=io (fun () ->
      let* original=Owner.load_listed ~store record |> Result.map_error Owner.error_to_string in
      let+ request=Request.restore ~owner:index.owner original in original,request) in
    let* ()=io (fun () -> Lineage.confirm_predecessor ~store ~require_confirmed:true request) in
    let* frontier=io (fun () ->
      Keeper_librarian_durable_commit.validate ~store ~request ~record:original) in
    match Progress.phase original.progress,frontier with
    | Progress.Finished _,Keeper_librarian_durable_commit.Settled -> Ok (Some (original,request))
    | Conflicted _,Settled ->
      (match Progress.replacement original.progress with
       | Some (Preparation_confirmed next) -> descend (id::seen) next.request_id
       | None | Some (Preparation_pending _) -> Ok None)
    | (Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
      | Finished _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _),
      (Keeper_librarian_durable_commit.Unfinished | Settled) -> Ok None in
  descend [] child_id
let retain_completion ~config ~keeper_name ~store intent =
  match intent.Intent.phase with
  | Child_confirmed child ->
    let* completed=find_completed ~config ~keeper_name ~store ~child_id:child.request_id |> unavailable in
    (match completed with None -> Ok () | Some (completed,request) ->
      io (fun () -> Intent.observe_memory_commit ~store ~expected:intent ~request ~completed) |> Result.map (fun _ -> ()))
  | Requested | Refused _ | Fenced | Child_intended _ -> Ok ()
let rec process ~config ~keeper_name ~store intent = match intent.Intent.phase with
  | Refused _ -> Ok ()
  | Requested ->
    let* stored=io (fun () -> Resolution.read ~config ~keeper_name ~request_id:intent.original_request_id)
      |> Result.map_error (fun error -> Intent.Unavailable (Resolution.error_to_string error)) in
    let observed=match stored with Some fence -> Ok fence | None ->
      io (fun () -> Resolution.fence_serialized ~config ~keeper_name ~request_id:intent.original_request_id
        ~expected:intent.expected ~actor:intent.actor ~reason:intent.reason ~now:(Time_compat.now ())) in
    (match observed with
     | Ok fence | Error (Resolution.Already_fenced fence) ->
       let* ()=fence_matches intent fence |> unavailable in
       let* next=io (fun () -> Intent.confirm_fence ~store ~expected:intent fence) in
       process ~config ~keeper_name ~store next
     | Error Resolution.Observation_changed ->
       io (fun () -> Intent.refuse ~store ~expected:intent Intent.Observation_changed) |> Result.map (fun _ -> ())
     | Error ((Original_absent | Ineligible _ | Range_already_recorded) as error) ->
       io (fun () -> Intent.refuse ~store ~expected:intent (Intent.No_longer_eligible (Resolution.error_to_string error)))
       |> Result.map (fun _ -> ())
     | Error (Unavailable detail) -> Error (Intent.Unavailable detail)
     | Error (Publication_uncertain detail) -> Error (Intent.Publication_uncertain detail))
  | Fenced ->
    let* next=prepare_child ~config ~keeper_name ~store intent in
    process ~config ~keeper_name ~store next
  | Child_intended _ -> recover_child ~config ~keeper_name ~store intent
  | Child_confirmed _ ->
    let* ()=recover_child ~config ~keeper_name ~store intent in
    retain_completion ~config ~keeper_name ~store intent
let run_serialized ~config ~keeper_name =
  try
    let store=Store.of_config config in
    let* intents=io (fun () -> Intent.active_for_keeper ~config ~keeper_name) in
    List.fold_left (fun result intent -> let* ()=result in
      process ~config ~keeper_name ~store intent) (Ok ()) intents
  with Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Error (Intent.Publication_uncertain (Printexc.to_string exn))
let record_completed_serialized ~config ~keeper_name ~request ~completed =
  let store=Store.of_config config in
  let* intents=io (fun () -> Intent.active_for_keeper ~config ~keeper_name) in
  (* Climbs by the records and their indexes; the lineage confirmed just
     before the climb already bound every link. *)
  let rec belongs seen root ~id ~owner ~predecessor =
    if id=root then Ok true else
    let* ()=require (not (List.mem id seen)) "Resolution completion ancestry contains a cycle" in
    match predecessor with
    | None -> Ok false
    | Some (predecessor:Request.predecessor) ->
      let* parent=load_record ~store ~scope:(Request.scope owner) ~request_id:predecessor.request_id
        ~absent:"Resolution completion predecessor disappeared" in
      let* (index:Request.index)=Request.index_of_summary parent in
      belongs (id::seen) root ~id:predecessor.request_id ~owner:index.owner ~predecessor:index.predecessor in
  List.fold_left (fun result intent -> let* ()=result in
    match intent.Intent.phase with
    | Child_confirmed child ->
      let* applies=io (fun () ->
        let* ()=Lineage.confirm_predecessor ~store ~require_confirmed:true request in
        belongs [] child.request_id ~id:(Request.request_id request)
          ~owner:(Request.physical_owner request) ~predecessor:(Request.predecessor request)) |> unavailable in
      if not applies then Ok () else
        io (fun () -> Intent.observe_memory_commit ~store ~expected:intent ~request ~completed) |> Result.map (fun _ -> ())
    | Requested | Refused _ | Fenced | Child_intended _ -> Ok ()) (Ok ()) intents
let range_summary ~store ~request_id =
  let* scope=Request.scope_of_request_id request_id in
  let* parent=Owner.load ~store ~scope ~request_id |> Result.map_error Owner.error_to_string in
  let* parent=Option.to_result ~none:"Original history payload is absent" parent in
  let* owner=match parent.request with
    | `Assoc fields -> let* owner=Option.to_result ~none:"Original history owner is absent" (List.assoc_opt "owner" fields) in
      Request.owner_of_json owner
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Error "Original history payload is invalid" in
  let* request=Request.restore_payload ~owner parent in
  let source=Request.source request in
  let atom=Option.map (fun (range:Current.durable_range_id) ->
    {trace_id=range.trace_id;history_start_boundary_line=range.history_start_boundary_line;
      start_atom=range.start_atom;end_atom=range.end_atom}) (Source.range_id source) in
  let official=Option.map (fun (range:Current.official_range_id) ->
    {after_boundary_line=range.after_boundary_line;selected_count=List.length range.turns;
      selected_through=List.fold_left (fun last (line,_) -> max last line) range.after_boundary_line range.turns})
    (Source.official_range_id source) in
  Ok {atom;official}
let read ~config ~keeper_name ~request_id =
  try
    let* intents=Intent.read ~config ~keeper_name ~request_id in
    let* fence=Resolution.read ~config ~keeper_name ~request_id
      |> Result.map_error (fun error -> Intent.Unavailable (Resolution.error_to_string error)) in
    let completion=match List.rev intents with
      | ({Intent.memory_commit=Some proof;_} as intent)::_ ->
        (match fence with
         | Some fence when Result.is_ok (fence_matches intent fence) -> Memory_committed {request_id=proof.request_id}
         | None | Some _ -> Completion_unavailable "Stored completion has no matching immutable fence")
      | [] | {memory_commit=None;_}::_ -> Not_observed in
    let original_range=range_summary ~store:(Store.of_config config) ~request_id in
    Ok {intents;fence;completion;original_range}
  with Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Error (Intent.Unavailable (Printexc.to_string exn))
