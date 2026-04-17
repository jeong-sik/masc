(** Tool_autoresearch_registry — loop registry, hypothesis injection, and
    custom code generator state for the autoresearch loop.

    [refactor] custom_generators: Hashtbl → StringMap.t ref.
    pending_hypotheses left as-is (dead code — separate deletion PR).
    No concurrent access; test uses reset helper for teardown. *)

module StringMap = Map.Make (String)

let active_loops = Autoresearch.active_loops
let latest_loop_id = Autoresearch.latest_loop_id

(** Pending hypothesis injections.
    NOTE: dead code (0 external callers per rg). Tracked for separate deletion PR. *)
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

(** Per-loop code generator override (for tests).
    Replaced Hashtbl with StringMap.t ref — immutable map + ref for mutability.
    Max entries = concurrent active loops (typically 1-3), so O(log n) is negligible. *)
let custom_generators : code_generator StringMap.t ref =
  ref StringMap.empty

(** Set a custom code generator for a loop (used in tests). *)
let set_generator loop_id gen =
  custom_generators := StringMap.add loop_id gen !custom_generators

(** Get the code generator for a loop. Falls back to Autoresearch.generate_code_change. *)
let get_generator loop_id =
  match StringMap.find_opt loop_id !custom_generators with
  | Some gen -> gen
  | None -> Autoresearch.generate_code_change

(** Reset helper for test teardown (replaces Hashtbl.reset on custom_generators). *)
let reset_custom_generators () =
  custom_generators := StringMap.empty

(** Remove a generator entry (replaces Hashtbl.remove on custom_generators). *)
let remove_generator loop_id =
  custom_generators := StringMap.remove loop_id !custom_generators
