(** Adaptive pheromone evaporation and Max-Min conductivity bounds for MASC Stigmergy.
    Prevents trail stagnation when keepers repeatedly deposit on the same path. *)

type path_id = string

type t = {
  mutable paths : (path_id, float) Hashtbl.t;
  tau_min : float;
  tau_max : float;
  base_rho : float;
  stagnation_threshold : float;
}

(** Create a new pheromone tracker with bounds. *)
val create : ?tau_min:float -> ?tau_max:float -> ?base_rho:float -> ?stagnation_threshold:float -> unit -> t

(** Deposit pheromone on a path. Increases conductivity. *)
val deposit : t -> path_id -> amount:float -> unit

(** Evaporate pheromones across all paths.
    If the max pheromone level exceeds the stagnation_threshold relative to others,
    the evaporation rate (rho) adaptively increases to prevent stagnation. *)
val evaporate : t -> unit

(** Get current pheromone level (conductivity) for a path. Defaults to tau_min. *)
val get_level : t -> path_id -> float
