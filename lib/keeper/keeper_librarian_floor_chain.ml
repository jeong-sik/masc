module Step = Keeper_librarian_floor_step_request
module Step_owner = Keeper_librarian_floor_step_owner
module Judgment = Keeper_librarian_floor_step_judgment
module Gate = Keeper_librarian_floor_step_gate
module Edge = Keeper_librarian_durable_edge
module Durable = Keeper_librarian_durable_request
module Machine = Keeper_librarian_message_floor.Machine
module Plan = Keeper_librarian_memory_plan
module Unread = Keeper_librarian_unread
module Refusal = Keeper_librarian_input_refusal
module Memory_runtime = Keeper_librarian_runtime
module Owner = Lane_addon_tool_request_owner
module Exact = Lane_addon_exact
module Replacement = Keeper_librarian_retained_step_replacement
let ( let* ) = Result.bind
let ( let+ ) result f = Result.map f result
let io f = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ f
let require condition detail = if condition then Ok () else Error detail

type fresh = {
  transaction_id : string;
  current : Keeper_librarian.current_selection option;
  previous_state : string option;
  unread_messages : Unread.t list;
}
type outcome =
  | Finished of Machine.finished
  | Pending of Keeper_librarian_pending.t
  | Stopped of {position : int; report : Memory_runtime.not_committed}
  | Declaration_replaced of {position : int; request_id : string}
  | Superseded

module Positions = Map.Make (Int)

(* The retained steps of one chain by position. Two steps at one position are
   two answers to one question; neither is chosen. *)
let index steps =
  List.fold_left (fun found (record, (header : Step.header)) ->
    let* found = found in
    if Positions.mem header.position found
    then Error (Printf.sprintf "Floor chain has two steps at position %d" header.position)
    else Ok (Positions.add header.position (record, header) found)) (Ok Positions.empty) steps
let link_of (record : Owner.retained) : Step.link =
  {request_id = record.request_id; request_digest = record.request_digest}
let owner_error = Step_owner.error_to_string

(* Whether a refused step may become an unread hole is the one rule the history
   path uses to descend: the host's own evidence names input refusals and shows
   that reading less could help. Nothing else lets the floor read past a message. *)
let hole_reasons report =
  match report.Memory_runtime.message_descent, report.provider_input_refusals with
  | Memory_runtime.Smaller_input_may_help, (_ :: _ as reasons) -> Some reasons
  | (Memory_runtime.Smaller_input_may_help | Invalid_output_blocks_descent
    | Unsettled_native_blocks_descent | No_descent_evidence), _ -> None

type mode = Ordinary | Complete_original of {
  source : Memory_runtime.retained_step_source;
  preparation : Memory_runtime.durable_preparation;
  destination : Durable.destination;
  before_inference : Step.retained_chain_basis -> (unit,string) result;
}
type selected_step = Selected of Owner.retained * Step.t | Basis_wait of string
(* The leaf binds the installation/package/tool. Each fresh question captures
   the current semantic revision; a retained question keeps its own revision. *)
let same_owner captured current =
  match Lane_addon_captured_destination.relation ~captured ~current with
  | Same | Replaced -> true
  | Other_owner -> false
