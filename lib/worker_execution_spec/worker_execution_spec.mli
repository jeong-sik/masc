(** Worker_execution_spec — JSON-addressable snapshot of a worker
    invocation.

    Carried across the local-worker boundary so runtime code
    (docker/container runners, tests) can reconstruct a worker run
    from stored state. *)

type t = {
  base_path : string;
  worker_name : string;
  model_label : string;
  working_dir : string option;
  runtime_backend : Worker_execution_backend.t;
  thinking_enabled : bool option;
  worker_run_id : string option;
  role : string option;
  selection_note : string option;
  prompt : string;
  timeout_sec : int;
}

val to_yojson : t -> Yojson.Safe.t

(** [of_yojson json] parses a previously serialized spec and rejects
    removed worker contract fields. *)
val of_yojson : Yojson.Safe.t -> (t, string) result
