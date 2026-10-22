(** Immutable structural witnesses for issuer context carriers only. Raw source
    offsets are never reported as encoded wire offsets. No vendor retention claim.
    V2 reports source acquisition separately from transport slot matching:
    not-applicable, verified, unavailable, or partial for mixed carriers.
    Missing/stale issuers remain unavailable through composition and held omission. *)
type t
val literal : string -> t
val text : t -> string
val encoded_carrier :
  assembly:Keeper_context_assembly.t option ->
  selected_blocks:Prompt_block_id.t list option ->
  ?omitted_sections:Keeper_context_layers.source list ->
  ?omitted_rows:(Keeper_context_layers.source * string list) list ->
  Agent_core.Types.message -> t
(** Encodes the actual message with the production codec. Attribution requires
    exact issuer bytes, or an exact ordered subset of its uniquely named blocks.
    [omitted_sections] (default none) are World State sections a resume left
    out of the selected [Dynamic_context] block; the block then attributes as
    its renderer's other sections, in order, and the proof names the ones left
    out. [omitted_rows] (default none) name, by sha256, the rows a resume left
    out of a section it sent in part ({!Keeper_context_layers.Head_and_rows});
    that section then attributes as its head, its other rows and its tail, and
    the proof names the rows left out. *)
val concat : separator:string -> t list -> t
val trim : t -> t
val omit_held : assembly:Keeper_context_assembly.t option ->
  blocks:Prompt_block_id.t list option -> Agent_core.Types.message -> t -> t
val binding_to_json : slot:Runtime_official_client_write.slot ->
  t -> Runtime_official_client_write.t -> Yojson.Safe.t
(** Called only by a completed-write observer. The piece matches when the
    write's [slot] holds its text as that write encodes it. A mismatch yields
    unavailable evidence, never a provider failure or retry. Content-free; no
    Tool history. The frame the write belongs to is recorded beside this
    binding, not in it. *)
