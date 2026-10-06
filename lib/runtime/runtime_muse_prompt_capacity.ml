(* Host facts measured on Muse Code 1.4.0; see the .mli for how. *)
let host_bytes_per_estimated_token = 4
let host_fixed_overhead_tokens = 11_946
let host_compaction_percent = 75
let percent_whole = 100

type error =
  | No_window_declared
  | Window_below_host_overhead of { max_context : int }

let error_to_string = function
  | No_window_declared ->
    "the Muse model declares no max-context (the window the host reports)"
  | Window_below_host_overhead { max_context } ->
    Printf.sprintf
      "%d%% of the Muse model's max-context %d does not cover the host's own %d-token \
       overhead"
      host_compaction_percent
      max_context
      host_fixed_overhead_tokens
;;

(* Split before multiplying so no positive [max_context] overflows:
   [q * 100 + r] scaled is [q * 75 + r * 75 / 100]. *)
let compaction_line_tokens max_context =
  (max_context / percent_whole * host_compaction_percent)
  + (max_context mod percent_whole * host_compaction_percent / percent_whole)
;;

(* A window too large for [int] bytes saturates: no prompt MASC can hold in
   memory reaches that line. *)
let bytes_of_tokens tokens =
  if tokens > Int.max_int / host_bytes_per_estimated_token
  then Int.max_int
  else tokens * host_bytes_per_estimated_token
;;

let start_prompt_bytes ~max_context =
  match max_context with
  | None -> Error No_window_declared
  | Some max_context ->
    let room_tokens = compaction_line_tokens max_context - host_fixed_overhead_tokens in
    if room_tokens <= 0
    then Error (Window_below_host_overhead { max_context })
    else Ok (bytes_of_tokens room_tokens)
;;
