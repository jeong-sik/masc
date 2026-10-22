module Context = Workspace_memory_context
module Ledger = Workspace_memory_ledger
module Request = Workspace_memory_request
module Briefing = Workspace_memory_briefing
module Capture = Workspace_memory_execution_capture
module Consumer = Server_workspace_memory_addon
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Exact = Lane_addon_exact
let ( let* ) = Result.bind
let io work=Eio_unix.run_in_systhread work
let consumer value=Result.map_error Consumer.error_to_string value
let id (original : Consumer.original)=original.record.request_id
let phase (original : Consumer.original)=Progress.phase original.record.progress
type kind = Classification | Synthesis
let kind (original : Consumer.original)=match Capture.work original.capture with
  | Capture.Classification _ -> Classification | Capture.Briefing _ -> Synthesis
let active = function
  | Progress.Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _ -> true
  | Finished _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false
let leaves originals=List.filter (fun original -> match phase original with
  | Progress.Subdividing _ | Subdivided _ -> false
  | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
  | Finished _ | Conflicted _ | Rejected _ -> true) originals
let size_refusal (original : Consumer.original)=match phase original with
  | Progress.Rejected {stage=Progress.Execution;evidence} ->
    let* final=Exact.final_of_json ~schema:(Capture.output_schema original.capture) evidence in
    (match final with
     | Exact.Call_final (Exact.Input_refused (Exact.Input_capacity | Context_overflow | Request_body_refused)) -> Ok true
     | Exact.Call_final (Exact.Output_limit_reached _) ->
       (match Capture.work original.capture with Capture.Classification _ -> Ok true | Capture.Briefing _ -> Ok false)
     | Exact.Call_final (Exact.Answered _ | Invalid_output _ | Input_refused Invalid_request)
     | Exact.Outcome_unknown | Not_allowed _ | Request_id_reused -> Ok false)
  | Progress.Rejected {stage=Progress.Before_dispatch;_}
  | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
  | Finished _ | Conflicted _ | Subdividing _ | Subdivided _ -> Ok false
let divisible (original : Consumer.original)=match Capture.work original.capture with
  | Capture.Classification {batch;_} -> (match batch.selected with _::_::_ -> true | [] | [_] -> false)
  | Capture.Briefing batch -> Briefing.selected_count batch > 1
let changed original record=phase original <> Progress.phase record.Owner.progress
let narrow ~config original =
  let* result=Consumer.narrow ~config ~request_id:(id original) |> consumer in
  match result with
  | Consumer.Successor_ready _ -> Ok true
  | Indivisible record | Successor_waiting record -> Ok (changed original record)
let step ~config original =
  let* result=Consumer.resume ~config ~request_id:(id original) |> consumer in
  match result with
  | Consumer.Judgment _ | Commit_pending _ ->
    let* settled=Consumer.settle ~config ~request_id:(id original) |> consumer in
    (match settled with
     | Consumer.Committed record | Commit_conflict record | Commit_waiting record -> Ok (changed original record))
  | Consumer.Awaiting (_,record) | Settled record -> Ok (changed original record)
  | Consumer.Terminal (_,record) ->
    let* fresh=Consumer.discover ~config |> consumer in
    let* current=match List.find_opt (fun current -> id current=id original) fresh with
      | Some current -> Ok current | None -> Error "Original Curator terminal vanished before successor evaluation" in
    let* eligible=size_refusal current in
    if eligible && divisible current then narrow ~config current else Ok (changed original record)
let observe ~config ~on_observation_failure originals =
  List.fold_left (fun complete original ->
    match Consumer.deliver_observation ~config ~request_id:(id original) with
    | Ok _ -> complete
    | Error error ->
      on_observation_failure ();
      Log.Server.error "workspace curator original observation %s: %s" (id original) (Consumer.error_to_string error);
      false) true originals
