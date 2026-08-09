(** Explicit, no-model-call login probes for configured official-client
    runtimes. Operational negative results are returned as measured payloads;
    malformed or non-official runtime requests are typed request errors. *)

type error_kind =
  | Bad_request
  | Not_found
  | Service_unavailable

type error =
  { kind : error_kind
  ; code : string
  ; message : string
  }

val probe_body :
  base_path:string ->
  body:string ->
  (Yojson.Safe.t, error) result
