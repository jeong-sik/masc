open Types

let _log = Log.create ~module_name:"agent" ()

let stop_reason_label : Types.stop_reason -> string = function
  | EndTurn -> "end_turn"
  | StopToolUse -> "stop_tool_use"
  | MaxTokens -> "max_tokens"
  | StopSequence -> "stop_sequence"
  | Refusal -> "refusal"
  | ContentFilter -> "content_filter"
  | RepetitionTruncation -> "repetition_truncation"
  | PauseTurn -> "pause_turn"
  | Compaction -> "compaction"
  | ContextWindowExceeded -> "model_context_window_exceeded"
  | UnmatchedToolCalls -> "unmatched_tool_calls"
  | Unknown s -> "unknown:" ^ s
;;

let log_turn ~run_start ~turn_start ~turn_index ~model ~stop =
  let now = Unix.gettimeofday () in
  let model_field = if String.length model = 0 then "-" else model in
  Log.info
    _log
    "turn completed"
    [ Log.I ("turn", turn_index)
    ; Log.F ("elapsed_run_sec", now -. run_start)
    ; Log.F ("turn_duration_sec", now -. turn_start)
    ; Log.S ("model", model_field)
    ; Log.S ("stop", stop)
    ]
;;

type provider_lease =
  | Held
  | Released

type provider_lease_release =
  { after : unit -> provider_lease
  ; before_tool_execution : (unit -> unit) option
  }

let plan_provider_lease_release ~yield_enabled ~on_yield = function
  | Released -> { after = (fun () -> Released); before_tool_execution = None }
  | Held when yield_enabled ->
    (match on_yield with
     | None -> { after = (fun () -> Held); before_tool_execution = None }
     | Some callback ->
       let released = ref false in
       { after = (fun () -> if !released then Released else Held)
       ; before_tool_execution =
           Some
             (fun () ->
               callback ();
               released := true)
       })
  | Held -> { after = (fun () -> Held); before_tool_execution = None }
;;

let acquire_provider_lease ~yield_enabled ~on_resume = function
  | Held -> Held
  | Released when yield_enabled ->
    Option.iter (fun callback -> callback ()) on_resume;
    Held
  | Released -> Held
;;