let one_active originals=match List.filter (fun original -> active (phase original)) originals with
  | [] -> Ok None | [original] -> Ok (Some original)
  | _::_::_ -> Error "Multiple active Curator originals have no unique domain frontier"
let one_successor ~config originals =
  let rec collect acc = function
    | [] -> (match acc with [] -> Ok None | [original] -> Ok (Some original)
        | _::_::_ -> Error "Multiple original size refusals have no unique successor frontier")
    | original::rest ->
      let* size=size_refusal original in
      let* current=if size && divisible original then
        Consumer.successor_is_current ~config ~capture:original.capture |> consumer
        else Ok false in
      collect (if current then original::acc else acc) rest in
  collect [] originals
let classification_blocked originals (fact:Ledger.pending_fact) =
  List.exists (fun (original : Consumer.original) -> match Capture.work original.capture with
    | Capture.Briefing _ -> false
    | Capture.Classification {batch;_} -> match phase original with
      | Progress.Rejected _ ->
        List.exists (fun (pending : Ledger.pending_fact) -> pending.fact=fact.Ledger.fact) batch.selected
      | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
      | Finished _ | Conflicted _ | Subdividing _ | Subdivided _ -> false) originals
let classify_new ~config ~originals ~new_work =
  let base_path=config.Workspace.base_path in
  let* context,ledger=io (fun () -> let* context=Context.collect ~base_path in
    let* ledger=Ledger.load ~base_path in Ok (context,ledger)) in
  let change=Ledger.reconcile ledger (Context.keepers context) in
  let* ()=if change.vanished=[] then Ok () else io (fun () -> Ledger.save ~base_path change.ledger) in
  (* Finished work already has a disposition in its confirmed after-state.
     Only fresh reconciliation can make that identity pending again, after
     its disposition was removed. A rejected original still fences its facts. *)
  let pending=List.filter (fun fact -> not (classification_blocked originals fact)) change.new_facts in
  if pending=[] || not new_work then Ok false else
  let resolution=Prompt_registry.resolve_prompt Prompt_names.workspace_memory_curator in
  let render input=Prompt_registry.render_resolved_prompt_template Prompt_names.workspace_memory_curator
    resolution ["workspace_memory_changes",Yojson.Safe.to_string input] in
  let* batch=io (fun () -> Request.prepare ~neighbor_limit:(max 0 (List.length (Context.keepers context)-1))
    ~render ~ledger:change.ledger ~current:change.current_facts ~pending
    |> Result.map_error Request.error_to_string) in
  match batch with
  | None -> Ok false
  | Some batch -> let* _=Consumer.capture_classification ~config ~prompt:resolution ~ledger:change.ledger ~batch |> consumer in
    Ok true
let briefing_blocked ~sources ~contract ~state originals =
  let rec loop = function
    | [] -> Ok false
    | (original : Consumer.original)::rest ->
      (match Capture.work original.capture with
       | Capture.Classification _ -> loop rest
       | Capture.Briefing batch -> match phase original with
         | Progress.Rejected _ | Finished _ ->
           let* current=Briefing.batch_is_current ~sources ~contract batch in
           if current && Yojson.Safe.equal (Briefing.to_json state) (Briefing.to_json (Briefing.prepared_state batch))
           then Ok true else loop rest
         | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
         | Conflicted _ | Subdividing _ | Subdivided _ -> loop rest) in loop originals
