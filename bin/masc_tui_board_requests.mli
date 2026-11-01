(** Board request execution. New publications retain their original outcome
    through the workspace result registry. Other operations use the caller's
    workspace-authorized launcher. *)

type 'a launch =
  deliver:(('a, string) result -> Masc_tui_async_protocol.async_msg) ->
  (unit -> ('a, string) result) -> unit

val start_board_post_refresh :
  Masc_tui_types.state -> host:string -> port:int -> post_id:string ->
  launch:(Masc_tui_types.board_post * Masc_tui_types.board_comment list * string option) launch -> unit

val start_board_post :
  Masc_tui_types.state -> host:string ->
  results:Masc_tui_async_protocol.async_msg Masc_tui_workspace_result.t ->
  admit:(Masc_tui_types.workspace_authority Masc_tui_board_publication.request ->
    (unit, string) result) ->
  report:(string -> string -> unit) -> title:string -> body:string ->
  ?hearth:string -> unit -> unit
(** Capture/register the exact request before dispatch. Publication outcomes
    are unscoped archival messages; applying them to the current workspace or
    draft remains the UI owner's separate authority check. Cancellation keeps
    the existing workspace job lifetime and publishes its phase-based outcome
    before propagation. *)

val start_board_comment :
  Masc_tui_types.state -> host:string -> launch:string launch ->
  report:(string -> string -> unit) -> post_id:string -> content:string -> unit

val start_board_vote :
  Masc_tui_types.state -> host:string -> launch:string launch ->
  report:(string -> string -> unit) -> post_id:string -> up:bool -> unit

val start_board_comment_vote :
  Masc_tui_types.state -> host:string -> launch:string launch ->
  report:(string -> string -> unit) -> post_id:string -> comment_id:string ->
  up:bool -> unit
(** Vote on one comment of [post_id]; the completion names the comment, and
    [post_id] is the reading it refreshes. *)
