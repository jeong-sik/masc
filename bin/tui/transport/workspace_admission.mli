(** Workspace identity admission, cancellation scopes, async mailbox delivery,
    and guarded request launchers for TUI producers. *)

type mailbox = {
  notifications :
    Masc_tui_async_protocol.async_msg Masc_tui_async_protocol.mailed Eio.Stream.t;
  workspace_results :
    Masc_tui_async_protocol.async_msg Masc_tui_workspace_result.t;
}

val server_peer_host : string

val enqueue : mailbox -> Masc_tui_async_protocol.async_msg -> unit

val same_server_workspace
  :  Masc.Tui_decode.server_identity
  -> Masc.Tui_decode.server_identity
  -> bool

val probe_expected_workspace
  :  host:string
  -> port:int
  -> Masc.Tui_decode.server_identity
  -> (unit, string) result

val same_workspace_identity
  :  Masc.Tui_decode.server_identity option
  -> Masc.Tui_decode.server_identity option
  -> bool

val workspace_enqueue
  :  Masc_tui_types.state
  -> mailbox
  -> Masc_tui_async_protocol.async_msg
  -> unit

val deliver_code
  :  Masc_tui_types.state
  -> mailbox
  -> Masc_tui_code_results.msg
  -> unit

val deliver_context
  :  Masc_tui_types.state
  -> mailbox
  -> Masc_tui_context_results.msg
  -> unit

val deliver_fleet
  :  Masc_tui_types.state
  -> mailbox
  -> Masc_tui_fleet_results.msg
  -> unit

val wrap_original
  :  Masc_tui_original_results.msg
  -> Masc_tui_async_protocol.async_msg

val admit_request
  :  ?schedule_form_change:Masc_tui_types.schedule_change
  -> ?refresh_ticket:Masc_tui_types.Http_refresh_order.ticket
  -> ?prior_contact:Masc_tui_server_lifecycle.contact
  -> Masc_tui_types.state
  -> mailbox:mailbox
  -> authority:Masc_tui_types.workspace_authority
  -> identity:Masc.Tui_decode.server_identity option
  -> host:string
  -> port:int
  -> unit
  -> (unit, Masc_tui_types.workspace_refusal) result

val admission_sequence
  :  Masc_tui_types.state
  -> mailbox:mailbox
  -> authority:Masc_tui_types.workspace_authority
  -> identity:Masc.Tui_decode.server_identity option
  -> host:string
  -> port:int
  -> (unit -> (unit, Masc_tui_types.workspace_refusal) result)

val capture_admission
  :  Masc_tui_types.state
  -> mailbox:mailbox
  -> (unit -> (unit, Masc_tui_types.workspace_refusal) result)

