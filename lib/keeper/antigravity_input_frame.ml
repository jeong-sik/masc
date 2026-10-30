(* Antigravity 입력의 틀 (구현). 계약: antigravity_input_frame.mli *)

let label key =
  match String.trim (Prompt_registry.get_prompt key) with
  | "" -> Error ("missing required Antigravity prompt: " ^ key)
  | prompt -> Ok (prompt ^ "\n")
;;

let system_instructions_label () =
  label Prompt_names.keeper_antigravity_system_instructions_label
;;

let current_goal_label () = label Prompt_names.keeper_antigravity_current_goal_label
let section_separator = "\n\n"
