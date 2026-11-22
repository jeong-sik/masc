module Digest = Agent_core.Checkpoint_objects
module Exact = Agent_core.Exact_output
module Read_result = Librarian_read_result
module Room_result = Librarian_room_result
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

type room_input =
  { place : Librarian_machine.place
  ; tail : unit -> Librarian_log.line option
  ; lane : Librarian_memory_lane.t
  ; resolved : Runtime_exact_output_registry.resolved_lane
  ; asked : Room_result.asked
  }

(* An ask that ends before its walk does: with a result of its own, or with a
   failure whose text goes to the log. *)
type 'result ended =
  | Ended of 'result
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

(* What ends an ask whose snapshot is not the one the tail names, in the
   result type of the question asked. *)
type 'result unread_memory =
  { diverged : expected:Digest.digest -> observed:Digest.digest -> 'result
  ; fault : Librarian_snapshot_fault.t -> 'result
  }

let read_unread : Read_result.t unread_memory =
  { diverged = (fun ~expected ~observed -> Memory_diverged { expected; observed })
  ; fault = (fun fault -> Snapshot_fault fault)
  }
;;

let room_unread : Room_result.t unread_memory =
  { diverged = (fun ~expected ~observed -> Room_memory_diverged { expected; observed })
  ; fault = (fun fault -> Room_snapshot_fault fault)
  }
;;

(* The file is read as the store reads it before a commit: a file the store
   does not open ends the ask with its fault, and the writer stops for it as
   the store does. The digest is of the bytes the file holds and is compared
   before they are decoded, so bytes other than the ones the tail names
   diverged, as they do for a commit. *)
let memory_of_bytes unread tail = function
  | Error fault -> Error (Ended (unread.fault fault))
  | Ok bytes ->
    let expected = Librarian_log.snapshot_after tail in
    let observed = Digest.digest_of_bytes bytes in
    if not (same_digest expected observed)
    then Error (Ended (unread.diverged ~expected ~observed))
    else (
      match Librarian_store.decode_snapshot bytes with
      | Some memory -> Ok (tail, memory)
      | None -> Error (Ended (unread.fault Not_a_snapshot_file)))
;;

let snapshot_path (place : Librarian_machine.place) =
  Keeper_memory_os_current_layout.path_for_keepers_dir
    ~keepers_dir:place.memory_dir
    ~keeper_id:place.keeper_id
;;

(* The tail is read on both sides of the bytes. A direct write that commits
   in between changes it, and the bytes are read again under the new line:
   they were never another snapshot than the log names. *)
let rec read_memory unread ~tail ~snapshot_path =
  match tail () with
  | None -> Error not_open
  | Some line ->
    let read = Librarian_store.read_snapshot_bytes snapshot_path in
    (match tail () with
     | None -> Error not_open
     | Some again when not (same_line line again) -> read_memory unread ~tail ~snapshot_path
     | Some (_ : Librarian_log.line) -> memory_of_bytes unread line read)
;;

(* --- The units and the question (§7.1 step 3) --- *)

(* Where reading stopped, when no unit before it holds an item. *)
let nothing_before : Librarian_unread.stop -> Read_result.t = function
  | Log_end | Limit_reached -> Nothing_to_ask
  | Unannounced_reset { line; past_line; before; after } ->
    Span_unknown
      { before; reach = { line; within = Whole; covered = after; turn_log_offset = past_line } }
  | Unreadable_line
      { offset
      ; past_line = (_ : int)
      ; from = (_ : Keeper_turn_log.mark)
      ; sha = (_ : Digest.digest)
      ; reason = (_ : Librarian_unread.unreadable)
      } -> Input_fault (Line_unreadable { offset })
;;

(* The units from the tail, when one holds an item (§7.6). *)
let read_units (input : input) ~(width : Librarian_width.width) tail =
  let turns_path =
    Keeper_turn_log_store.path_for_keepers_dir
      ~keepers_dir:input.place.turns_dir
      ~keeper_id:input.place.keeper_id
  in
  match Librarian_question_units.units ~turns_path ~width tail with
  | Ok range -> Ok range
  | Error (No_head stop) -> Error (Ended (nothing_before stop))
  | Error (Turn_log_fault fault) -> Error (Ended (Read_result.Input_fault fault))
  | Error (Turn_log_unread { detail }) -> Error (Failed (Read_failed, "turn log: " ^ detail))
;;

let read_range (input : input) ~width range =
  match Librarian_question_units.contents input.stores ~width range with
  | Ok contents -> Ok contents
  | Error (Content_unreadable { span }) ->
    Error (Ended (Read_result.Input_fault (Content_unreadable { line = span.line })))
  | Error (Content_unread { detail }) -> Error (Failed (Read_failed, "unit content: " ^ detail))