let briefing_new ~config ~originals ~new_work ~busy =
  let base_path=config.Workspace.base_path in
  let directory=Ledger.directory ~base_path in
  let* ledger,state=io (fun () -> let* ledger=Ledger.load ~base_path in
    let* state=Briefing.load ~directory in Ok (ledger,state)) in
  let sources=Ledger.briefing_sources ledger in
  let resolution=Prompt_registry.resolve_prompt Prompt_names.workspace_memory_briefing in
  let contract=Briefing.contract ~template:resolution.effective in
  let render input=Prompt_registry.render_resolved_prompt_template Prompt_names.workspace_memory_briefing
    resolution ["workspace_memory_briefing",Yojson.Safe.to_string input] in
  let* prepared=Briefing.prepare ~sources ~contract ~render state in
  match prepared with
  | Briefing.Unchanged -> Ok false
  | Cleanup cleaned -> let* ()=io (fun () -> Briefing.save ~directory cleaned) in Ok true
  | Prepared batch ->
    let* blocked=briefing_blocked ~sources ~contract ~state originals in
    if busy || blocked || not new_work then Ok false else
    let prepared=Briefing.prepared_state batch in
    let* ()=if Yojson.Safe.equal (Briefing.to_json state) (Briefing.to_json prepared) then Ok ()
      else io (fun () -> Briefing.save ~directory prepared) in
    let* _=Consumer.capture_briefing ~config ~prompt:resolution ~batch |> consumer in Ok true
let run_domain ~config ~on_inventory ~on_observation_failure domain =
  let* originals=Consumer.discover ~config |> consumer in
  on_inventory originals;
  let new_work=observe ~config ~on_observation_failure originals in
  let selected=leaves originals |> List.filter (fun original -> kind original=domain) in
  let* running=one_active selected in
  match running with
  | Some original ->
    let result=step ~config original in
    (match domain with
     | Classification -> result
     | Synthesis -> let* progressed=result in
       let* cleaned=briefing_new ~config ~originals:selected ~new_work:false ~busy:true in Ok (progressed || cleaned))
  | None ->
    let* successor=one_successor ~config selected in
    let prepare ~originals ~new_work=match domain with
      | Classification -> classify_new ~config ~originals ~new_work
      | Synthesis -> briefing_new ~config ~originals ~new_work ~busy:false in
    match successor with
    | None -> prepare ~originals:selected ~new_work
    | Some original ->
      match narrow ~config original with
      | Ok true -> Ok true
      | Ok false | Error _ as result ->
        (match result with Ok _ -> () | Error detail -> Log.Server.error "workspace curator successor: %s" detail);
        (* A failed publication is not absence. Rediscover before any new root;
           a recovered child is now runnable on the next pass, never alongside
           another capture derived from the previous frontier. *)
        let* fresh=Consumer.discover ~config |> consumer in
        on_inventory fresh;
        let new_work=observe ~config ~on_observation_failure fresh in
        let selected=leaves fresh |> List.filter (fun original -> kind original=domain) in
        let* running=one_active selected in
        match running with Some _ -> Ok true | None -> prepare ~originals:selected ~new_work
let run ~config ~on_inventory ~on_observation_failure =
  let classify=run_domain ~config ~on_inventory ~on_observation_failure Classification in
  let synthesize=run_domain ~config ~on_inventory ~on_observation_failure Synthesis in
  let changed=function Ok changed -> changed | Error detail ->
    Log.Server.error "workspace curator original owner: %s" detail;false in
  let classified=changed classify and synthesized=changed synthesize in
  classified || synthesized

type owner =
  { mutex : Stdlib.Mutex.t
  ; mutable pending : bool
  ; mutable in_flight : bool
  ; mutable stopped : bool
  ; mutable observation_retry : bool
  ; mutable wake : unit Eio.Promise.u option
  ; in_flight_revisions :
      (string * Keeper_memory_commit_notifications.store, int) Hashtbl.t
  }

let owners_mutex = Stdlib.Mutex.create ()
let owners : (string, owner) Hashtbl.t = Hashtbl.create 4

type refresh = Queued | No_owner | Unavailable of string

let wake owner =
  let queued, resolver = Stdlib.Mutex.protect owner.mutex (fun () ->
    if owner.stopped then false, None else (
      owner.pending <- true;
      let resolver = owner.wake in owner.wake <- None; true, resolver)) in
  Option.iter (fun resolver -> Eio.Promise.resolve resolver ()) resolver;
  if queued then Queued else No_owner

