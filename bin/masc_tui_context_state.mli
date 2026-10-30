module Decode = Masc.Tui_decode

type key
type request
type t

type start_result = Already_loading | Started of t * request

val empty : t
val clear : t -> t
val suspend : t -> t
val key_for_keeper : scope:unit ref -> base_path:string -> Decode.keeper -> key
val same_key : key -> key -> bool
val describe_key : key -> string * string * string option
val current_key : t -> key option
val request_key : request -> key
val request_id : request -> int64
val is_current : t -> request -> bool
val start : t -> key:key -> start_result
val complete : t -> request -> (Decode.context_observation, string) result -> t
val view : t -> key:key -> Decode.context_observation Masc_tui_fetched.view
(** Pending/failed/previous observations are explicit. Values never cross a
    workspace read scope, base path, Keeper or trace identity. *)

val resolve_with :
  project:(keeper_name:string -> current_trace_id:string -> (string * Yojson.Safe.t) list) ->
  Decode.keeper -> (Decode.context_observation, string) result
(** Decode against the captured trace, preserving identity/projection errors. *)
val load : config:Workspace_core.config -> Decode.keeper -> (Decode.context_observation, string) result
(** Read only; safe to pass immutable Keeper/config input to the I/O worker. *)
