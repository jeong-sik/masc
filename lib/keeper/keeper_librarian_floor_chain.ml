module Step = Keeper_librarian_floor_step_request
module Step_owner = Keeper_librarian_floor_step_owner
module Judgment = Keeper_librarian_floor_step_judgment
module Edge = Keeper_librarian_durable_edge
module Durable = Keeper_librarian_durable_request
module Machine = Keeper_librarian_message_floor.Machine
module Plan = Keeper_librarian_memory_plan
module Unread = Keeper_librarian_unread
module Refusal = Keeper_librarian_input_refusal
module Memory_runtime = Keeper_librarian_runtime
module Owner = Lane_addon_tool_request_owner
module Exact = Lane_addon_exact
let ( let* ) = Result.bind
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
  | Pending of string
  | Stopped of {position : int; report : Memory_runtime.not_committed}

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
  | (Memory_runtime.Smaller_input_may_help | Invalid_output_blocks_descent | No_descent_evidence), _ -> None

let run ~store ~config ~reserved ~owner ~range ~input ~sources ~fresh ~unread_message =
  let keeper_name = Durable.keeper_id owner in
  let* found = Step_owner.discover ~store ~owner |> Result.map_error owner_error in
  let mine = List.filter (fun (_, (header : Step.header)) -> header.range = range) found in
  let* retained = index mine in
  (* A chain that has a step starts again from what its first step retained:
     the transaction, the facts the floor started from, and the state and unread
     messages it carried in. The caller's [fresh] names a chain's start only
     once, so a restart cannot start the same range from another Memory. *)
  let* start = match Positions.find_opt 0 retained with
    | None -> fresh ()
    | Some (record, _) ->
      let* first = Step.restore ~owner record in
      let step = Step.step first in
      Ok {transaction_id = Step.transaction_id first;
          current = step.preparation.source_input.current;
          previous_state = step.context.previous_state;
          unread_messages = step.context.unread_messages} in
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
      let* () = Step.matches_question question step in
      let* () = require (Step.previous step = previous)
        "Floor chain step names another step before it than the one the chain answered" in
      let* () = require (Step.transaction_id step = start.transaction_id)
        "Floor chain step belongs to another transaction" in
      Ok (record, step)
    | None ->
      Edge.with_destination ~config ~reserved (fun destination ->
        let context : Memory_runtime.durable_step_context =
          {previous_state = question.previous_state; unread_messages = question.unread_messages} in
        let* preparation = Memory_runtime.prepare_durable_step ~now:(Time_compat.now ()) ~context question.input in
        let* step = Step.create ~request_id:(Step.fresh_request_id owner) ~owner ~destination
          ~transaction_id:start.transaction_id ~range ~previous ~question ~step:preparation () in
        let* record = Step_owner.retain ~store step |> Result.map_error owner_error in
        Ok (record, step)) in
  let fresh_authority step () =
    Edge.fresh_authority ~config ~reserved ~owner ~expected:(Step.destination step) () in
  let rec go machine ~previous =
    let* next = Machine.next machine in
    match next with
    | Machine.Finished finished ->
      let* () = require (!reused = List.length mine)
        "Floor chain has steps the floor never asked about" in
      Ok (Finished finished)
    | Machine.Ask question ->
      let* record, step = step_for question ~previous in
      let* outcome = Step_owner.resume ~store ~config ~reserved ~original:record ~step
        ~call:(Edge.call ~config ~reserved) |> Result.map_error owner_error in
      (match outcome with
       | Step_owner.Pending (wait, _) ->
         Ok (Pending (Printf.sprintf "Floor step %d is waiting on its worker (%s)" question.position
           (match wait with
            | Capacity -> "capacity" | Worker_pending -> "pending" | Worker_unknown -> "outcome unknown"
            | Worker_unreachable -> "unreachable" | Missing_after_dispatch -> "missing after dispatch"
            | Journal_recheck -> "journal recheck")))
       | Step_owner.Refused (final, record) ->
         let detail = Printf.sprintf "Floor step %d was refused: %s" question.position
           (Yojson.Safe.to_string (Exact.final_to_json final)) in
         let report = match io (fun () -> Step.refusal_evidence ~store step final) with
           | Ok evidence -> Memory_runtime.not_committed_of_failure ~detail evidence
           | Error why ->
             Memory_runtime.not_committed_of_failure ~detail:(detail ^ "; reading less could not be judged: " ^ why)
               Keeper_exact_walk_failure.empty in
         (match question.sources, hole_reasons report with
          | [source], Some reasons ->
            let* hole = unread_message source ~reasons in
            let* machine = Machine.unreadable machine ~reasons ~hole in
            go machine ~previous:(Some (link_of record))
          | [], _ | _ :: _ :: _, _ | [_], None -> Ok (Stopped {position = question.position; report}))
       | Step_owner.Answered (answer, record) ->
         let* judged = Judgment.judge ~store ~step ~record ~answer ~fresh_authority:(fresh_authority step) in
         (match judged with
          | Judgment.Pending detail -> Ok (Pending detail)
          | Judgment.Decided decision ->
            let* machine = Machine.answered machine decision in
            go machine ~previous:(Some (link_of record)))) in
  go machine ~previous:None
