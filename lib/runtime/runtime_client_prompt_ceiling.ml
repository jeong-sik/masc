let bytes_per_window_token = 2
let antigravity_proven_start_prompt_bytes = 2_078_915

(* A window too large for [int] bytes saturates: no prompt MASC can hold in
   memory reaches that line. *)
let window_bytes ~max_context =
  if max_context > Int.max_int / bytes_per_window_token
  then Int.max_int
  else max_context * bytes_per_window_token
;;

let antigravity_start_prompt_bytes ~max_context =
  Int.min antigravity_proven_start_prompt_bytes (window_bytes ~max_context)
;;
