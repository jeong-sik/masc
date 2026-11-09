open Masc

type lag =
  | Lag_unmeasured
  | Lag of int

type gap =
  | No_gap
  | Gap of
      { first_atom : int
      ; past_last_atom : int
      }
  | Gap_unmeasured

type t =
  | Unknown
  | No_row
  | Refused of string
  | Row of
      { state : Masc_tui_types.memory_state
      ; lag : lag
      ; gap : gap
      ; digest_at : float option
      ; updated_at : float option
      ; added : int
      ; removed : int
      ; source_invalidations : int
      ; age_bins : Masc.Keeper_memory_age_bins.t option
      }

type index =
  { ind_snapshot : Tui_decode_memory_health.memory_health_snapshot option
  ; ind_has_anonymous_refusal : bool
  ; ind_keepers : (string, t) Hashtbl.t
  }

let unread_lag (librarian : Tui_decode_memory_health.memory_librarian_health) =
  match librarian.mlh_unread_atom_turns, librarian.mlh_unread_official_turns with
  | Some atoms, Some official -> Some (atoms + official)
  | Some _, None | None, Some _ | None, None -> None
;;

let index_of_snapshot (snap_opt : Tui_decode_memory_health.memory_health_snapshot option) : index =
  match snap_opt with
  | None ->
      { ind_snapshot = None
      ; ind_has_anonymous_refusal = false
      ; ind_keepers = Hashtbl.create 0
      }
  | Some snap ->
      let has_anonymous_refusal =
        List.exists
          (fun (r : Tui_decode_memory_health.memory_keeper_refusal) ->
            Option.is_none r.mkr_keeper_id)
          snap.mhs_refused_keepers
      in
      let table =
        Hashtbl.create
          (List.length snap.mhs_keepers + List.length snap.mhs_refused_keepers)
      in
      List.iter
        (fun (r : Tui_decode_memory_health.memory_keeper_refusal) ->
          match r.mkr_keeper_id with
          | Some id -> Hashtbl.replace table id (Refused r.mkr_reason)
          | None -> ())
        snap.mhs_refused_keepers;
      List.iter
        (fun (k : Tui_decode_memory_health.memory_keeper_health) ->
          let lag =
            match unread_lag k.mkh_librarian with
            | Some turns -> Lag turns
            | None -> Lag_unmeasured
          in
          let gap =
            match k.mkh_librarian.mlh_stalled with
            | None -> No_gap
            | Some (Stalled_gap { mls_gap_start_atom; mls_gap_end_atom }) ->
                Gap { first_atom = mls_gap_start_atom; past_last_atom = mls_gap_end_atom }
            | Some (Stalled_unmeasured _) -> Gap_unmeasured
          in
          let state = Masc_tui_types.memory_state k in
          let row =
            Row
              { state
              ; lag
              ; gap
              ; digest_at = k.mkh_librarian.mlh_last_success_at
              ; updated_at = k.mkh_updated_at
              ; added = k.mkh_added
              ; removed = k.mkh_removed
              ; source_invalidations = k.mkh_source_invalidations
              ; age_bins = k.mkh_age_bins
              }
          in
          Hashtbl.replace table k.mkh_keeper_id row)
        snap.mhs_keepers;
      { ind_snapshot = Some snap
      ; ind_has_anonymous_refusal = has_anonymous_refusal
      ; ind_keepers = table
      }
;;

let find (idx : index) ~keeper_name : t =
  match idx.ind_snapshot with
  | None -> Unknown
  | Some _ ->
      match Hashtbl.find_opt idx.ind_keepers keeper_name with
      | Some t -> t
      | None ->
          if idx.ind_has_anonymous_refusal then
            Unknown
          else
            No_row
;;

let unknown_cell = { Masc_tui_keeper_axis_cell.text = "mem ?"; tone = Quiet }
let refused_cell = { Masc_tui_keeper_axis_cell.text = "mem !"; tone = Failure }

let cell_of_lag = function
  | Lag n ->
      let tone =
        if n > 0 then Masc_tui_keeper_axis_cell.Attention else Masc_tui_keeper_axis_cell.Quiet
      in
      { Masc_tui_keeper_axis_cell.text = Printf.sprintf "lag %d" n; tone }
  | Lag_unmeasured -> { Masc_tui_keeper_axis_cell.text = "lag ?"; tone = Quiet }
;;

let lag_cell = function
  | Unknown -> Some unknown_cell
  | No_row -> None
  | Refused _ -> Some refused_cell
  | Row { lag; _ } -> Some (cell_of_lag lag)
;;

let cells ~now = function
  | Unknown -> [ unknown_cell ]
  | No_row -> []
  | Refused _ -> [ refused_cell ]
  | Row { lag; gap; updated_at; added; removed; source_invalidations; _ } ->
      let gap_cells =
        match gap with
        | Gap { first_atom; past_last_atom } ->
            let count = past_last_atom - first_atom in
            [ { Masc_tui_keeper_axis_cell.text = Printf.sprintf "gap %d" count; tone = Attention } ]
        | Gap_unmeasured ->
            [ { Masc_tui_keeper_axis_cell.text = "gap ?"; tone = Attention } ]
        | No_gap -> []
      in
      let clock_cells =
        match updated_at with
        | Some at ->
            let age_span = Masc_tui_message_layout.span_text (max 0.0 (now -. at)) in
            [ { Masc_tui_keeper_axis_cell.text = Printf.sprintf "+%s +%d -%d" age_span added removed; tone = Quiet } ]
        | None -> []
      in
      let stale_cells =
        if source_invalidations > 0 then
          [ { Masc_tui_keeper_axis_cell.text = Printf.sprintf "stale ×%d" source_invalidations; tone = Attention } ]
        else []
      in
      gap_cells @ [ cell_of_lag lag ] @ clock_cells @ stale_cells
;;
