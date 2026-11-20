type opened =
  { runtime : string
  ; task : Keeper_turn_log.task_evidence
  ; stimuli : Keeper_turn_log.stimulus list
  }

type body =
  | Chat_row of Keeper_chat_store_line_decode.parsed_line
  | External_row of Keeper_external_attention.item
  | Message of Agent_core.Types.message
  | Fragment of
      { file : Keeper_turn_fragments.file
      ; line : Keeper_turn_fragments.line
      }

type item =
  { index : int
  ; name : Librarian_unit.item_name
  ; body : body
  }

type kind =
  | Turn of
      { turn : int
      ; outcome : Keeper_turn_log.outcome
      ; opened : opened
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
  ; missing : Librarian_unit.missing_part list
  }

let missing_at units =
  List.filter_map
    (fun ({ line; missing; _ } : t) ->
       match missing with
       | [] -> None
       | _ :: _ -> Some ({ line; parts = missing } : Librarian_unit.missing_at))
    units
;;

let first_item { kind; _ } =
  let first = function
    | [] -> None
    | (item : item) :: (_ : item list) -> Some item.name
  in
  match kind with
  | Turn { unattributed; own; _ } -> first (unattributed @ own)
  | Reset { items; _ } -> first items
;;
