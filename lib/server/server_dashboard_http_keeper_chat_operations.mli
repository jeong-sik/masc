(** HTTP adapter for Keeper chat operation reads and queued-only mutations. *)

type get_route =
  | Operation_list of { keeper_name : string }
  | Operation_exact of
      { keeper_name : string
      ; raw_operation_id : string
      }

type mutation =
  | Edit
  | Move_to_end
  | Cancel

type mutation_route =
  { keeper_name : string
  ; raw_operation_id : string
  ; mutation : mutation
  }

val read_permission : Masc_domain.permission
val mutation_permission : Masc_domain.permission

val get_route : string -> get_route option
val mutation_route : string -> mutation_route option

val handle_get
  :  Mcp_server.server_state
  -> Httpun.Request.t
  -> Httpun.Reqd.t
  -> get_route
  -> unit

val handle_mutation
  :  Mcp_server.server_state
  -> Httpun.Request.t
  -> Httpun.Reqd.t
  -> mutation_route
  -> string
  -> unit

module For_testing : sig
  val parse_mutation_body
    :  mutation
    -> string
    -> (Yojson.Safe.t option, string) result
end
