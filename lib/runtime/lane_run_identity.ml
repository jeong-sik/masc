type t =
  | Librarian
  | Hitl_auto_judge
  | Board_attention
  | Workspace_curator
  | Verifier
  | Candle_appraiser
  | Librarian_memory
[@@deriving enumerate]

let to_id = function
  | Librarian -> "librarian_exact"
  | Hitl_auto_judge -> "hitl_auto_judge"
  | Board_attention -> "board_attention_exact"
  | Workspace_curator -> "workspace_curator_exact"
  | Verifier -> "verifier_exact"
  | Candle_appraiser -> "candle_appraiser"
  | Librarian_memory -> "librarian_memory"
;;

let of_id id = List.find_opt (fun lane -> String.equal (to_id lane) id) all
let equal (left : t) (right : t) = left = right

let label = function
  | Librarian -> "Librarian"
  | Hitl_auto_judge -> "HITL Auto Judge"
  | Board_attention -> "Board Attention"
  | Workspace_curator -> "Workspace Curator"
  | Verifier -> "Verifier"
  | Candle_appraiser -> "Candle Appraiser"
  | Librarian_memory -> "Librarian Memory"
;;

let keeps_run_records = function
  | Librarian
  | Hitl_auto_judge
  | Board_attention
  | Workspace_curator
  | Verifier
  | Candle_appraiser -> true
  | Librarian_memory -> false
;;
