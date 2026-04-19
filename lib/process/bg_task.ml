(* Phase 2 Tick 4: signatures + switch scaffolding only. Runtime
   machinery (pgid setup, ring buffers, reaper) lands in Tick 5. Every
   [spawn]/[read]/[kill] today returns a "not yet implemented" error so
   that downstream wiring PRs can compile against the real types
   without the feature being live. *)

type task_id = string

let task_id_to_string t = t
let task_id_of_string_exn s =
  if s = "" then invalid_arg "Bg_task.task_id_of_string_exn: empty handle";
  s

type snapshot = {
  stdout_since : string;
  stderr_since : string;
  closed : bool;
  status : Unix.process_status option;
  bytes_dropped_stdout : int;
  bytes_dropped_stderr : int;
}

type spawn_error =
  | Spawn_failed of string
  | Too_many_tasks of { keeper : string; limit : int }
  | Invalid_cwd of string

type read_error =
  | Unknown_task of task_id
  | Read_failed of string

type kill_error =
  | Unknown_task_kill of task_id
  | Kill_failed of string

(* Registry is a placeholder so that [list] can return []. When Tick 5
   lands this becomes a [Hashtbl.t] keyed by task_id plus an Eio.Mutex
   guarding it. *)
let _registry : (string, task_id list) Hashtbl.t = Hashtbl.create 16

let not_implemented reason =
  Spawn_failed (Printf.sprintf "bg_task.spawn not implemented yet: %s" reason)

let spawn ~sw:_ ~env:_ ~keeper:_ ~argv:_ ~cwd:_ ~envp:_ ~timeout_sec:_ =
  Error (not_implemented "awaiting Tick 5")

let read _id ~since_stdout:_ ~since_stderr:_ =
  Error (Read_failed "bg_task.read not implemented yet: awaiting Tick 5")

let kill _id ~signal:_ ~grace_sec:_ =
  Error (Kill_failed "bg_task.kill not implemented yet: awaiting Tick 5")

let list ~keeper =
  match Hashtbl.find_opt _registry keeper with
  | Some ids -> ids
  | None -> []

let reap_orphans ~base_path:_ = 0
