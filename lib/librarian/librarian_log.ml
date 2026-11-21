module Digest = Agent_core.Checkpoint_objects

type within =
  | Whole
  | Item of Librarian_unit.item_name

type position =
  | Before_first
  | Through of
      { line : int
      ; within : within
      }

type hole =
  | Content_missing of Librarian_unit.missing_at list
  | Unknown_span of
      { before : Keeper_turn_log.mark
      ; after : Keeper_turn_log.mark
      }
  | Item_exceeds_window of Librarian_unit.missing_at list
  | Turn_log_replaced of
      { from : Keeper_turn_log.Log_id.t
      ; to_ : Keeper_turn_log.Log_id.t
      }
  | Position_lost of
      { offset : int
      ; length : int
      }
  | Line_unreadable of
      { offset : int
      ; sha : Digest.digest
      }
  | Operator_skipped of
      { by : string
      ; missing : Librarian_unit.missing_at list
      }

type shown =
  | With_memory
  | Item_alone of alone_working_state

and alone_working_state =
  | Untouched
  | Not_valid_alone

type cause =
  | Direct of
      { by : Librarian_effects.actor
      ; trace : string
      ; write : Librarian_direct.write
      }
  | Adopt of
      { by : string
      ; observed : Digest.digest
      }
  | Read of
      { question : Librarian_question_id.t
      ; shown : shown
      ; slot : string
      ; trace : string
      ; missing : Librarian_unit.missing_at list
      }
  | Make_room of
      { question : Librarian_question_id.t
      ; slot : string
      ; trace : string
      }
  | Skip of { hole : hole }

type commit =
  { seq : int
  ; at : float
  ; basis : Digest.digest
  ; after : Digest.digest
  ; revision : int
  ; cause : cause
  ; effects : Librarian_effects.t
  ; turn_log : Keeper_turn_log.Log_id.t
  ; turn_log_offset : int
  ; covers_through : position
  ; covered : Keeper_turn_log.mark
  ; working_state : string option
  }

type line =
  | Started of
      { at : float
      ; turn_log : Keeper_turn_log.Log_id.t
      ; snapshot : Digest.digest
      ; revision : int
      ; turn_log_offset : int
      ; covered : Keeper_turn_log.mark
      }
  | Committed of commit

let snapshot_after = function
  | Started { snapshot; _ } -> snapshot
  | Committed { after; _ } -> after
;;
