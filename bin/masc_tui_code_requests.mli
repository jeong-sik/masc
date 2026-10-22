(** Code request execution. The caller owns dispatch-captured workspace-stamped completion delivery
    and reporting.
    These operations keep request admission, state capture and Eio launch order
    together; response state transitions belong to {!Masc_tui_code_results}. *)

(** Capture scope and directory before launching; an already loading key is shared. *)
val launch_entries_load
  :  Masc_tui_types.state
  -> host:string
  -> deliver:(Masc_tui_async_protocol.async_msg -> unit)
  -> unit

(** Start the path request and deliver its whole-file response with its request key. *)
val launch_file_finder :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_async_protocol.async_msg -> unit) -> unit

val open_found_file :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_async_protocol.async_msg -> unit) -> path:string -> unit
(** Read a selected file without replacing the original file or cursor. Only
    an admitted successful reply commits navigation through Code results. *)

val return_to_reading :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_async_protocol.async_msg -> unit) -> unit
(** Return through jump history using the destination scope and confirmed
    workspace identity, without replacing the current file while reading. *)

val launch_navigation_read :
  Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_async_protocol.async_msg -> unit) ->
  Masc_tui_types.code_navigation_owner -> string Masc_tui_fetched.request -> unit
(** Send an already-owned return/location read under its destination scope. *)

val launch_file_load
  :  ?intent:Masc_tui_types.code_file_load_intent
  -> Masc_tui_types.state
  -> host:string
  -> deliver:(Masc_tui_async_protocol.async_msg -> unit)
  -> path:string
  -> unit

(** Capture the workspace scope and activity address, then combine stable git and
    Keeper history. A failed source leaves the other source visible, with its
    failure reported in the listing. *)
val launch_history_load
  :  Masc_tui_types.state
  -> host:string
  -> deliver:(Masc_tui_async_protocol.async_msg -> unit)
  -> path:string
  -> unit

(** The caller supplies the shared working-tree comparison reference. *)
val launch_diff_load
  :  Masc_tui_types.state
  -> host:string
  -> deliver:(Masc_tui_async_protocol.async_msg -> unit)
  -> base_ref:string
  -> path:string
  -> unit

(** Capture workspace axes before launching the margin read. *)
val launch_blame_load
  :  Masc_tui_types.state
  -> host:string
  -> deliver:(Masc_tui_async_protocol.async_msg -> unit)
  -> path:string
  -> unit

(** With no open file, report the refusal. Otherwise capture the cursor and scope
    before the daemon starts; the LSP request generation travels with completion.
    Cancellation propagates; a missing switch delivers
    the existing error response instead of blocking on the request. *)
val start_lsp_question
  :  ?line:int
  -> Masc_tui_types.state
  -> host:string
  -> deliver:(Masc_tui_async_protocol.async_msg -> unit)
  -> report:(string -> string -> unit)
  -> question:string
  -> symbol:string
  -> unit

val save_draft : Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_async_protocol.async_msg -> unit) -> (unit, string) result
(** Deliver this effect acknowledgement unwrapped so navigation cannot lose the
    submitted draft's outcome. The UI still settles only its original ticket. *)

val reread_draft : Masc_tui_types.state -> host:string ->
  deliver:(Masc_tui_async_protocol.async_msg -> unit) -> (unit, string) result
(** Supersede an earlier file read and own a new comparison request after a
    conflict/uncertainty. A pre-submission GET cannot supply that comparison. *)
