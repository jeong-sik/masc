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
  selected_blocks:Prompt_block_id.t list option -> Agent_core.Types.message -> t
(** Encodes the actual message with the production codec. Attribution requires
    exact issuer bytes, or an exact ordered subset of its uniquely named blocks. *)
val concat : separator:string -> t list -> t
val trim : t -> t
val omit_held : assembly:Keeper_context_assembly.t option ->
  blocks:Prompt_block_id.t list option -> Agent_core.Types.message -> t -> t
val binding_to_json : slot:Runtime_codex_app_server.context_fragment_slot ->
  t -> Runtime_codex_app_server.context_submission -> Yojson.Safe.t
(** Called only by the completed-write observer. A mismatch yields unavailable
    evidence, never a provider failure or retry. Content-free; no Tool history. *)
