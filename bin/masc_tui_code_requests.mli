(** Code request execution. The caller owns completion delivery and reporting.
    These operations keep request admission, state capture and Eio launch order
    together; response state transitions belong to {!Masc_tui_code_results}. *)

val launch_entries_load :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_async_protocol.async_msg -> unit) -> unit
(** Capture scope and directory before launching; an already loading key is shared. *)

val launch_file_load :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_async_protocol.async_msg -> unit) -> path:string -> unit
(** Start the path request and deliver its whole-file response with its request key. *)

val launch_history_load :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_async_protocol.async_msg -> unit) -> path:string -> unit
(** Capture the workspace scope and activity address, then combine stable git and
    Keeper history with the existing durable coverage note. *)

val launch_diff_load :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_async_protocol.async_msg -> unit) ->
  base_ref:string -> path:string -> unit
(** The caller supplies the shared working-tree comparison reference. *)

val launch_blame_load :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_async_protocol.async_msg -> unit) -> path:string -> unit
(** Capture workspace axes before launching the margin read. *)

val start_lsp_question :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_async_protocol.async_msg -> unit) ->
  report:(string -> string -> unit) -> question:string -> symbol:string -> unit
(** With no open file, report the refusal. Otherwise capture the cursor and scope
    before the daemon starts. Cancellation propagates; a missing switch delivers
    the existing error response instead of blocking on the request. *)
