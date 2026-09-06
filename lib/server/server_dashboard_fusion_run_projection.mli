(** Read-only Fusion run detail projected from the run registry and Board's
    exact typed-origin index. *)

type evidence_status =
  | Recorded
  | Pending
  | Absent

type evidence =
  { status : evidence_status
  ; post : Board.post option
  }

type detail =
  { run : Fusion_run_registry.run
  ; evidence : evidence
  }

type lookup =
  | Found of detail
  | Run_not_found

val detail_prefix : string

val to_yojson : generated_at:string -> detail -> Yojson.Safe.t
(** Serialize the detail contract with explicit [evidence.post] JSON or null. *)

val list_response :
  generated_at:string -> registry:Fusion_run_registry.t -> Yojson.Safe.t
(** Shared HTTP/1 and HTTP/2 list payload. *)

val detail_response :
  generated_at:string ->
  registry:Fusion_run_registry.t ->
  path:string ->
  [ `Bad_request | `Not_found | `OK ] * Yojson.Safe.t
(** Shared HTTP/1 and HTTP/2 detail response. The path suffix is decoded
    exactly; a blank suffix is [Bad_request] and an unknown run is
    [Not_found]. *)
