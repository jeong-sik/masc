(** Read-only observations of serialized Agent Core requests. These do not
    authorize history removal or prove a provider accepted the request. *)
type frontier = { trace_id : string; end_atom : int; boundary_line : int }
type input =
  | Summarized of frontier
  | Absorbed of { trace_id : string; end_atom : int }
      (** The request started at the Librarian's durable position, with no
          summary of what lies before it. *)
  | Uncompressed
  | Not_applied
type t =
  { prepared_at : float
  ; runtime_id : string
  ; input : input
  ; request_bytes : int
  }
val record : config:Workspace.config -> keeper_name:string -> t -> unit
val latest : config:Workspace.config -> keeper_name:string -> t option
val forget : config:Workspace.config -> keeper_name:string -> unit

type synthesis_state =
  | Checking | Running | Committed | No_source
  | Disabled | Source_unavailable | Input_unavailable | Not_committed
  | Capacity_refused | Cancelled

type atom_range = { start_atom : int; end_atom : int; completed_end_atom : int }
type synthesis =
  { observed_at : float
  ; trace_id : string option
  ; state : synthesis_state
  ; range : atom_range option
  }
val record_synthesis : config:Workspace.config -> keeper_name:string -> synthesis -> unit
val latest_synthesis : config:Workspace.config -> keeper_name:string -> synthesis option
val synthesis_state_to_string : synthesis_state -> string
val synthesis_to_json : synthesis -> Yojson.Safe.t
val synthesis_of_json : Yojson.Safe.t -> (synthesis, string) result
(** Process-local synthesis evidence, independent of the ordinary Memory drain.
    [No_source] does not certify that the checkpoint has been summarized. *)
