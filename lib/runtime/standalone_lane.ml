type t =
  | Librarian
  | Hitl_auto_judge
  | Board_attention
  | Workspace_curator
  | Verifier

(* [to_id] is exhaustive and [all] is not, so the two stay adjacent.
   test_exact_lane_run_registry holds [all] against a match of its own. The
   order is the one the runtime file editor and the route error list use. *)
let all = [ Librarian; Hitl_auto_judge; Board_attention; Workspace_curator; Verifier ]

let to_id = function
  | Librarian -> "librarian_exact"
  | Hitl_auto_judge -> "hitl_auto_judge"
  | Board_attention -> "board_attention_exact"
  | Workspace_curator -> "workspace_curator_exact"
  | Verifier -> "verifier_exact"
;;

(* Read back through [to_id], so no id is spelled a second time. *)
let of_id id = List.find_opt (fun lane -> String.equal (to_id lane) id) all
