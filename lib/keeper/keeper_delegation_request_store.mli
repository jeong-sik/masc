(** Durable review surface for keeper delegation requests.

    This store persists [propose_spawn] projections as reviewable artifacts under
    [.masc/delegation-requests/]. It never spawns agents and never mutates the
    task graph; a human or existing operator workflow must promote a request. *)

type stored_request =
  { request : Keeper_delegation_request.t
  ; dir : string
  ; json_path : string
  ; task_seed_md_path : string
  ; index_path : string
  }

type request_summary =
  { id : string
  ; requester : string
  ; topic : string
  ; promotion_state : string
  ; dir : string
  ; json_path : string
  ; task_seed_md_path : string
  ; created_at : float option
  }

type request_listing =
  { total : int
  ; shown : int
  ; limit : int
  ; index_path : string
  ; items : request_summary list
  }

val requests_dir : base_path:string -> string
val index_path : base_path:string -> string
val request_dir : base_path:string -> Keeper_delegation_request.t -> string

val render_task_seed_md : Keeper_delegation_request.t -> string

val write_request
  :  base_path:string
  -> Keeper_delegation_request.t
  -> (stored_request, string) result

val write_requests
  :  base_path:string
  -> Keeper_delegation_request.t list
  -> (stored_request list, string) result

val write_request_if_changed
  :  base_path:string
  -> Keeper_delegation_request.t
  -> (stored_request option, string) result

val write_execution_result
  :  base_path:string
  -> requester:string
  -> Keeper_deliberation.execution_result
  -> (stored_request list, string) result

val list_requests : base_path:string -> limit:int -> (request_listing, string) result
val request_summary_to_json : request_summary -> Yojson.Safe.t
