module Types = Typesafeai_types
module Candidates = Keeper_memory_recall_candidates
module Codec = Keeper_memory_recall_jev_codec
module J = Keeper_memory_recall_judgment
module Ids = Set.Make (String)

type attempt_failure =
  | Capacity_refused
  | Rate_limited
  | Invalid_response
  | Failed

type evaluate = Codec.request -> (Types.eval_response, attempt_failure) result

type judged =
  { status : J.status
  ; results : J.candidate_result list
  ; turn : J.turn_answer
  ; marks : (string * J.time_mark) list
  }

(* What came of question (b). Only a request the server took shows that the
   purpose alone fits, and a response that does not decode was still taken. *)
type turn_outcome =
  | Turn_taken of J.turn_answer
  | Turn_capacity_refused
  | Turn_not_taken

(* One request of question (a) and the candidates it covered. *)
type segment =
  | Answered_piece of { piece : Candidates.piece; results : J.candidate_result list }
  | Unanswered_piece of J.candidate_result list

let turn_answer_of = function
  | Turn_taken answer -> answer
  | Turn_capacity_refused | Turn_not_taken -> J.Turn_question_failed

let ask_turn ~evaluate request =
  match evaluate request with
  | Ok response -> Turn_taken (Codec.turn_answer (Codec.decode_turn response))
  | Error Invalid_response -> Turn_taken J.Turn_question_failed
  | Error Capacity_refused -> Turn_capacity_refused
  | Error (Rate_limited | Failed) -> Turn_not_taken

let undecided piece reason =
  List.map (fun candidate -> J.Undecided { id = Candidates.id candidate; reason })
    (Candidates.piece_candidates piece)

(* A piece of two or more candidates has line bytes above zero, so half of them
   fits no piece in one go: the cut gives at least two pieces, each with fewer
   candidates. A piece of one candidate is never cut. *)
let halves piece =
  Candidates.split ~piece_bytes:(Candidates.piece_line_bytes piece / 2)
    (Candidates.piece_candidates piece)

(* [List.concat_map] without the question of which element goes first. *)
let in_order f items =
  List.rev (List.fold_left (fun done_rev item -> List.rev_append (f item) done_rev) [] items)

let stopped turn_done =
  match Eio.Promise.peek turn_done with
  | Some Turn_capacity_refused -> true
  | Some (Turn_taken _ | Turn_not_taken) | None -> false

(* The server refused a request holding only this candidate. If it took
   question (b), the purpose fits and the candidate is what is too large. If it
   refused (b) for size, the purpose is what is too large. If (b) failed some
   other way, nothing is known and the candidate is left as refused for size. *)
let reason_for_a_lone_candidate turn_done =
  match Eio.Promise.await turn_done with
  | Turn_taken _ -> J.Too_large
  | Turn_capacity_refused | Turn_not_taken -> J.Capacity

let impossible detail = invalid_arg ("Keeper_memory_recall_flow: " ^ detail)

(* A request built after [run] has checked its inputs cannot fail to build:
   the options are constants and the ids are some of the ids that were
   checked. An error here is a bug in this module. *)
let built = function
  | Ok request -> request
  | Error (Codec.Duplicate_candidate_id id) -> impossible ("duplicate candidate " ^ id)
  | Error (Codec.Choice_set_invalid detail) -> impossible detail

let rec resolve ~evaluate ~purpose ~turn_done ~request piece =
  match evaluate request with
  | Ok response ->
    [ Answered_piece
        { piece
        ; results =
            List.map (fun (id, answer) -> Codec.candidate_result ~id answer)
              (Codec.decode_candidates piece response)
        }
    ]
  | Error Rate_limited -> [ Unanswered_piece (undecided piece J.Rate_limited) ]
  | Error Invalid_response -> [ Unanswered_piece (undecided piece J.Invalid_answer) ]
  | Error Failed -> [ Unanswered_piece (undecided piece J.Provider_failed) ]
  | Error Capacity_refused ->
    (match Candidates.piece_candidates piece with
     | [] -> impossible "a piece without candidates"
     | [ _ ] ->
       [ Unanswered_piece (undecided piece (reason_for_a_lone_candidate turn_done)) ]
     | _ :: _ :: _ -> in_order (resolve_half ~evaluate ~purpose ~turn_done) (halves piece))

