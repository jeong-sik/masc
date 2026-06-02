(** Chronicle_index — index structure for navigating chronicle epochs.
    @since Project Chronicle Phase 1 *)

type epoch_summary =
  { id : string
  ; label : string
  ; start_date : string
  ; end_date : string
  ; status : Chronicle_types.epoch_status
  ; file_path : string
  ; conductivity : float (** Law 4: read/write intensity *)
  }
[@@deriving yojson, show]

type index =
  { schema_version : int
  ; repo : string
  ; last_updated : string
  ; epochs : epoch_summary list
  ; last_commit_indexed : string
  }
[@@deriving yojson, show]

val current_schema_version : int

type pheromone_policy =
  { tau_min : float
  ; tau_max : float
  ; base_evaporation : float
  ; stagnation_threshold : float
  ; stagnation_boost : float
  }

val default_pheromone_policy : pheromone_policy
(** Max-Min conductivity and adaptive evaporation defaults for Chronicle
    trail pheromones. *)

val empty : repo:string -> now:string -> index
(** Create an empty index with the current schema version. *)

val find_epoch : index -> string -> epoch_summary option
(** Look up an epoch by ID. *)

val active_epochs : index -> epoch_summary list
(** Return only epochs with [Active] status. *)

val add_or_replace_epoch : index -> epoch_summary -> index
(** Add or replace an epoch summary, returning a new index. *)

val bound_conductivity : ?policy:pheromone_policy -> float -> float
(** Clamp a conductivity value to the policy's Max-Min range. *)

val active_trail_stagnation_score : epoch_summary list -> float
(** Return [0, 1] concentration score for active Chronicle trails.
    [0] means balanced or no active trail; [1] means one active trail
    monopolizes all conductivity. *)

val adaptive_evaporation_rate :
  ?policy:pheromone_policy -> stagnation_score:float -> unit -> float
(** Evaporation rate derived from the current stagnation score. *)

val evaporate_conductivity :
  ?policy:pheromone_policy -> stagnation_score:float -> float -> float
(** Apply adaptive evaporation and Max-Min bounds to one conductivity. *)

val evaporate_active_epochs : ?policy:pheromone_policy -> index -> index
(** Evaporate active Chronicle epoch conductivities using the index's current
    active trail concentration score. Non-active epochs are preserved. *)
