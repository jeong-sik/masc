(** Dashboard HTTP handler bodies extracted from the dashboard route table. *)

val handle_broadcast :
  Mcp_server.server_state -> string -> Httpun.Reqd.t -> string -> unit
(** Handle dashboard broadcast POST bodies. *)

val handle_dashboard_link_previews :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
(** Handle dashboard link-preview POST bodies. *)

val handle_dashboard_task_history :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Handle dashboard task-history requests. *)

val handle_dashboard_rooms :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Handle dashboard rooms requests. *)
