(** Private affine executor for an ordered exact-output flow.

    The public contract is exposed only through {!Exact_output}. This module is
    generic so it can own orchestration without depending back on the facade
    types that wrap the private exact plan and execution modules. *)

type t
type ('admission, 'attempt, 'measurement, 'advance) progress

type ('admission, 'attempt, 'measurement, 'advance) progress_snapshot =
  { candidate_visit_count : int
  ; admissions : 'admission list
  ; attempts : 'attempt list
  ; measurements : 'measurement list
  ; advances : 'advance list
  }

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

val create : unit -> t

(** Progress has exactly one writer: the invocation that wins [execute_once]'s
    affine gate. Concurrent readers may observe the honest point between a
    recorded admission and its subsequently allocated attempt. *)
val create_progress : unit -> ('admission, 'attempt, 'measurement, 'advance) progress

val record_admission
  :  ('admission, 'attempt, 'measurement, 'advance) progress
  -> 'admission
  -> unit

val record_attempt
  :  ('admission, 'attempt, 'measurement, 'advance) progress
  -> 'attempt
  -> unit

val publish_attempt
  :  ('admission, 'attempt, 'measurement, 'advance) progress
  -> same:('attempt -> 'attempt -> bool)
  -> 'attempt
  -> unit

val publish_measurement
  :  ('admission, 'attempt, 'measurement, 'advance) progress
  -> same:('measurement -> 'measurement -> bool)
  -> 'measurement
  -> unit

val record_advance
  :  ('admission, 'attempt, 'measurement, 'advance) progress
  -> 'advance
  -> unit

val progress_snapshot
  :  ('admission, 'attempt, 'measurement, 'advance) progress
  -> ('admission, 'attempt, 'measurement, 'advance) progress_snapshot

val duplicate_key
  :  equal:('key -> 'key -> bool)
  -> key:('candidate -> 'key)
  -> 'candidate list
  -> ('key * int * int) option

(** Execute one immutable, nonempty candidate snapshot in its declared order.

    Each candidate is passed to [execute] at most once. A successful transport
    result is passed exactly once to the pure [validate] callback. [Accept]
    terminates the flow; [Reject_and_advance] records opaque evidence and moves
    directly to the predetermined successor without invoking [before_advance].
    [before_advance] remains reserved for OAS-classified execution failures.

    The outer attempt is affine. A duplicate or concurrent invocation returns
    [Attempt_already_started]. Any exception, including Eio cancellation,
    terminalizes the outer attempt before the exception is re-raised. *)
val execute_once
  :  t
  -> candidates:'candidate list
  -> execute:('candidate -> ('success, 'execution_error) result)
  -> validate:
       ('candidate -> 'success -> ('accepted, 'semantic_rejection) semantic_verdict)
  -> advanceable:('execution_error -> 'advanceable_error option)
  -> before_advance:
       (failed:'candidate
        -> failure:'advanceable_error
        -> next:'candidate
        -> (unit, 'callback_error) result)
  -> ( 'candidate
       , 'accepted
       , 'execution_error
       , 'advanceable_error
       , 'semantic_rejection
       , 'callback_error )
       outcome
