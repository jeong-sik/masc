(** Read-only observations of composed requests: what each one started
    from, recorded before it went out. Agent Core records its serialized
    request; the official-client lanes record the range they handed the
    client ([Keeper_official_client_host.continuity_observation_input]).
    These do not authorize history removal or prove a provider accepted the
    request. *)
type frontier = { trace_id : string; end_atom : int; boundary_line : int }
type input =
  | Summarized of frontier
  | Absorbed of { trace_id : string; end_atom : int }
      (** The request started at the Librarian's durable position, with no
          summary of what lies before it. *)
  | Without_snapshot
      (** The turn chose no absorbed point: the request started at its own
          boundary. *)
  | Not_applied
      (** The saved context was not applied to this request: the turn made no
          choice (no trace, or a recovery view), or, on an official-client
          lane, the seed or the lane's own cut sat past the point the turn
          chose. *)
type t =
  { prepared_at : float
  ; runtime_id : string
  ; input : input
  ; request_bytes : int
        (** Agent Core: the serialized request body. Official-client lanes:
            the carried range in the canonical encoding, before the client
            assembles its own request. *)
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
