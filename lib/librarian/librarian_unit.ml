type range =
  { from : int
  ; until : int
  }

type missing_part =
  | Bundle of Keeper_turn_log.slice
  | History_bytes of range
  | Internal_bytes of range
  | Chat_bytes of range
  | External_rows of range
  | Undecodable_history_line of { offset : int }
  | Undecodable_internal_line of { offset : int }
  | Undecodable_external_row of { row : int }

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
