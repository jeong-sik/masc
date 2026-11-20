module Digest = Agent_core.Checkpoint_objects

type within =
  | Whole
  | Item of int

type position =
  | Before_first
  | Through of
      { line : int
      ; within : within
      }

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