;;

(* --- The walk (§7.1 steps 4 to 6) --- *)

(* The flow's callbacks all answer [Ok ()]: the ask keeps nothing before a
   dispatch or an advance. So a callback failure has no value. *)
type no_callback_error = |

let proceed (_ : 'a) : (unit, no_callback_error) result = Ok ()
let no_callback_error_text : no_callback_error -> string = function _ -> .

let validate_http ~asked success
  : (Librarian_answer.t, Librarian_answer.rejection) Exact.semantic_verdict
  =
  match Librarian_answer.of_json ~asked (Exact.flow_success_output success).output with
  | Ok answer -> Accept answer
  | Error rejection -> Reject_and_advance rejection
;;

(* What the walk left at one slot it passed, read as every exact lane reads
   it ({!Exact_lane_slot_visit.of_passed}). A flow that ended on masc's own
   failure is no visit: the cases {!Exact.flow_execution_terminal_kind} calls
   [Non_advanceable_terminal] end the ask as a stopped walk does. *)
let slot_visit
  (passed :
    ( Exact_lane_slots.t
      , (Librarian_answer.rejection, no_callback_error) Exact_lane_slots.failure )
      Exact_lane_walk.passed)
  : (Librarian_answer.rejection Exact_lane_slot_visit.slot_visit, 'result ended) result
  =
  match Exact_lane_slot_visit.of_passed passed with
  | Ok visit -> Ok visit
  | Error stopped ->
    Error
      (Failed
         ( Flow_stopped
         , Exact.flow_execution_error_to_string
             ~callback_error_to_string:no_callback_error_text
             ~raw_response_to_string:Exact.raw_response_sha256_to_string
             stopped ))
;;

let rec slot_visits ~http ~cli = function
  | [] -> Ok (List.rev http, List.rev cli)
  | passed :: rest ->
    let* visit = slot_visit passed in
    (match visit with
     | Exact_lane_slot_visit.Http_visit seen -> slot_visits ~http:(seen :: http) ~cli rest
     | Exact_lane_slot_visit.Cli_visit seen -> slot_visits ~http ~cli:(seen :: cli) rest)
;;

let stop_detail : (Librarian_answer.rejection, no_callback_error) Exact_lane_slots.stop -> string =
  function
  | Exact_lane_slots.Http_unstartable { slot_id; reason } -> slot_id ^ ": " ^ reason
  | Exact_lane_slots.Http_stopped
      { slot_id; error = Exact.Flow_execution_terminal { cause; prior_rejections = _ } } ->
    slot_id
    ^ ": "
    ^ Exact.flow_execution_error_to_string
        ~callback_error_to_string:no_callback_error_text
        ~raw_response_to_string:Exact.raw_response_sha256_to_string
        cause
  | Exact_lane_slots.Http_stopped
      { slot_id; error = Exact.Flow_semantic_candidates_exhausted { rejections = _; evidence = _ } }
    -> slot_id ^ ": every answer was rejected"
  | Exact_lane_slots.Record_failed _ -> .
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

type lane_walked =
  | Lane_answered of
      { slot : string
      ; answer : Librarian_answer.t
      }
  | Lane_unanswered of (Lane.slot_key * Librarian_slot_outcome.unanswered) list

(* One walk over the lane's slots, HTTP and CLI alike
   (RFC exact-lane-walks-one-slot-list). Every slot is asked to match the
   schema of the question's kind. *)
let walk_lane env ~(lane : Lane.t) ~resolved ~known ~schema ~asked text =
  let requirement = Exact.make_output_requirement ~schema ~minimum_guarantee:Json_syntax in
  let resolved = to_call lane ~known resolved in
  match
    Exact_lane_slots.walk
      ~net:env.net
      ~clock:env.clock
      ~base_dir:env.base_dir
      ~admission_class:(Standalone_lane.admission_class Librarian_memory)
      ~messages:[ Llm_provider.Types.user_msg text ]
      ~requirement
      ~cli_request:(Some { Exact_lane_slots.system_prompt = ""; prompt = text })
      ~before_measurement_dispatch:proceed
      ~on_measurement_terminal:proceed
      ~before_dispatch:proceed
      ~validate_http:(validate_http ~asked)
      ~validate_cli:(Librarian_answer.of_json ~asked)
      ~before_cli_visit:(fun ~runtime_id:_ -> proceed ())
      ~on_advance:(fun ~failed:_ ~next:_ -> proceed ())
      (Exact_lane_slots.of_resolved_lane resolved)
  with
  | Exact_lane_walk.Answered
      { slot = _; value = Exact_lane_slots.Http_answered { slot_id; success }; passed = _ } ->
    Ok (Lane_answered { slot = slot_id; answer = success.accepted })
  | Exact_lane_walk.Answered
      { slot = _; value = Exact_lane_slots.Cli_answered { runtime_id; accepted }; passed = _ } ->
    Ok (Lane_answered { slot = runtime_id; answer = accepted })
  | Exact_lane_walk.Exhausted { passed; standing = _ } ->
    let* http, cli = slot_visits ~http:[] ~cli:[] passed in
    Ok (Lane_unanswered (outcomes lane ~known ~http ~cli))
  | Exact_lane_walk.Stopped { slot = _; stop; passed = _ } ->
    Error (Failed (Flow_stopped, stop_detail stop))
;;

let walk env (input : input) ~which ~schema (question : Read_result.question) text =
  let known = Librarian_bottom.known input.bottom which question.id in
  let* walked =
    walk_lane env ~lane:input.lane ~resolved:input.resolved ~known ~schema ~asked:question.id text
  in
  match walked with
  | Lane_answered { slot; answer } -> Ok (Read_result.Answered { question; answer; slot })
  | Lane_unanswered slots -> Ok (Read_result.No_answer { question; slots })
;;

let ask env (input : input) =
  let* tail, memory =
    read_memory read_unread ~tail:input.tail ~snapshot_path:(snapshot_path input.place)
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
  let* ({ units; reach; trace; offered } : Librarian_question_units.contents) =
    read_range input ~width range
  in
  let world_index =
    match shows with
    | Librarian_question.With_memory _ ->
      World_memory.read_index_snapshot_for_librarian ~base_path:input.stores.base_path
    | Librarian_question.Item_alone -> None
  in
  match
    Librarian_question.make ?world_index ~lane:input.lane.question ~from:tail ~shows ~reach ~trace
      ~offered units
  with
  | Nothing_readable { reach; missing } ->
    Ok (Read_result.Nothing_readable { reach; missing; offered })
  | Made { question; text; schema } -> walk env input ~which ~schema question text
;;

(* §7.4 「자리 내기」: Memory under the tail, then one walk. No turn log is
   read, and the bottom's facts are not about this question: every slot is
   called. *)
let ask_room env (input : room_input) =
  let* tail, memory =
    read_memory room_unread ~tail:input.tail ~snapshot_path:(snapshot_path input.place)
  in
  let world_index =
    World_memory.read_index_snapshot_for_librarian ~base_path:env.base_dir
  in
  let room =
    Librarian_question.make_room
      ?world_index
      ?molt_trigger:input.asked.molt_trigger
      ?category_filter:input.asked.category_filter
      ~lane:input.lane.question
      ~from:tail
      ~memory
      ~trace:input.asked.trace
      ()
  in
  let* walked =
    walk_lane env ~lane:input.lane ~resolved:input.resolved ~known:[] ~schema:room.schema
      ~asked:room.question.id room.text
  in
  match walked with
  | Lane_answered { slot; answer } ->
    Ok (Room_result.Room_answered { question = room.question; answer; slot })
  | Lane_unanswered slots -> Ok (Room_result.Room_not_answered { question = room.question; slots })
;;

let failed_kind : Read_result.failed -> string = function
  | Raised -> "raised"
  | Flow_stopped -> "flow_stopped"
  | Read_failed -> "read_failed"
;;

(* The failure's text goes to the structured log; the result carries its
   kind. *)
let finished ~(place : Librarian_machine.place) ~what ~failed asked =
  let failed failure detail =
    Log.Keeper.warn
      ~keeper_name:place.keeper_id
      "librarian %s failed (%s): %s"
      what
      (failed_kind failure)
      detail;
    failed failure
  in
  match asked () with
  | Ok result | Error (Ended result) -> result
  | Error (Failed (failure, detail)) -> failed failure detail
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    (* Out of memory, a stack overflow or an aggregate that holds a
       cancellation goes on up as it is. *)
    Llm_provider.Reserved_exn.reraise_if_reserved exn;
    failed Raised (Printexc.to_string exn)
;;

let run env (input : input) =
  finished ~place:input.place ~what:"ask"
    ~failed:(fun failure -> Read_result.Ask_failed failure)
    (fun () -> ask env input)
;;

let run_room env (input : room_input) =
  finished ~place:input.place ~what:"make room"
    ~failed:(fun failure -> Room_result.Room_failed failure)
    (fun () -> ask_room env input)
;;
