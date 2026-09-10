type reason = Config_missing | Config_unreadable | Config_invalid
type t = Not_initialized | Available | Setup_required of reason
let state = Atomic.make Not_initialized
let get () = Atomic.get state
let set value = Atomic.set state value
let requires_setup () = match get () with Setup_required _ -> true | Not_initialized | Available -> false
let message = function
  | Config_missing -> "Model setup required: runtime configuration is missing. Open connection settings, configure a model, and restart the server."
  | Config_unreadable -> "Model setup required: runtime configuration could not be read. Check workspace configuration access and restart the server."
  | Config_invalid -> "Model setup required: runtime configuration has no valid initialized runtime. Review connection settings and restart the server."
let to_json () =
  let status, reason, detail = match get () with
    | Not_initialized -> "not_initialized", `Null, `Null
    | Available -> "available", `Null, `Null
    | Setup_required reason -> "setup_required",
        `String (match reason with Config_missing -> "config_missing" | Config_unreadable -> "config_unreadable" | Config_invalid -> "config_invalid"),
        `String (message reason)
  in
  `Assoc ["status", `String status; "reason", reason; "message", detail]
