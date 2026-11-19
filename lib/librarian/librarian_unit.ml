module Digest = Agent_core.Checkpoint_objects

type missing_part =
  | Bundle of
      { bundle : Digest.digest
      ; first : int
      ; count : int
      }
  | History_bytes of
      { first : int
      ; count : int
      }
  | Internal_bytes of
      { first : int
      ; count : int
      }
  | Chat_bytes of
      { first : int
      ; count : int
      }
  | External_rows of
      { first : int
      ; count : int
      }
  | Undecodable_fragment_line of { item : int }

type missing_at =
  { line : int
  ; parts : missing_part list
  }

type input_fault =
  | Line_unreadable of { offset : int }
  | Turn_log_replaced of
      { expected : Keeper_turn_log.Log_id.t
      ; observed : Keeper_turn_log.Log_id.t option
      }
  | Position_lost of
      { offset : int
      ; length : int
      }
  | Content_unreadable of { line : int }