(* Keeper_memory_commit_notifications.Current.replace increments snapshot.revision
   monotonically per (keepers_dir, keeper_id, store), while recovery may
   re-dispatch the same revision. Suppress only duplicate wakes for a revision
   that is already in-flight; once in_flight clears at the end of a drain pass,
   in_flight_revisions is cleared so any subsequent commit wakes a fresh pass. *)
let wake_for_commit owner (event : Keeper_memory_commit_notifications.event) =
  let key = event.keeper_id, event.store in
  let should_wake, resolver =
    Stdlib.Mutex.protect owner.mutex (fun () ->
      if owner.stopped then false, None
      else if owner.in_flight
              && Hashtbl.find_opt owner.in_flight_revisions key = Some event.revision
      then false, None
      else (
        Hashtbl.replace owner.in_flight_revisions key event.revision;
        owner.pending <- true;
        let resolver = owner.wake in
        owner.wake <- None;
        true, resolver))
  in
  Option.iter (fun resolver -> Eio.Promise.resolve resolver ()) resolver;
  if should_wake then Queued else No_owner

let request ~base_path =
  match Unix.realpath base_path with
  | base_path ->
    let owner = Stdlib.Mutex.protect owners_mutex (fun () -> Hashtbl.find_opt owners base_path) in
    (match owner with None -> No_owner | Some owner -> wake owner)
  | exception Unix.Unix_error (error, operation, _) ->
    Unavailable (operation ^ ": " ^ Unix.error_message error)

let retry_pending_observations ~base_path =
  match Eio_guard.run_in_systhread ~label:"curator-retry-workspace" (fun () -> Unix.realpath base_path) with
  | base_path ->
  let owner=Stdlib.Mutex.protect owners_mutex (fun () -> Hashtbl.find_opt owners base_path) in
  (match owner with
  | None -> ()
  | Some owner ->
    let pending=Stdlib.Mutex.protect owner.mutex (fun () -> owner.observation_retry && not owner.stopped) in
    if pending then ignore (wake owner))
  | exception Unix.Unix_error (error,operation,_) ->
    Log.Server.warn "workspace curator retry identity %s: %s: %s" base_path operation (Unix.error_message error)

