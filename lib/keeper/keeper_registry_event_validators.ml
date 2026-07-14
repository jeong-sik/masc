(** Event-dispatch transition validators.

    Extracted from keeper_registry.ml as part of the godfile decomp
    campaign. Two side-effect wrappers shared by RFC-0002 Event
    Dispatch and RFC-0072 Phase 6 (compaction matrix). Pure on top of
    [Keeper_registry_types] resolvers / state machine helpers — no
    registry state read or written.

    Companion to [Keeper_registry_fsm_validators] (runtime /
    turn_phase) which carries the GADT-resolver wrappers. *)

open Keeper_registry_types

let paired_lifecycle_origin origin event =
  if origin_allows_paired_lifecycle_event origin event
  then Ok ()
  else
    Error
      (Keeper_state_machine.Precondition_violation
         { event = Keeper_state_machine.event_to_string event
         ; reason =
             Printf.sprintf
               "paired lifecycle event requires origin=post_turn_lifecycle%s; got %s"
               (match event with
                | Keeper_state_machine.Compaction_started
                | Keeper_state_machine.Compaction_completed
                | Keeper_state_machine.Compaction_failed _ -> " or origin=operator_compact"
                | _ -> "")
               (lifecycle_event_origin_to_string origin)
         })
;;

(* RFC-0072 Phase 6: the 3×3 compaction matrix dispatched as an exhaustive
   match — valid pairs (incl. idempotent self-loops) return [()], forbidden
   pairs raise the typed [Compaction_transition_violation]
   (replacing the prior bare [assert], whose [Assert_failure] carried no
   labels).  Still wrapped in [Keeper_fsm_guard_runtime.wrap_unit] so
   [metric_fsm_guard_violation] (action=compaction_transition, stage=guard)
   fires on a forbidden pair; the match stays exhaustive so adding a
   [compaction_stage] variant triggers Warning 8 here.  No
   [Compaction_transition] GADT / [resolve_*] helper: with 3 states and a
   single consumer the resolver indirection would be premature. *)
let compaction_transition ~from ~to_ =
  Keeper_fsm_guard_runtime.wrap_unit
    ~action:"compaction_transition"
    ~stage:"guard"
    (fun () ->
       match from, to_ with
       (* Idempotent self-loops + valid cross-state transitions (6). *)
       | Packed Compaction_accumulating, Packed Compaction_accumulating
       | Packed Compaction_accumulating, Packed Compaction_compacting
       (* via set_compaction_stage *)
       | Packed Compaction_compacting, Packed Compaction_accumulating
       (* via set_compaction_stage: retry after a failed compaction *)
       | Packed Compaction_compacting, Packed Compaction_compacting
       | Packed Compaction_compacting, Packed Compaction_done
       (* via set_compaction_stage *)
       | Packed Compaction_done, Packed Compaction_done
       (* fresh compaction cycle after a completed prior cycle *)
       | Packed Compaction_done, Packed Compaction_compacting -> ()
       (* Forbidden transitions. *)
       | Packed Compaction_accumulating, Packed Compaction_done ->
         raise_compaction_transition_violation
           ~where:"validate_compaction_transition"
           ~from
           ~to_
           ~violation:Accumulating_to_done
       | Packed Compaction_done, Packed Compaction_accumulating ->
         raise_compaction_transition_violation
           ~where:"validate_compaction_transition"
           ~from
           ~to_
           ~violation:Done_to_accumulating)
;;