val in_request_scope
  :  kind:Masc_tui_workspace_precondition.kind
  -> Masc_tui_types.state
  -> mailbox:mailbox
  -> authority:Masc_tui_types.workspace_authority
  -> identity:Masc.Tui_decode.server_identity option
  -> host:string
  -> port:int
  -> withdrawn:(Masc_tui_types.workspace_refusal -> 'a)
  -> (unit -> 'a)
  -> 'a

val workspace_scope_refused_english : string

val fork_job
  :  ?observation:bool
  -> ?kind:Masc_tui_workspace_precondition.kind
  -> ?key:unit ref
  -> ?on_withdrawn:(unit -> unit)
  -> ?observe:(Masc_tui_workspace_job.event -> unit)
  -> Masc_tui_types.state
  -> mailbox:mailbox
  -> sw:Eio.Switch.t
  -> (unit -> unit)
  -> unit

val launch_result
  :  ?key:unit ref
  -> ?operation:bool
  -> ?observation:bool
  -> ?cancelled:Masc_tui_async_protocol.async_msg
  -> ?cancelled_by:(unit -> Masc_tui_async_protocol.async_msg)
  -> ?observe_job:(Masc_tui_workspace_job.event -> unit)
  -> ?on_not_run:(unit -> unit)
  -> ?withdrawn:(Masc_tui_types.workspace_refusal -> 'error)
  -> Masc_tui_types.state
  -> mailbox:mailbox
  -> boundary_error:(string -> 'error)
  -> deliver:(('a, 'error) result -> Masc_tui_async_protocol.async_msg)
  -> (unit -> ('a, 'error) result)
  -> unit

val launch_session
  :  Masc_tui_types.state
  -> mailbox:mailbox
  -> boundary_error:(string -> 'error)
  -> deliver:(('a, 'error) result -> Masc_tui_async_protocol.async_msg)
  -> (unit -> ('a, 'error) result)
  -> unit

val launch_observation
  :  ?key:unit ref
  -> ?observe_job:(Masc_tui_workspace_job.event -> unit)
  -> ?on_not_run:(unit -> unit)
  -> Masc_tui_types.state
  -> mailbox:mailbox
  -> boundary_error:(string -> 'error)
  -> not_started:(string -> 'error)
  -> cancelled:Masc_tui_async_protocol.async_msg
  -> progress:('part -> Masc_tui_async_protocol.async_msg)
  -> deliver:(('a, 'error) result -> Masc_tui_async_protocol.async_msg)
  -> (('part -> unit) -> ('a, 'error) result)
  -> unit

val launch_async_read
  :  ?source:Masc_tui_async_read.source
  -> ?on_not_run:(unit -> unit)
  -> Masc_tui_types.state
  -> mailbox:mailbox
  -> deliver:(('a, string) result -> unit)
  -> (unit -> ('a, string) result)
  -> unit

val launch_async_read_with
  :  ?on_not_run:(unit -> unit)
  -> ?withdrawn:(Masc_tui_types.workspace_refusal -> 'error)
  -> Masc_tui_types.state
  -> mailbox:mailbox
  -> boundary_error:(string -> 'error)
  -> deliver:(('a, 'error) result -> unit)
  -> (unit -> ('a, 'error) result)
  -> unit

val launch_async_read_pair
  :  Masc_tui_types.state
  -> mailbox:mailbox
  -> boundary_error:(string -> 'error)
  -> withdrawn:(Masc_tui_types.workspace_refusal -> 'error)
  -> deliver_first:(('a, 'error) result -> unit)
  -> deliver_second:(('b, 'error) result -> unit)
  -> (unit -> ('a, 'error) result)
  -> (unit -> ('b, 'error) result)
  -> unit

val launch_guarded_request
  :  ?operation:bool
  -> ?cancelled:Masc_tui_async_protocol.async_msg
  -> ?cancelled_by:(unit -> Masc_tui_async_protocol.async_msg)
  -> Masc_tui_types.state
  -> mailbox:mailbox
  -> boundary_error:(string -> 'error)
  -> withdrawn:(Masc_tui_types.workspace_refusal -> 'error)
  -> deliver:(('a, 'error) result -> Masc_tui_async_protocol.async_msg)
  -> (unit -> ('a, 'error) result)
  -> unit

val capture_json_read
  :  Masc_tui_types.state
  -> (unit -> 'a)
  -> (unit -> ('a, Masc_tui_types.workspace_refusal) result)

val launch_json_read
  :  ?key:unit ref
  -> ?on_not_run:(unit -> unit)
  -> Masc_tui_types.state
  -> mailbox:mailbox
  -> boundary_error:(string -> 'error)
  -> withdrawn:(Masc_tui_types.workspace_refusal -> 'error)
  -> deliver:(('a, 'error) result -> Masc_tui_async_protocol.async_msg)
  -> (unit -> ('a, 'error) result)
  -> unit

val attribute_request_failure
  :  Masc_tui_async_read.source
  -> Masc_tui_types.request_failure
  -> Masc_tui_types.request_failure

val launch_guarded_async_read
  :  ?source:Masc_tui_async_read.source
  -> ?on_not_run:(unit -> unit)
  -> Masc_tui_types.state
  -> mailbox:mailbox
  -> deliver:(('a, Masc_tui_types.request_failure) result -> unit)
  -> (unit -> (('a, string) result, Masc_tui_types.workspace_refusal) result)
  -> unit
