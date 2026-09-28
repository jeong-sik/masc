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
    "the Muse model declares neither max-context (the window the host reports) nor \
     max-prompt-bytes"
  | Window_below_host_overhead { max_context } ->
    Printf.sprintf
      "%d%% of the Muse model's max-context %d does not cover the host's own %d-token \
       overhead"
      host_compaction_percent
      max_context
      host_fixed_overhead_tokens
;;

let start_prompt_bytes ~declared ~max_context =
  match declared, max_context with
  | Some declared, _ -> Ok declared
  | None, None -> Error No_window_declared
  | None, Some max_context ->
    let room_tokens =
      (max_context * host_compaction_percent / percent_whole) - host_fixed_overhead_tokens
    in
    if room_tokens > 0
    then Ok (room_tokens * host_bytes_per_estimated_token)
    else Error (Window_below_host_overhead { max_context })
;;
