module Digest = Agent_core.Checkpoint_objects
module Exact = Agent_core.Exact_output
module Backpressure = Runtime_exact_lane_backpressure
module Oneshot = Keeper_lane_cli_oneshot
module Read_result = Librarian_read_result
module Visit = Librarian_slot_visit
module Lane = Librarian_memory_lane
module Registry = Runtime_exact_output_registry

type env =
  { net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  ; clock : float Eio.Time.clock_ty Eio.Resource.t
  ; base_dir : string
  }

type input =
  { place : Librarian_machine.place
  ; stores : Librarian_unit_content.stores
  ; tail : unit -> Librarian_log.line option
  ; lane : Librarian_memory_lane.t
  ; resolved : Runtime_exact_output_registry.resolved_lane
  ; asked : Read_result.asked
  ; bottom : Librarian_bottom.t
  }

(* An ask that ends before its walk does: with a result of its own, or with a
   failure whose text goes to the log. *)
type ended =
  | Ended of Read_result.t
  | Failed of Read_result.failed * string

let ( let* ) = Result.bind

(* --- Memory under one tail (§7.1 steps 1 and 2) --- *)

let same_digest (a : Digest.digest) (b : Digest.digest) = String.equal (a :> string) (b :> string)

(* Two reads of the tail give one line when the codec writes them alike. The
   store compares the lines it appends through the codec too. *)
let same_line a b =
  Yojson.Safe.equal (Librarian_log_codec.to_json a) (Librarian_log_codec.to_json b)
;;

let not_open = Failed (Flow_stopped, "the writer is no longer open")

(* The file is read as the store reads it before a commit: a file the store
   does not open ends the ask with its fault, and the writer stops for it as
   the store does. The digest is of the bytes the file holds and is compared
   before they are decoded, so bytes other than the ones the tail names
   diverged, as they do for a commit. *)
let memory_of_bytes tail = function
  | Error fault -> Error (Ended (Snapshot_fault fault))
  | Ok bytes ->
    let expected = Librarian_log.snapshot_after tail in
    let observed = Digest.digest_of_bytes bytes in
    if not (same_digest expected observed)
    then Error (Ended (Memory_diverged { expected; observed }))
    else (
      match Librarian_store.decode_snapshot bytes with
      | Some memory -> Ok (tail, memory)
      | None -> Error (Ended (Snapshot_fault Not_a_snapshot_file)))
;;

(* The tail is read on both sides of the bytes. A direct write that commits
   in between changes it, and the bytes are read again under the new line:
   they were never another snapshot than the log names. *)
let rec read_memory input ~snapshot_path =
  match input.tail () with
  | None -> Error not_open
  | Some tail ->
    let read = Librarian_store.read_snapshot_bytes snapshot_path in
    (match input.tail () with
     | None -> Error not_open
     | Some again when not (same_line tail again) -> read_memory input ~snapshot_path
     | Some (_ : Librarian_log.line) -> memory_of_bytes tail read)
;;

(* --- The units and the question (§7.1 step 3) --- *)

(* Where reading stopped, when no unit before it holds an item. *)
let nothing_before : Librarian_unread.stop -> Read_result.t = function
  | Log_end | Limit_reached -> Nothing_to_ask
  | Unannounced_reset { line; past_line; before; after } ->
    Span_unknown
      { before; reach = { line; within = Whole; covered = after; turn_log_offset = past_line } }
  | Unreadable_line { offset; reason = (_ : Librarian_unread.unreadable) } ->
    Input_fault (Line_unreadable { offset })
;;

(* The units read, split at the first that holds items: the head (§7.6). *)
type range =
  { before : Librarian_unread.span list (** Units with no items, before the head. *)
  ; head : Librarian_unread.span
  ; after : Librarian_unread.span list
  }

let rec head_of before = function
  | [] -> None
  | span :: rest ->
    if Librarian_unread.has_items span
    then Some { before = List.rev before; head = span; after = rest }
    else head_of (span :: before) rest
