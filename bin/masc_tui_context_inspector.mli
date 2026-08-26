(** Read-only projection of the last provider input a Keeper actually sent.

    The turn record owns exact component byte counts and provider usage. The
    prompt capture owns exact text for the per-turn prompt blocks. They are
    kept as two readings because one may be unavailable without licensing the
    other to disappear. *)

type reading =
  { turn : (Turn_record.t, string) result
  ; prompt : (Masc.Keeper_prompt_capture.capture, string) result
  }

type tab =
  | Composition
  | Prompt_blocks
  | Input_map

type input_map_row =
  { component : Turn_record.input_component_id
  ; bytes : int
  ; included_by : string
  ; retention : string
  ; exact_text : string option
  }

val decode_turn_records : Yojson.Safe.t -> (Turn_record.t, string) result
(** Strictly decode every returned row, then select the newest row that has an
    exact input-component observation. A malformed row fails the reading; it
    is never dropped to make the input look smaller. *)

val decode_prompt_capture :
  expected_keeper:string -> Yojson.Safe.t ->
  (Masc.Keeper_prompt_capture.capture, string) result

val input_component_label : Turn_record.input_component_id -> string
val prompt_block_label : Prompt_block_id.t -> string
val input_map_rows :
  Turn_record.t ->
  Masc.Keeper_prompt_capture.capture option ->
  input_map_row list
(** Join exact component attribution to the prompt capture only when both
    observations name the same turn and the captured text matches the turn
    record's byte count and digest. Other provider-input components remain
    visible as byte-only evidence rather than being filled from another
    store. *)
val attributed_bytes : Turn_record.t -> int option
val format_bytes : int -> string
val format_tokens : int -> string
