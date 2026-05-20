(** RFC-0145 PR-4-3: extract post-turn memory bank compaction from
    [keeper_agent_run.run_turn] Step 8 body (L1583-L1616).

    Builds an [Keeper_memory_llm_summary] summarizer (cascade-aware)
    and invokes
    [Keeper_memory_bank.compact_memory_bank_if_needed]; logs an info
    line when compaction was performed (before/after/dropped notes).

    Side effects only.  [Eio.Cancel.Cancelled] re-raised;
    other exceptions counter + warn log under the
    [site=compaction] label. *)
val compact_if_needed
  :  config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> cascade_name_string:string
  -> ?provider_filter:Cascade_runner.provider_filter
  -> unit
  -> unit