;;

(* The units from the tail, when one holds an item. A width of units stops
   after that many units with items, and a width of items after the first.
   Reading that stopped at a line it cannot pass asks about the units before
   that line. *)
let read_units input ~(width : Librarian_width.width) tail =
  let turns_path =
    Keeper_turn_log_store.path_for_keepers_dir
      ~keepers_dir:input.place.turns_dir
      ~keeper_id:input.place.keeper_id
  in
  let until : Librarian_unread.until =
    match width with
    | All -> To_end
    | Units count -> First_with_items (count :> int)
    | Items (_ : Librarian_width.count) -> First_with_items 1
  in
  match Librarian_unread.read ~turns_path ~until tail with
  | Error (Fault fault) -> Error (Ended (Input_fault fault))
  | Error (Unread { detail }) -> Error (Failed (Read_failed, "turn log: " ^ detail))
  | Ok { spans; stop; bytes = (_ : int) } ->
    (match head_of [] spans with
     | Some range -> Ok range
     | None -> Error (Ended (nothing_before stop)))
;;

let read_content input span ~take =
  match Librarian_unit_content.read input.stores span ~take with
  | Ok content -> Ok (span, content)
  | Error (Fault fault) -> Error (Ended (Input_fault fault))
  | Error (Unread { detail }) -> Error (Failed (Read_failed, "unit content: " ^ detail))
;;

let rec read_whole input reads = function
  | [] -> Ok (List.rev reads)
  | span :: rest ->
    let* read = read_content input span ~take:Rest_of_unit in
    read_whole input (read :: reads) rest
;;

let item_count ({ kind; _ } : Librarian_read_unit.t) =
  match kind with
  | Turn { unattributed; own; _ } -> List.length unattributed + List.length own
  | Reset { items; _ } -> List.length items
;;