and resolve_half ~evaluate ~purpose ~turn_done piece =
  if stopped turn_done then [ Unanswered_piece (undecided piece J.Capacity) ]
  else
    resolve ~evaluate ~purpose ~turn_done
      ~request:(built (Codec.candidate_request ~purpose piece))
      piece

let segment_results = function
  | Answered_piece { piece = _; results } -> results
  | Unanswered_piece results -> results

let carried_ids results =
  List.filter_map
    (function
      | J.Decided { id; decision = J.Possibly_needed } -> Some id
      | J.Decided { id = _; decision = J.Not_needed } | J.Undecided { id = _; reason = _ } -> None)
    results

(* The carried candidates of each request the server answered, as pieces of
   their own. They are some of the candidates of that request, so their line
   bytes fit its piece and the cut gives one piece. *)
let carried_pieces segments =
  List.concat_map
    (function
      | Unanswered_piece _ -> []
      | Answered_piece { piece; results } ->
        let carried = carried_ids results in
        Candidates.split ~piece_bytes:(Candidates.piece_line_bytes piece)
          (List.filter (fun candidate -> List.mem (Candidates.id candidate) carried)
             (Candidates.piece_candidates piece)))
    segments

let ask_time ~evaluate piece =
  match evaluate (built (Codec.time_request piece)) with
  | Ok response ->
    List.map (fun (id, answer) -> id, Codec.time_mark answer) (Codec.decode_time piece response)
  | Error (Capacity_refused | Rate_limited | Invalid_response | Failed) ->
    List.map (fun candidate -> Candidates.id candidate, J.Time_unjudged)
      (Candidates.piece_candidates piece)

let ask_times ~evaluate segments =
  List.concat (Eio.Fiber.List.map (ask_time ~evaluate) (carried_pieces segments))

(* Question (b) runs in a fiber of the switch and the requests of (a) in its
   body. An exception on either side cancels the other, and a request of (a)
   that waits for (b) does not wait forever when (b) raises. *)
let judge ~evaluate ~purpose ~initial ~turn_request =
  let turn_done, resolve_turn = Eio.Promise.create () in
  let segments =
    Eio.Switch.run @@ fun sw ->
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Promise.resolve resolve_turn (ask_turn ~evaluate turn_request));
    List.concat
      (Eio.Fiber.List.map
         (fun (piece, request) -> resolve ~evaluate ~purpose ~turn_done ~request piece)
         initial)
  in
  let results = List.concat_map segment_results segments in
  let turn = turn_answer_of (Eio.Promise.await turn_done) in
  let marks = ask_times ~evaluate segments in
  match J.reduce ~candidates:results ~turn with
  | Some status -> { status; results; turn; marks }
  | None -> impossible "no result for a non-empty candidate list"

let first_duplicate candidates =
  let rec go seen = function
    | [] -> None
    | candidate :: rest ->
      let id = Candidates.id candidate in
      if Ids.mem id seen then Some id else go (Ids.add id seen) rest
  in
  go Ids.empty candidates

let build_initial ~purpose pieces =
  let rec go built_rev = function
    | [] -> Ok (List.rev built_rev)
    | piece :: rest ->
      (match Codec.candidate_request ~purpose piece with
       | Ok request -> go ((piece, request) :: built_rev) rest
       | Error error -> Error error)
  in
  go [] pieces

let run ~evaluate ~purpose ?(piece_bytes = Candidates.state_bytes_per_piece) candidates =
  let ( let* ) = Result.bind in
  match first_duplicate candidates with
  | Some id -> Error (Codec.Duplicate_candidate_id id)
  | None ->
    (match Candidates.split ~piece_bytes candidates with
     | [] -> Ok None
     | first :: _ as pieces ->
       let* initial = build_initial ~purpose pieces in
       let* turn_request = Codec.turn_request ~purpose in
       (* Question (c) is built later from some of these candidates. Its options
          are checked here so that nothing is sent when they cannot be built. *)
       let* _time_request = Codec.time_request first in
       Ok (Some (judge ~evaluate ~purpose ~initial ~turn_request)))
