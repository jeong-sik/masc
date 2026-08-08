type state =
  | Not_started
  | Running
  | Terminal

type t = state Atomic.t

type ('admission, 'attempt, 'measurement, 'advance) progress_snapshot =
  { candidate_visit_count : int
  ; admissions : 'admission list
  ; attempts : 'attempt list
  ; measurements : 'measurement list
  ; advances : 'advance list
  }

type ('admission, 'attempt, 'measurement, 'advance) progress_state =
  { candidate_visit_count : int
  ; admissions_rev : 'admission list
  ; attempts_rev : 'attempt list
  ; measurements_rev : 'measurement list
  ; advances_rev : 'advance list
  }

type ('admission, 'attempt, 'measurement, 'advance) progress =
  ('admission, 'attempt, 'measurement, 'advance) progress_state Atomic.t

type ('accepted, 'rejection) semantic_verdict =
  | Accept of 'accepted
  | Reject_and_advance of 'rejection

type ('candidate
     , 'accepted
     , 'execution_error
     , 'advanceable_error
     , 'semantic_rejection
     , 'callback_error)
     outcome =
  | Succeeded of
      { accepted : 'accepted
      ; prior_rejections : 'semantic_rejection list
      }
  | Semantic_candidates_exhausted of
      { first_rejection : 'semantic_rejection
      ; rest_rejections : 'semantic_rejection list
      }
  | Attempt_already_started
  | Before_advance_callback_failed of
      { failed_candidate : 'candidate
      ; failure : 'advanceable_error
      ; next_candidate : 'candidate
      ; cause : 'callback_error
      ; prior_rejections : 'semantic_rejection list
      }
  | Execution_failed of
      { candidate : 'candidate
      ; cause : 'execution_error
      ; prior_rejections : 'semantic_rejection list
      }

let create () = Atomic.make Not_started

let create_progress () =
  Atomic.make
    { candidate_visit_count = 0
    ; admissions_rev = []
    ; attempts_rev = []
    ; measurements_rev = []
    ; advances_rev = []
    }
;;

let record_admission progress admission =
  let current = Atomic.get progress in
  let candidate_visit_count = current.candidate_visit_count + 1 in
  Atomic.set
    progress
    { current with
      candidate_visit_count
    ; admissions_rev = admission :: current.admissions_rev
    }
;;

let record_attempt progress attempt =
  let current = Atomic.get progress in
  Atomic.set progress { current with attempts_rev = attempt :: current.attempts_rev }
;;

let rec replace_or_prepend ~same value = function
  | [] -> [ value ]
  | head :: tail when same head value -> value :: tail
  | head :: tail -> head :: replace_or_prepend ~same value tail
;;

let publish_attempt progress ~same attempt =
  let current = Atomic.get progress in
  Atomic.set
    progress
    { current with attempts_rev = replace_or_prepend ~same attempt current.attempts_rev }
;;

let publish_measurement progress ~same measurement =
  let current = Atomic.get progress in
  Atomic.set
    progress
    { current with
      measurements_rev = replace_or_prepend ~same measurement current.measurements_rev
    }
;;

let record_advance progress advance =
  let current = Atomic.get progress in
  Atomic.set progress { current with advances_rev = advance :: current.advances_rev }
;;

let progress_snapshot progress =
  let current = Atomic.get progress in
  { candidate_visit_count = current.candidate_visit_count
  ; admissions = List.rev current.admissions_rev
  ; attempts = List.rev current.attempts_rev
  ; measurements = List.rev current.measurements_rev
  ; advances = List.rev current.advances_rev
  }
;;

let duplicate_key ~equal ~key candidates =
  let rec find position seen = function
    | [] -> None
    | candidate :: rest ->
      let value = key candidate in
      (match List.find_opt (fun (seen_value, _) -> equal seen_value value) seen with
       | Some (_, first_position) -> Some (value, first_position, position)
       | None -> find (position + 1) ((value, position) :: seen) rest)
  in
  find 1 [] candidates
;;

let execute_once state ~candidates ~execute ~validate ~advanceable ~before_advance =
  if not (Atomic.compare_and_set state Not_started Running)
  then Attempt_already_started
  else
    Fun.protect
      ~finally:(fun () -> Atomic.set state Terminal)
      (fun () ->
         let rec execute_candidates prior_rejections_rev = function
           | [] -> invalid_arg "Exact_output_flow: empty candidate snapshot"
           | candidate :: rest ->
             (match execute candidate with
              | Ok success ->
                (match validate candidate success with
                 | Accept accepted ->
                   Succeeded
                     { accepted; prior_rejections = List.rev prior_rejections_rev }
                 | Reject_and_advance rejection ->
                   let prior_rejections_rev = rejection :: prior_rejections_rev in
                   (match rest with
                    | _ :: _ -> execute_candidates prior_rejections_rev rest
                    | [] ->
                      (match List.rev prior_rejections_rev with
                       | first_rejection :: rest_rejections ->
                         Semantic_candidates_exhausted
                           { first_rejection; rest_rejections }
                       | [] -> assert false)))
              | Error failure ->
                (match rest, advanceable failure with
                 | next :: _, Some advanceable_failure ->
                   (match
                      before_advance ~failed:candidate ~failure:advanceable_failure ~next
                    with
                    | Ok () -> execute_candidates prior_rejections_rev rest
                    | Error cause ->
                      Before_advance_callback_failed
                        { failed_candidate = candidate
                        ; failure = advanceable_failure
                        ; next_candidate = next
                        ; cause
                        ; prior_rejections = List.rev prior_rejections_rev
                        })
                 | [], _ | _ :: _, None ->
                   Execution_failed
                     { candidate
                     ; cause = failure
                     ; prior_rejections = List.rev prior_rejections_rev
                     }))
         in
         execute_candidates [] candidates)
;;
