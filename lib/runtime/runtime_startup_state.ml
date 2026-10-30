type reason =
  | Config_missing
  | Config_unreadable of { detail : string }
  | Config_invalid of { detail : string }
type t = Not_initialized | Available | Setup_required of reason
let state = Atomic.make Not_initialized
let get () = Atomic.get state
let changed = Eio.Condition.create ()
let set value = Atomic.set state value; Eio.Condition.broadcast changed
let note_runtime_loaded () = match get () with
  | Setup_required _ -> ()
  | Not_initialized | Available -> set Available
let await_available () =
  Eio.Condition.loop_no_mutex changed (fun () -> match get () with
    | Available -> Some () | Not_initialized | Setup_required _ -> None)
let requires_setup () = match get () with Setup_required _ -> true | Not_initialized | Available -> false
let message = function
  | Config_missing -> "Model setup required: runtime configuration is missing. Open connection settings, configure a model, and resume model setup."
  | Config_unreadable { detail } -> "Model setup required: runtime configuration could not be read. Check workspace configuration access and resume model setup. Cause: " ^ detail
  | Config_invalid { detail } -> "Model setup required: runtime configuration has no valid initialized runtime. Review connection settings and resume model setup. Cause: " ^ detail
let to_json () =
  let status, reason, detail = match get () with
    | Not_initialized -> "not_initialized", `Null, `Null
    | Available -> "available", `Null, `Null
    | Setup_required reason -> "setup_required",
        `String (match reason with Config_missing -> "config_missing" | Config_unreadable _ -> "config_unreadable" | Config_invalid _ -> "config_invalid"),
        `String (message reason)
  in
  `Assoc ["status", `String status; "reason", reason; "message", detail]
