(** Pure lane edits against the declarations of one runtime.toml observation.
    Runtime owns path resolution, journal admission, locking, reads, whole-file
    validation and commit. The admitted runtime/slot catalog is not edit input. *)

type exact_slot_list = Catalog_slots | Cli_slots

val exact_slot_list_key : exact_slot_list -> string
val exact_slot_list_admitting : Runtime_schema.api_format -> exact_slot_list option
(** The declared list that accepts this client's output-schema channel.
    [None] means neither list can dispatch an exact-output call through it.
    First-run setup and lane editing share this classification. *)

type exact_slot_move = Move_slot_up | Move_slot_down | Move_slot_first

type error
val error_to_string : error -> string

type edit
(** A request whose arguments have been trimmed and validated. Construction
    reads no configuration and is performed before acquiring the writer lock.
    Declaration-dependent refusals belong to {!plan}. *)

val create : lane_id:string -> runtime_ids:string list -> (edit, error) result
val rename : lane_id:string -> new_lane_id:string -> (edit, error) result
val remove : lane_id:string -> (edit, error) result
val set_exact_slots : lane:Standalone_lane.t -> slots:string list -> (edit, error) result
val append_exact_slot : lane:Standalone_lane.t -> slot:string -> (edit, error) result
val drop_exact_slot : lane:Standalone_lane.t -> slot:string -> (edit, error) result
val move_exact_slot :
  lane:Standalone_lane.t -> slot:string -> move:exact_slot_move -> (edit, error) result
val replace_exact_slot :
  lane:Standalone_lane.t -> slot:string -> replacement:string -> (edit, error) result

val plan : content:string -> Runtime_schema.config -> edit -> (string, error) result
(** Return the edited text or the first refusal. [content] and [config] must
    describe the same freshly read observation under the caller's writer lock.
    Rename rewrites the lane and all declared routing references together;
    exact-slot edits preserve the declared order and the other transport list.
    Success is a text plan, not validation or evidence of a committed write. *)
