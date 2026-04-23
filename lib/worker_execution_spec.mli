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
  worker_class : Worker_types.worker_class option;
  thinking_enabled : bool option;
  max_turns : int;
  worker_run_id : string option;
  role : string option;
  selection_note : string option;
  prompt : string;
  allowed_tools : string list;
  allowed_shell_tools : string list;
  timeout_sec : int;
}

val to_yojson : t -> Yojson.Safe.t

(** [of_yojson json] parses a previously serialized spec. Unknown
    strings for [worker_class] surface as [None]. *)
val of_yojson : Yojson.Safe.t -> (t, string) result
