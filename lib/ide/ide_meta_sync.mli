(** IDE meta sync — Keeper activity → .masc-ide/ synchronization engine. *)

open Ide_annotation_types

type config =
  { base_path : string
  ; flush_on_turn_complete : bool
  ; batch_size : int
  }

val default_config : config

type sync_state

val initial_state : sync_state

val extract_regions_from_tool_call
  :  keeper_id:string
  -> turn:int
  -> tool_name:string
  -> file_path:string
  -> diff_text:string option
  -> full_content:string option
  -> code_region list

val on_tool_call_complete
  :  config
  -> sync_state
  -> keeper_id:string
  -> turn:int
  -> tool_name:string
  -> file_path:string
  -> diff_text:string option
  -> full_content:string option
  -> sync_state

val on_turn_complete : config -> sync_state -> sync_state
val flush_regions : config -> sync_state -> sync_state

type stats =
  { pending_region_count : int
  ; pending_annotation_count : int
  ; turn_count : int
  ; last_flush_ago : float
  }

val get_stats : sync_state -> stats