let run_with ~mode ~store ~config ~reserved ~owner ~range ~input ~sources ~fresh ~current ~unread_message =
  let keeper_name = Durable.keeper_id owner in
  let* mine=match mode with
    | Ordinary ->
      let* found=Step_owner.discover ~store ~owner |> Result.map_error owner_error in
      let selected=List.filter (fun (_, (index:Step.index)) -> index.header.range=range) found in
      let* ()=require (List.for_all (fun (_, (index:Step.index)) -> index.header.retained_source=None) selected)
        "Ordinary floor range belongs to another preparation mode" in
      List.fold_left (fun result listed ->
        let* loaded=result in
        let+ original=Step_owner.load ~store listed |> Result.map_error owner_error in
        original::loaded) (Ok []) selected |> Result.map List.rev
    | Complete_original original -> io (fun () ->
      let* selected=Replacement.read ~store ~owner ~range ~source:original.source in
      List.fold_left (fun result (record,_step) ->
        let* loaded=result in
        let+ header=Step.header ~owner record in
        (record,header)::loaded) (Ok []) (Replacement.steps selected)
      |> Result.map List.rev) in
  let* retained = index mine in
  (* The gate scope is read once for the pass, when the first answered step
     needs judging. The judgments of the steps that earlier passes finished are
     answered from that read, so the pass reads the scope once, not once per
     step, and a pass with no answered step does not read it. *)
  let gate_scope_read = ref None in
  let inventory () = match !gate_scope_read with
    | Some inventory -> Ok inventory
    | None ->
      let* inventory = io (fun () -> Gate.Inventory.read ~store ~owner) in
      gate_scope_read := Some inventory;
      Ok inventory in
  (* A chain that has a step starts again from what its first step retained:
     the transaction, the facts the floor started from, and the state and unread
     messages it carried in. The caller's [fresh] names a chain's start only
     once, so a restart cannot start the same range from another Memory. *)
  let* start, observed, basis = match Positions.find_opt 0 retained with
    | None ->
      let* ()=require (Positions.is_empty retained) "Floor chain has steps without its retained first question" in
      let* start,basis = fresh () in Ok (start, start.current,basis)
    | Some (record, _) ->
      let* first = Step.restore ~owner record in
      let step = Step.step first in
      let* () = Memory_runtime.require_counterpart_template step.preparation in
      let* observed = current () in
      Ok ({transaction_id = Step.transaction_id first;
          current = step.preparation.source_input.current;
          previous_state = step.context.previous_state;
          unread_messages = step.context.unread_messages}, observed,Step.chain_basis first) in
  let before_inference ()=match mode,basis with
    | Ordinary,None -> Ok ()
    | Complete_original original,Some basis -> original.before_inference basis
    | Ordinary,Some _ | Complete_original _,None -> Error "Floor chain lost its retained Memory/source basis" in
  let sources=match mode,basis with
    | Complete_original _,Some basis -> basis.sources
    | Ordinary,(None|Some _) | Complete_original _,None -> sources in
  let facts = Option.map (fun (selection : Keeper_librarian.current_selection) -> selection.facts) in
  let ordinary=match mode with Ordinary -> true | Complete_original _ -> false in
  let result=if ordinary && facts start.current <> facts observed then Ok Superseded else
  let* read = Machine.read ~keeper_name ~sources ~unread_messages:start.unread_messages
    ~previous_state:start.previous_state input in
  let* plan = Plan.create_over ~keeper_id:input.keeper_id ~turn_ref:input.turn_ref ~current:start.current
    |> Result.map_error Plan.error_to_string in
  let* machine = Machine.start ~transaction_id:start.transaction_id ~plan read in
  let reused = ref 0 in
  let step_for (question : Machine.question) ~previous =
    match Positions.find_opt question.position retained with
    | Some (record, _) ->
      incr reused;
      let* step = Step.restore ~owner record in
      let* ()=match mode with
        | Ordinary -> Ok ()
        | Complete_original original ->
          let* ()=require (same_owner
            original.destination (Step.destination step))
            "Retained floor step belongs to another original leaf owner" in
          Memory_runtime.validate_retained_durable_step
            ~source:original.source ~original:original.preparation (Step.step step) in
      let* () = Memory_runtime.require_counterpart_template (Step.step step).preparation in
      let* () = Step.matches_question question step in
      let* () = require (Step.previous step = previous)
        "Floor chain step names another step before it than the one the chain answered" in
      let* () = require (Step.transaction_id step = start.transaction_id)
        "Floor chain step belongs to another transaction" in
      Ok (Selected (record, step))
    | None ->
      (match before_inference () with
       | Error detail -> Ok (Basis_wait detail)
       | Ok () ->
      Edge.with_destination ~config ~reserved (fun destination ->
        let relation=match mode with
          | Ordinary -> Lane_addon_captured_destination.Same
          | Complete_original original -> Lane_addon_captured_destination.relation
              ~captured:original.destination ~current:destination in
        match relation with
        | Other_owner -> Error "Retained floor destination belongs to another original owner"
        | Lane_addon_captured_destination.Same | Replaced ->
        let context : Memory_runtime.durable_step_context =
          {previous_state = question.previous_state; unread_messages = question.unread_messages} in
        let* preparation=match mode with
          | Complete_original original -> Memory_runtime.prepare_retained_durable_step
              ~source:original.source ~original:original.preparation ~context question.input
          | Ordinary ->
            let* source_lines = io (fun () ->
              Keeper_memory_source_current.read_budget_lines ~keepers_dir:(Durable.keepers_dir owner)
                ~keeper_id:keeper_name) in
            Memory_runtime.prepare_durable_step ~now:(Time_compat.now ()) ~context ~source_lines question.input in
        let first_basis=if question.position=0 then basis else None in
        let* step = Step.create ?basis:first_basis ~request_id:(Step.fresh_request_id owner) ~owner ~destination
          ~transaction_id:start.transaction_id ~range ~previous ~question ~step:preparation () in
        let* record = Step_owner.retain ~store step |> Result.map_error owner_error in
        Ok (Selected (record, step)))) in
  let fresh_authority step () =
    let* ()=before_inference () in
    Edge.fresh_gate_authority ~config ~reserved ~owner ~expected:(Step.destination step) () in
  let replaced (question:Machine.question) (record:Owner.retained) step = match mode with
    | Ordinary -> Ok (Declaration_replaced {position=question.position;request_id=record.request_id})
    | Complete_original _ ->
      (match before_inference () with
       | Error detail -> Ok (Pending (Keeper_librarian_pending.Message_floor {request_id=range.request_id;detail}))
       | Ok () ->
         let* child_id=Replacement.resume ~store ~config ~reserved ~original:record ~step in
         Keeper_working_context_signal.changed ~base_path:(Durable.base_path owner) ~keeper_name;
         Ok (Pending (Keeper_librarian_pending.Message_floor
           {request_id=child_id;detail="The retained question replacement is durable; the next Memory unit resumes that ID"}))) in
  let rec go machine ~previous =
    let* next = Machine.next machine in
    match next with
    | Machine.Finished finished ->
      let* () = require (!reused = List.length mine)
        "Floor chain has steps the floor never asked about" in
      Ok (Finished finished)
    | Machine.Ask question ->
      let* selected = step_for question ~previous in
      (match selected with
       | Basis_wait detail -> Ok (Pending (Keeper_librarian_pending.Message_floor
           {request_id=range.request_id;detail}))
       | Selected (record,step) ->
      let* outcome = Step_owner.resume_with_admission ~before_admission:(fun () ->
        before_inference () |> Result.map_error (fun detail -> Step_owner.Unavailable detail))
        ~store ~config ~reserved ~original:record ~step
        ~call:(Edge.call ~config ~reserved) |> Result.map_error owner_error in
      (match outcome with
       | Step_owner.Pending (wait, record) ->
         Ok (Pending (Keeper_librarian_pending.Worker
           (Keeper_librarian_pending.of_worker_wait ~installation_id:record.installation_id
              ~request_id:record.request_id wait)))
       | Step_owner.Before_dispatch_replaced record ->
         replaced question record step
       | Step_owner.Refused (final, record) ->
         let* replacement=match final with
           | Exact.Not_allowed _ ->
             io (fun () ->
               let* exact=Step.request step in
               let* target=Keeper_librarian_original_final.target
                 ~installation_id:(Step.destination step).installation_id exact in
               Keeper_librarian_original_final.declaration_replaced ~store target record)
           | Call_final _ | Outcome_unknown | Request_id_reused -> Ok false in
         if replacement then replaced question record step else
         let* ()=Memory_runtime.require_counterpart_template (Step.step step).preparation in
         let detail = Printf.sprintf "Floor step %d was refused: %s" question.position
           (Yojson.Safe.to_string (Exact.final_to_json final)) in
         let report = match io (fun () -> Step.refusal_evidence ~store step final) with
           | Ok evidence -> Memory_runtime.not_committed_of_failure ~detail evidence
           | Error why ->
             Memory_runtime.not_committed_of_failure ~detail:(detail ^ "; reading less could not be judged: " ^ why)
               Keeper_exact_walk_failure.empty in
         (match mode,question.sources, hole_reasons report with
          | Complete_original _,_,_ -> Ok (Stopped {position=question.position;report})
          | Ordinary,[source], Some reasons ->
            let* hole = unread_message source ~reasons in
            let* machine = Machine.unreadable machine ~reasons ~hole in
            go machine ~previous:(Some (link_of record))
          | Ordinary,[], _ | Ordinary,_ :: _ :: _, _ | Ordinary,[_], None ->
            Ok (Stopped {position = question.position; report}))
       | Step_owner.Answered (answer, record) ->
         let* inventory = inventory () in
         let* judged = Judgment.judge ~store ~step ~record ~answer ~fresh_authority:(fresh_authority step)
           ~inventory in
         (match judged with
          | Judgment.Pending detail ->
            Ok (Pending (Keeper_librarian_pending.Message_floor
              { request_id = record.request_id; detail }))
          | Judgment.Decided decision ->
            let* machine = Machine.answered machine decision in
            go machine ~previous:(Some (link_of record))))) in
  go machine ~previous:None in
  let+ outcome=result in outcome,basis,start.transaction_id