let start ~sw ~config =
  Eio.Switch.check sw;
  let base_path = Unix.realpath config.Workspace.base_path in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  (* A missing directory is an inventory failure, not an empty workspace.
     Creating it here could reconcile every durable ledger member away. *)
  let keepers_dir = try Unix.realpath keepers_dir with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> keepers_dir in
  let owner =
    { mutex = Stdlib.Mutex.create ()
    ; pending = true
    ; in_flight = false
    ; stopped = false
    ; observation_retry = false
    ; wake = None
    ; in_flight_revisions = Hashtbl.create 8
    }
  in
  let admitted = Stdlib.Mutex.protect owners_mutex (fun () ->
    if Hashtbl.mem owners base_path then false
    else (Hashtbl.add owners base_path owner; true)) in
  if admitted then (
    let routes=ref [] in
    let sync_routes originals =
      let inventory=Lane_addon_runtime.inventory ~config in
      let installed=List.filter_map (fun (item : Lane_addon_runtime.inventory_instance) ->
        if item.package_id=Capture.package_id then Option.map (fun owner -> owner.Lane_addon_runtime.id) item.configuration
        else None) inventory.instances in
      let retained=List.filter_map (fun (original : Consumer.original) ->
        match Owner.installation_of_id original.record.installation_id with
        | Ok (Owner.Configuration id) -> Some id
        | Ok (Owner.Manual _) | Error _ -> None) originals in
      let wanted=List.sort_uniq String.compare (installed @ retained)
        |> List.concat_map (fun id -> [id ^ "/classification";id ^ "/briefing"]) in
      List.iter (fun (id,stop) -> if not (List.mem id wanted) then stop ()) !routes;
      routes:=List.filter (fun (id,_) -> List.mem id wanted) !routes;
      List.iter (fun id -> if not (List.mem_assoc id !routes) then
        routes:=(id,Runtime_exact_output_registry.subscribe_lane_changes ~lane_id:id
          (fun () -> ignore (wake owner))) :: !routes) wanted in
    let unsubscribe = Keeper_memory_commit_notifications.subscribe (fun event ->
      (* fire-and-forget: wake reports admission only; notifications have no response consumer. *)
      if String.equal event.keepers_dir keepers_dir then ignore (wake_for_commit owner event)) in
    let unsubscribe_addon=Lane_addon_runtime.subscribe_owner_events ~config
      ~package_id:Server_workspace_memory_addon_validation.package_id (fun event ->
        match event with
        | Lane_addon_runtime.Export_inventory_changed | Configuration_observed | Exact_result_delivered _ ->
          ignore (wake owner)) in
    Eio.Switch.on_release sw (fun () ->
      Stdlib.Mutex.protect owner.mutex (fun () -> owner.stopped <- true; owner.wake <- None);
      List.iter (fun (_,stop) -> stop ()) !routes;
      routes:=[];
      unsubscribe ();
      unsubscribe_addon ();
      Stdlib.Mutex.protect owners_mutex (fun () -> Hashtbl.remove owners base_path));
    (* A daemon, because the switch is this owner's whole life and the loop
       parks on [owner.wake] whenever the backlog is empty. Nothing wakes it on
       the way down: the release hook below sets [stopped] and drops the
       resolver without resolving it, and release hooks run only after every
       ordinary fiber has finished. [Switch.run] joins ordinary fibers when its
       body returns a value, so as an ordinary fiber this loop would hold the
       server's shutdown open. The daemon is cancelled instead, and a review
       cancelled mid-run already records itself. *)
    Eio.Fiber.fork_daemon ~sw (fun () ->
      let rec drain () =
        let next = Stdlib.Mutex.protect owner.mutex (fun () ->
          if owner.stopped then `Stop
          else if owner.pending then (owner.pending <- false; owner.in_flight <- true; `Run)
          else let promise, resolver = Eio.Promise.create () in
            owner.wake <- Some resolver; `Wait promise) in
        match next with
        | `Stop -> ()
        | `Wait promise -> Eio.Promise.await promise; drain ()
        | `Run ->
          (* fire-and-forget: remaining facts queue another pulse; stopped owners need none. *)
          (try
             let retry=ref false in
             let progressed=run ~config ~on_inventory:sync_routes
               ~on_observation_failure:(fun () -> retry:=true) in
             Stdlib.Mutex.protect owner.mutex (fun () -> owner.observation_retry <- !retry);
             if progressed then ignore (wake owner)
           with
           | Eio.Cancel.Cancelled _ as error -> raise error
           | exn ->
             Stdlib.Mutex.protect owner.mutex (fun () -> owner.observation_retry <- true);
             Log.Server.error "workspace curator owner %s: %s" base_path (Printexc.to_string exn));
          Stdlib.Mutex.protect owner.mutex (fun () ->
            owner.in_flight <- false;
            Hashtbl.clear owner.in_flight_revisions);
          drain () in
      drain ();
      `Stop_daemon))


module For_testing = struct
  let find ~base_path =
    let base_path = Unix.realpath base_path in
    Stdlib.Mutex.protect owners_mutex (fun () -> Hashtbl.find_opt owners base_path)

  let is_idle ~base_path = match find ~base_path with
    | None -> true
    | Some owner -> Stdlib.Mutex.protect owner.mutex (fun () -> not owner.pending && not owner.in_flight)

  let stop ~base_path = Option.iter (fun owner ->
    let resolver = Stdlib.Mutex.protect owner.mutex (fun () ->
      owner.stopped <- true;
      let resolver = owner.wake in owner.wake <- None; resolver) in
    Option.iter (fun resolver -> Eio.Promise.resolve resolver ()) resolver) (find ~base_path)
end