(* What one question is made of. *)
type contents =
  { units : Librarian_read_unit.t list
  ; reach : Read_result.reach
  ; trace : string (** The last unit's trace. *)
  ; offered : Librarian_width.offered
  }

(* Only the head is cut by a width of items; every other unit is read to its
   end. The reach is where the last unit's read ended. *)
let read_range input ~(width : Librarian_width.width) { before; head; after } =
  let head_take : Librarian_unit_content.take =
    match width with
    | Items count -> First_items count
    | All | Units (_ : Librarian_width.count) -> Rest_of_unit
  in
  let* before = read_whole input [] before in
  let* head_read = read_content input head ~take:head_take in
  let* after = read_whole input [] after in
  let (last : Librarian_unread.span), (ended : Librarian_unit_content.read) =
    match List.rev after with
    | last :: (_ : (Librarian_unread.span * Librarian_unit_content.read) list) -> last
    | [] -> head_read
  in
  let with_items =
    List.filter
      (fun ((span : Librarian_unread.span), (_ : Librarian_unit_content.read)) -> Librarian_unread.has_items span)
      after
  in
  let offered : Librarian_width.offered =
    { units = 1 + List.length with_items; head_items = item_count (snd head_read).unit }
  in
  let reads = before @ (head_read :: after) in
  Ok
    { units = List.map (fun ((_ : Librarian_unread.span), (read : Librarian_unit_content.read)) -> read.unit) reads
    ; reach = Librarian_unread.reach last ended.ends
    ; trace = last.through.trace
    ; offered
    }
;;

(* --- The walk (§7.1 steps 4 to 6) --- *)

(* The flow's callbacks all answer [Ok ()]: the ask keeps nothing before a
   dispatch or an advance. So a callback failure has no value. *)
type no_callback_error = |

let proceed (_ : 'a) : (unit, no_callback_error) result = Ok ()
let no_callback_error_text : no_callback_error -> string = function _ -> .

type 'visit walked =
  | Walk_answered of
      { slot : string
      ; answer : Librarian_answer.t
      }
  | Walk_unanswered of (string * 'visit) list (* Each slot visited, by its id. *)

let candidate_id (visit : Exact.flow_candidate_visit) = visit.identity.candidate_id

let passed rejection : string * Visit.http =
  ( (Exact.candidate_rejection_identity rejection).candidate_id
  , Rejected_before_dispatch (Exact.candidate_rejection_disposition rejection) )
;;

let advanced (receipt : Exact.flow_advance_receipt) : string * Visit.http =
  match receipt.failed with
  | Flow_advance_candidate_rejected rejection -> passed rejection
  | Flow_advance_execution_failed { candidate; cause; raw_response_sha256 = (_ : string option) } ->
    candidate_id candidate.visit, Execution_failed cause
;;

let answer_rejected (receipt : Librarian_answer.rejection Exact.semantic_rejection_receipt)
  : string * Visit.http
  =
  ( candidate_id (Exact.flow_success_candidate receipt.transport_success).visit
  , Answer_rejected receipt.rejection )
;;

(* The slot a flow ended on when it ran out of slots, or why it stopped on
   masc's side: the cases {!Exact.flow_execution_terminal_kind} calls
   [Non_advanceable_terminal]. *)
let last_visit
  : no_callback_error Exact.flow_execution_error
  -> ((string * Visit.http) * Exact.flow_evidence, ended) result
  = function
  | Flow_candidates_exhausted { rejection; evidence } -> Ok (passed rejection, evidence)
  | Flow_exact_execution_failed { candidate; cause; evidence } ->
    Ok ((candidate_id candidate.visit, Execution_failed cause.cause), evidence)
  | (Flow_attempt_already_started _ | Flow_attempt_start_failed _ | Flow_measurement_start_failed _)
    as stopped ->
    Error
      (Failed
         ( Flow_stopped
         , Exact.flow_execution_error_to_string
             ~callback_error_to_string:no_callback_error_text
             ~raw_response_to_string:Exact.raw_response_sha256_to_string
             stopped ))
  | Flow_before_measurement_dispatch_callback_failed { cause = _; _ }
  | Flow_measurement_terminal_callback_failed { cause = _; _ }
  | Flow_before_dispatch_callback_failed { cause = _; _ }
  | Flow_before_advance_callback_failed { cause = _; _ } -> .
;;

let flow_candidate (slot : Runtime_exact_output_registry.selected_slot) =
  match Exact.make_flow_candidate ~id:slot.slot_id ~admitted_target:slot.admitted_target with
  | Ok candidate -> Ok candidate
  | Error Blank_flow_candidate_id -> Error (Failed (Flow_stopped, "a slot has a blank id"))
;;

let rec flow_candidates = function
  | [] -> Ok []
  | slot :: rest ->
    let* candidate = flow_candidate slot in
    let* rest = flow_candidates rest in
    Ok (candidate :: rest)
;;

(* The question's text goes as one user message with no system prompt. The
   flow writes the requirement's schema sentence after it. *)
let start_flow ~requirement ~text first rest =
  let* first = flow_candidate first in
  let* rest = flow_candidates rest in
  let* snapshot =
    match
      Exact.snapshot_flow ~first ~rest ~messages:[ Llm_provider.Types.user_msg text ] requirement
    with
    | Ok snapshot -> Ok snapshot
    | Error (Duplicate_flow_candidate_id { candidate_id; _ }) ->
      Error (Failed (Flow_stopped, "a slot is named twice: " ^ candidate_id))
  in
  match
    Exact.start_flow ~admission_class:(Standalone_lane.admission_class Librarian_memory) snapshot
  with
  | Ok attempt -> Ok attempt
  | Error (Flow_id_generation_failed detail) -> Error (Failed (Flow_stopped, detail))
;;

let walk_http env ~resolved ~asked ~requirement ~text =
  let ordered = Backpressure.order_at ~now:(Eio.Time.now env.clock) resolved in
  let held =
    List.map (fun (slot : Backpressure.held_slot) -> slot.slot_id, Visit.Held) ordered.held_http
  in
  match ordered.lane.selected_slots with
  | [] -> Ok (Walk_unanswered held)
  | first :: rest ->
    let* attempt = start_flow ~requirement ~text first rest in
    let validate success : (Librarian_answer.t, Librarian_answer.rejection) Exact.semantic_verdict =
      match Librarian_answer.of_json ~asked (Exact.flow_success_output success).output with
      | Ok answer -> Accept answer
      | Error rejection -> Reject_and_advance rejection
    in
    let flow =
      Exact.execute_flow_once
        ~net:env.net
        ~clock:env.clock
        ~before_measurement_dispatch:proceed
        ~on_measurement_terminal:proceed
        ~before_dispatch:proceed
        ~before_advance:(fun ~failed:_ ~next:_ -> proceed ())
        ~validate
        attempt
    in
    Backpressure.observe ~resolved:ordered.lane flow;
    (match flow with
     | Ok { accepted; transport_success; prior_rejections = _ } ->
       Ok
         (Walk_answered
            { slot = candidate_id (Exact.flow_success_candidate transport_success).visit
            ; answer = accepted
            })
     | Error
         (Flow_semantic_candidates_exhausted
            { rejections = { first = first_rejection; rest = later_rejections }; evidence }) ->
       Ok
         (Walk_unanswered
            (held
             @ List.map advanced evidence.advances
             @ List.map answer_rejected (first_rejection :: later_rejections)))
     | Error (Flow_execution_terminal { cause; prior_rejections }) ->
       let* last, evidence = last_visit cause in
       Ok
         (Walk_unanswered
            (held
             @ List.map advanced evidence.advances
             @ List.map answer_rejected prior_rejections
             @ [ last ])))
;;

(* Each CLI slot is run and its JSON read here: [Keeper_lane_cli_oneshot.walk]
   would fold a rejection into text. The order is read again before each
   slot; a held slot is set aside where a read finds it and is not called, as
   that walk does. *)
let walk_cli env ~cli_slots ~asked ~requirement ~text =
  let rec walk visits slots =
    let { Runtime_candidate_standing.walk = callable; held } =
      Oneshot.order_slots_at ~now:(Eio.Time.now env.clock) slots
    in
    let visits =
      List.fold_left
        (fun visits (runtime_id, until) ->
           (runtime_id, Visit.Cli_failed (Oneshot.Held { runtime_id; until })) :: visits)
        visits
        held
    in
    match callable with
    | [] -> Walk_unanswered visits
    | runtime_id :: rest ->
      (match
         Oneshot.run
           ~base_dir:env.base_dir
           ~runtime_id
           ~system_prompt:""
           ~requirement
           ~prompt:text
           ()
       with
       | Error failure -> walk ((runtime_id, Visit.Cli_failed failure) :: visits) rest
       | Ok json ->
         (match Librarian_answer.of_json ~asked json with
          | Ok answer -> Walk_answered { slot = runtime_id; answer }
          | Error rejection -> walk ((runtime_id, Visit.Cli_answer_rejected rejection) :: visits) rest))
  in
  walk [] cli_slots
;;

let fact_of known (key : Lane.slot_key) =
  List.find_map
    (fun (held, fact) -> if Lane.equal_slot_key held key then Some fact else None)
    known
;;

(* One outcome for every slot of the lane value, in its order. A slot with a
   size fact under this question was not called, and its fact is its
   outcome. Any other is found among the visits by its id; one the walk did
   not reach has none. *)
let outcomes (lane : Lane.t) ~known ~http ~cli =
  let outcome visits visit (key : Lane.slot_key) =
    match fact_of known key with
    | Some fact -> key, Librarian_slot_outcome.Refused (Sized fact)
    | None ->
      let found =
        List.find_map (fun (id, seen) -> if String.equal id key.id then Some seen else None) visits
      in
      ( key
      , Visit.classify_unanswered
          (match found with
           | Some seen -> visit seen
           | None -> Visit.Not_visited) )
  in
  List.map (outcome http (fun seen -> Visit.Http seen)) lane.http
  @ List.map (outcome cli (fun seen -> Visit.Cli seen)) lane.cli
;;

(* §7.4 「묻기는 bottom 을 받는다」: the slots with a size fact under the
   question's id are left out of the walk, HTTP and CLI alike. With none
   left, nothing is called and the facts are the result. *)
let to_call (lane : Lane.t) ~known (resolved : Registry.resolved_lane) : Registry.resolved_lane =
  let unknown keys =
    List.filter_map
      (fun (key : Lane.slot_key) -> if Option.is_some (fact_of known key) then None else Some key.id)
      keys
  in
  let http = unknown lane.http in
  let cli = unknown lane.cli in
  { selected_slots =
      List.filter
        (fun (slot : Registry.selected_slot) -> List.exists (String.equal slot.slot_id) http)
        resolved.selected_slots
  ; cli_slots = List.filter (fun id -> List.exists (String.equal id) cli) resolved.cli_slots
  }
;;

(* HTTP first, CLI only when no HTTP slot answered. *)
let walk env input ~which (question : Read_result.question) text =
  let requirement =
    Exact.make_output_requirement
      ~schema:input.lane.question.answer_schema
      ~minimum_guarantee:Json_syntax
  in
  let known = Librarian_bottom.known input.bottom which question.id in
  let resolved = to_call input.lane ~known input.resolved in
  let asked = question.id in
  let answered slot answer : Read_result.t = Answered { question; answer; slot } in
  let* http = walk_http env ~resolved ~asked ~requirement ~text in
  match http with
  | Walk_answered { slot; answer } -> Ok (answered slot answer)
  | Walk_unanswered http ->
    (match walk_cli env ~cli_slots:resolved.cli_slots ~asked ~requirement ~text with
     | Walk_answered { slot; answer } -> Ok (answered slot answer)
     | Walk_unanswered cli ->
       Ok (Read_result.No_answer { question; slots = outcomes input.lane ~known ~http ~cli }))
;;

let ask env input =
  let* tail, memory =
    read_memory
      input
      ~snapshot_path:
        (Keeper_memory_os_current_layout.path_for_keepers_dir
           ~keepers_dir:input.place.memory_dir
           ~keeper_id:input.place.keeper_id)
  in
  (* The item alone is read as the head item is at the narrowest width, and
     the snapshot is still read under the tail: the question is made against
     it whether or not it shows it. *)
  let width, shows, which =
    match input.asked with
    | Read_range width -> width, Librarian_question.With_memory memory, Librarian_bottom.With_memory
    | Read_item_alone -> Librarian_width.head_item, Librarian_question.Item_alone, Librarian_bottom.Alone
  in
  let* range = read_units input ~width tail in
  let* { units; reach; trace; offered } = read_range input ~width range in
  match
    Librarian_question.make ~lane:input.lane.question ~from:tail ~shows ~reach ~trace ~offered units
  with
  | Nothing_readable { reach; missing } ->
    Ok (Read_result.Nothing_readable { reach; missing; offered })
  | Made { question; text } -> walk env input ~which question text
;;

let failed_kind : Read_result.failed -> string = function
  | Raised -> "raised"
  | Flow_stopped -> "flow_stopped"
  | Read_failed -> "read_failed"
;;

let run env input =
  let failed failure detail : Read_result.t =
    Log.Keeper.warn
      ~keeper_name:input.place.keeper_id
      "librarian ask failed (%s): %s"
      (failed_kind failure)
      detail;
    Ask_failed failure
  in
  match ask env input with
  | Ok result | Error (Ended result) -> result
  | Error (Failed (failure, detail)) -> failed failure detail
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    (* Out of memory, a stack overflow or an aggregate that holds a
       cancellation goes on up as it is. *)
    Llm_provider.Reserved_exn.reraise_if_reserved exn;
    failed Raised (Printexc.to_string exn)
;;
