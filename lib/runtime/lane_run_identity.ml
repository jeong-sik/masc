type t =
  | Librarian
  | Hitl_auto_judge
  | Board_attention
  | Workspace_curator
  | Verifier
  | Browser_stagehand
  | Candle_appraiser
[@@deriving enumerate]

let to_id = function
  | Librarian -> "librarian_exact"
  | Hitl_auto_judge -> "hitl_auto_judge"
  | Board_attention -> "board_attention_exact"
  | Workspace_curator -> "workspace_curator_exact"
  | Verifier -> "verifier_exact"
  | Browser_stagehand -> "browser_stagehand_exact"
  | Candle_appraiser -> "candle_appraiser"
;;

let of_id id = List.find_opt (fun lane -> String.equal (to_id lane) id) all
let equal (left : t) (right : t) = left = right

let label = function
  | Librarian -> "Librarian"
  | Hitl_auto_judge -> "HITL Auto Judge"
  | Board_attention -> "Board Attention"
  | Workspace_curator -> "Workspace Curator"
  | Verifier -> "Verifier"
  | Browser_stagehand -> "Browser Stagehand"
  | Candle_appraiser -> "Candle Appraiser"
;;
