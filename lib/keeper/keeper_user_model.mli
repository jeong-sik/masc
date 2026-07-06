(** Keeper_user_model — operator preference/constraint projection.

    This is a read-only MASC-side projection over Memory OS facts. It turns
    librarian-categorized [Preference] and [Constraint] facts into a compact
    prompt block for keepers; it does not change Memory OS write semantics or
    add provider/OAS responsibilities. *)

type item_source =
  | Keeper_private
  | Shared of string list

type item =
  { claim : string
  ; category : Keeper_memory_os_types.category
  ; source : item_source
  ; turn : int
  ; first_seen : float
  ; last_verified_at : float option
  }

type t =
  { preferences : item list
  ; constraints : item list
  ; source_fact_count : int
  ; shared_fact_count : int
  }

type build_error =
  | Fact_store_parse_error of Keeper_memory_os_io.fact_jsonl_parse_error list

val build_error_to_string : build_error -> string

val build_result
  :  keeper_id:string
  -> now:float
  -> ?max_preferences:int
  -> ?max_constraints:int
  -> unit
  -> (t, build_error) result
(** Result-returning projection. Malformed private or shared Memory OS fact rows
    are explicit errors, not partial user-model projections. *)

val build
  :  keeper_id:string
  -> now:float
  -> ?max_preferences:int
  -> ?max_constraints:int
  -> unit
  -> t

val render_prompt_block : t -> string option

val enabled : unit -> bool
(** Kill-switch flag [MASC_KEEPER_USER_MODEL] (default [true]). *)

val render_if_enabled : keeper_id:string -> now:float -> unit -> string option