let run ~store ~config ~reserved ~owner ~range ~input ~sources ~fresh ~current ~unread_message =
  let+ outcome,_,_=run_with ~mode:Ordinary ~store ~config ~reserved ~owner ~range ~input ~sources
    ~fresh:(fun () -> let+ start=fresh () in start,None) ~current ~unread_message in outcome

type retained_outcome = {outcome:outcome;basis:Step.retained_chain_basis;transaction_id:string}
let run_complete_original ~store ~config ~reserved ~original ~fresh ~before_inference =
  let* source_basis_digest=Durable.source_basis_digest original in
  let source : Memory_runtime.retained_step_source = {request_id=Durable.request_id original;
    request_digest=Durable.body_digest original;source_basis_digest} in
  let mode=Complete_original {source;preparation=Durable.preparation original;
    destination=Durable.destination original;before_inference} in
  let range : Step.link = {request_id=source.request_id;request_digest=source.request_digest} in
  let* outcome,basis,transaction_id=run_with ~mode ~store ~config ~reserved
    ~owner:(Durable.physical_owner original) ~range
    ~input:(Keeper_librarian_durable_capture.input (Durable.source original)) ~sources:[]
    ~fresh:(fun () -> let+ start,basis=fresh () in start,Some basis)
    ~current:(fun () -> Ok None)
    ~unread_message:(fun _ ~reasons:_ -> Error "Retained Cut source cannot become an unread hole") in
  let+ basis=Option.to_result ~none:"Retained floor omitted its original basis" basis in
  {outcome;basis;transaction_id}
