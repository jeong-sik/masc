(** Tool_autoresearch_registry — loop registry, hypothesis injection, and
    custom code generator state for the autoresearch loop. *)

let active_loops = Autoresearch.active_loops
let latest_loop_id = Autoresearch.latest_loop_id

(** Pending hypothesis injections. *)
let pending_hypotheses : (string, string) Hashtbl.t =
  Hashtbl.create 4


(** Code generator type for test injection.
    Returns Ok (hypothesis, new_code) or Error reason. *)
type code_generator =
  goal:string -> baseline:float -> lower_is_better:bool ->
  history:Autoresearch.cycle_record list ->
  insights:string list ->
  target_file:string -> file_content:string ->
  (string * string, string) Stdlib.result

(** Per-loop code generator override (for tests). *)
let custom_generators : (string, code_generator) Hashtbl.t =
  Hashtbl.create 4

(** Set a custom code generator for a loop (used in tests). *)
let set_generator loop_id gen =
  Hashtbl.replace custom_generators loop_id gen

(** Get the code generator for a loop. Falls back to Autoresearch.generate_code_change. *)
let get_generator loop_id =
  match Hashtbl.find_opt custom_generators loop_id with
  | Some gen -> gen
  | None -> Autoresearch.generate_code_change
