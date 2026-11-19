module Digest = Agent_core.Checkpoint_objects

type item_ref =
  { line : int
  ; index : int
  }

type missing_part =
  | Bundle of
      { bundle : Digest.digest
      ; first : item_ref
      ; count : int
      }
  | History_bytes of { item : item_ref }
  | Internal_bytes of { item : item_ref }
  | Chat_bytes of { item : item_ref }
  | External_rows of
      { first : item_ref
      ; count : int
      }
  | Undecodable_fragment_line of { item : item_ref }

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

type opened =
  { runtime : string
  ; task : Keeper_turn_log.task_evidence
  ; stimuli : Keeper_turn_log.stimulus list
  }

type item =
  { index : int
  ; text : string
  }

type kind =
  | Turn of
      { turn : int
      ; outcome : Keeper_turn_log.outcome
      ; opened : opened option
      ; unattributed : item list
      ; own : item list
      }
  | Reset of
      { cause : Keeper_turn_log.announced
      ; items : item list
      }

type t =
  { line : int
  ; at : float
  ; kind : kind
  ; missing : missing_part list
  }

type offered =
  { units : int
  ; head_items : int
  }
