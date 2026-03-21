(** Backend_eio_types - Shared types for Backend_eio modules.

    Extracted to avoid circular dependency between
    Backend_eio and Backend_eio_pg. *)

type error =
  | NotFound of string
  | AlreadyExists of string
  | IOError of string
  | InvalidKey of string

type 'a result = ('a, error) Stdlib.result

type config = {
  base_path: string;
  node_id: string;
  cluster_name: string;
}

let default_config = {
  base_path = ".masc";
  node_id = Printf.sprintf "node_%d" (Unix.getpid ());
  cluster_name = "default";
}

type health_result = {
  latency_ms: float;
  is_healthy: bool;
}
