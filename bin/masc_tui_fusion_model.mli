(** Read-only Fusion list, detail and Keeper-run selection from shared state. *)

val fusion_snapshot_entries : Masc.Tui_decode_fusion.fusion_snapshot -> Masc.Tui_decode_fusion.fusion_list_entry list
val fusion_runs_view : Masc_tui_types.state -> Masc.Tui_decode_fusion.fusion_snapshot Masc_tui_fetched.view
val fusion_snapshot : Masc_tui_types.state -> Masc.Tui_decode_fusion.fusion_snapshot option
(** The latest retained snapshot, including a stale successful reading.
    [None] means no successful snapshot is available. *)

val fusion_list_entries : Masc_tui_types.state -> Masc.Tui_decode_fusion.fusion_list_entry list
val fusion_entry_identity : Masc.Tui_decode_fusion.fusion_list_entry -> string
val selected_fusion_entry : Masc_tui_types.state -> Masc.Tui_decode_fusion.fusion_list_entry option
val fusion_detail_entry_index : Masc_tui_types.state -> int option
val selected_keeper_runs : Masc_tui_types.state -> Masc.Tui_decode_fusion.fusion_run list
val selected_keeper_run : Masc_tui_types.state -> (int * Masc.Tui_decode_fusion.fusion_run) option
val keeper_runs_view : Masc_tui_types.state -> Masc.Tui_decode_fusion.fusion_run list Masc_tui_fetched.view
