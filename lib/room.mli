(** MASC Room - Core coordination logic.

    This module ties together all Room sub-modules (utils, state, task,
    portal, worktree, gc, vote) and adds room-level functions for join,
    leave, init, status, walph control, tempo, and multi-room management. *)

(** {1 Included sub-modules} *)

include module type of Room_utils
include module type of Room_state
include module type of Room_task
include module type of Room_portal
include module type of Room_worktree
include module type of Room_gc
include module type of Room_vote

(** {1 Room lifecycle} *)

val join :
  config ->
  agent_name:string ->
  ?agent_type_override:string option ->
  capabilities:string list ->
  ?pid:int option ->
  ?hostname:string option ->
  ?tty:string option ->
  ?worktree:string option ->
  ?parent_task:string option ->
  unit -> string

val join_in_room :
  config ->
  room_id:string ->
  agent_name:string ->
  ?agent_type_override:string option ->
  capabilities:string list ->
  ?pid:int option ->
  ?hostname:string option ->
  ?tty:string option ->
  ?worktree:string option ->
  ?parent_task:string option ->
  unit -> string

val leave : config -> agent_name:string -> string

val init : config -> agent_name:string option -> string

val pause : config -> by:string -> reason:string -> unit

val resume : config -> by:string -> [> `Already_running | `Resumed ]

val reset : config -> string

val status : config -> string

(** {1 Walph control system} *)

type walph_state = {
  mutable running : bool;
  mutable paused : bool;
  mutable stop_requested : bool;
  mutable current_preset : string;
  mutable iterations : int;
  mutable completed : int;
  mutex : Mutex.t;
  cond : Condition.t;
}

val walph_states : (string, walph_state) Hashtbl.t
val walph_states_mutex : Mutex.t
val get_walph_state : config -> walph_state
val remove_walph_state : config -> unit
val with_walph_lock : walph_state -> (unit -> 'a) -> 'a

val parse_walph_command : string -> (string * string) option

val walph_control :
  config ->
  from_agent:string ->
  command:string ->
  args:string -> string

val walph_should_continue : config -> bool

val get_chain_id_for_preset : string -> string option

val walph_loop :
  config ->
  agent_name:string ->
  ?preset:string ->
  ?max_iterations:int ->
  ?target:string ->
  unit -> string

(** {1 Task helpers} *)

val update_priority :
  config -> task_id:string -> priority:int -> string

val get_tasks_raw : config -> Types.task list

val get_tasks_raw_in_room : config -> string -> Types.task list

val get_agents_raw : config -> Types.agent list

val get_agents_raw_in_room : config -> string -> Types.agent list

val audit_orphan_tasks : config -> (Types.task * string) list

val list_tasks :
  ?include_done:bool ->
  ?include_cancelled:bool ->
  ?status:string ->
  config -> string

(** {1 Agent queries} *)

val count_agents_in_room : config -> string -> int

val is_agent_joined_in_room :
  config -> room_id:string -> agent_name:string -> bool

val is_agent_joined : config -> agent_name:string -> bool

val is_valid_filename : string -> bool

val get_messages_raw :
  config -> since_seq:int -> limit:int -> Types.message list

val get_messages_raw_in_room :
  config -> room_id:string -> since_seq:int -> limit:int -> Types.message list

val get_messages : config -> since_seq:int -> limit:int -> string

val get_agents_status : config -> Yojson.Safe.t

val register_capabilities :
  config -> agent_name:string -> capabilities:string list -> string

val update_agent_r :
  config ->
  agent_name:string ->
  ?status:string ->
  ?capabilities:string list ->
  unit -> string Types.masc_result

val find_agents_by_capability :
  config -> capability:string -> Yojson.Safe.t

(** {1 Tempo control} *)

val read_tempo : config -> Types.tempo_config
val write_tempo : config -> Types.tempo_config -> unit
val get_tempo : config -> Yojson.Safe.t

val set_tempo :
  config ->
  mode:string ->
  reason:string option ->
  agent_name:string -> string

(** {1 Multi-room management} *)

val read_current_room : config -> string option
val write_current_room : config -> string -> unit
val room_path : config -> string -> string
val rooms_list : config -> Yojson.Safe.t

val room_create :
  config -> name:string -> description:string option -> Yojson.Safe.t

val ensure_room_entry : config -> string -> unit

val room_enter :
  config ->
  room_id:string ->
  ?agent_name:string ->
  agent_type:string ->
  unit -> Yojson.Safe.t
