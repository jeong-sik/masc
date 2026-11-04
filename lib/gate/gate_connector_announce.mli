(** Says that a connector's state changed, for readers that show connectors
    (RFC-0480 §3.4).

    This library does not know the server's event stream. The server installs
    an observer at boot ({!install}); the writers of connector state call
    {!changed} after their write. Before an observer is installed, as in a CLI
    process or a test, there is no reader to tell and {!changed} does
    nothing.

    The writers are the binding store ({!Channel_gate_binding_store}), the
    connector name directory ([Keeper_connector_names]) and the connectors'
    own state setters. Some call {!changed} under their own lock, so the
    observer must not yield and must not raise. The server's observer only
    records which connector changed and wakes the fiber that sends. *)

val install : (connector_id:string -> unit) -> unit
(** Replace the observer. The server installs one per process at boot. *)

val changed : connector_id:string -> unit
(** Tell the installed observer that [connector_id]'s state changed. *)
