(** Read-only projection of the last provider input a Keeper actually sent.

    The turn record owns exact component byte counts and provider usage. The
    prompt capture owns exact text for the per-turn prompt blocks. They are
    kept as two readings because one may be unavailable without licensing the
    other to disappear. *)

type tool_surface_entry = Turn_record.tool_surface_entry =
  { name : string
  ; schema_bytes : int
  }
(** Re-exported rather than restated: the shape is owned by {!Turn_record},
    beside the field that points at the blob holding it. *)

(** Whether the Tool_schemas row can name its tools, and why not when it
    cannot. Three closed outcomes rather than an option: a turn that recorded
    no reference and a reference that could not be read are different facts,
    and folding them together would report a failed read as "this request
    carried no tools". *)
type tool_surface =
  | Surface_not_recorded
  | Surface_unresolved of { detail : string }
  | Surface_resolved of tool_surface_entry list

type reading =
  { turn : (Turn_record.t, string) result
  ; prompt : (Masc.Keeper_prompt_capture.capture, string) result
  ; tool_surface : tool_surface
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
val tool_surface_sha256 : Turn_record.t -> (string, string) result option
(** The content address the turn recorded for its tool surface. [None] when the
    record carries no reference; [Some (Error _)] when it carries one that is
    not a readable marker. The marker grammar is owned by {!Tool_output}; this
    reads it rather than restating it. *)

val decode_tool_surface :
  Yojson.Safe.t -> (tool_surface_entry list, string) result
(** Strictly decode the [GET /api/v1/artifacts/<sha256>] envelope into the
    listing the producer stored. One malformed entry fails the whole listing;
    dropping it would understate the surface that was actually sent. *)

val input_map_rows :
  Turn_record.t ->
  Masc.Keeper_prompt_capture.capture option ->
  tool_surface:tool_surface ->
  input_map_row list
(** Join exact component attribution to the prompt capture only when both
    observations name the same turn and the captured text matches the turn
    record's byte count and digest. Other provider-input components remain
    visible as byte-only evidence rather than being filled from another
    store. *)
val attributed_bytes : Turn_record.t -> int option
val format_bytes : int -> string
val format_tokens : int -> string
