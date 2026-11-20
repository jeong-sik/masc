(** Local editing keymap and viewport-input admission for Keeper message mode.
    Network submission and asynchronous refresh callbacks are injected so the
    input path never owns a blocking effect. *)

val keeper_message_input_supported
  :  terminal_size:(unit -> int * int)
  -> Masc_tui_types.state
  -> bool

val handle_message_key
  :  terminal_size:(unit -> int * int)
  -> wheel_notch_rows:int
  -> Masc_tui_types.state
  -> submit_message:(Masc_tui_message_input.snapshot -> unit)
  -> load_older:(cursor:string option -> unit)
  -> paste_image:(unit -> unit)
  -> open_named_image:(unit -> unit)
  -> inspect_context:(unit -> unit)
  -> inspect_queue:(unit -> unit)
  -> load_tool_changes:(unit -> unit)
  -> load_preparation:(unit -> unit)
  -> drain_queue:(unit -> unit)
  -> start_voice:(unit -> unit)
  -> toggle_voice_continuous:(unit -> unit)
  -> string
  -> bool
