(** Says that a connector's state changed (RFC-0480 §3.4).

    The event is [{"type":"gate_connector_changed","connector":<id>,"ts_unix":...}]
    and goes to the observers of [base_path]'s runtime. A reader that shows
    connectors ([GET /api/v1/gate/connectors], [GET /api/v1/gate/connector/names])
    reads that connector again. *)

val changed_event : string

val install : sw:Eio.Switch.t -> base_path:string -> unit
(** Installs the observer into [Gate_connector_announce] and the fiber that
    announces for it. The binding store and the connector name directory call
    the observer under their lock, so it only records which connector changed
    and wakes the fiber. The fiber sends one event per changed connector: a
    directory sync that records many names in a row is announced once. A
    failed broadcast is counted on [keeper_sse_broadcast_failures] and
    logged. *)
