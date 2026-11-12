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
      ; pass_end : Tui_decode_memory_health.memory_librarian_pass_end option
      ; admission_wait : Masc.Keeper_librarian_pending.admission option
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
              ; pass_end = k.mkh_librarian.mlh_state
              ; admission_wait = k.mkh_librarian.mlh_admission_wait
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

(* A value the row came without draws the age ladder's mark, so one mark
   says "not measured" on every memory cell. *)
let unknown_cell =
  { Masc_tui_keeper_axis_cell.text = "mem " ^ Masc_tui_keeper_age_ladder.unmeasured_mark
  ; tone = Quiet
  }
;;

let refused_cell = { Masc_tui_keeper_axis_cell.text = "mem !"; tone = Failure }

let lag_tone turns =
  if turns > 0 then Masc_tui_keeper_axis_cell.Attention else Masc_tui_keeper_axis_cell.Quiet
;;

let cell_of_lag = function
  | Lag n -> { Masc_tui_keeper_axis_cell.text = Printf.sprintf "lag %d" n; tone = lag_tone n }
  | Lag_unmeasured ->
      { Masc_tui_keeper_axis_cell.text = "lag " ^ Masc_tui_keeper_age_ladder.unmeasured_mark
      ; tone = Quiet
      }
;;

let lag_cell = function
  | Unknown -> Some unknown_cell
  | No_row -> None
  | Refused _ -> Some refused_cell
  | Row { lag; _ } -> Some (cell_of_lag lag)
;;

let gap_cells = function
  | Gap { first_atom; past_last_atom } ->
      let count = past_last_atom - first_atom in
      [ { Masc_tui_keeper_axis_cell.text = Printf.sprintf "gap %d" count; tone = Attention } ]
  | Gap_unmeasured ->
      [ { Masc_tui_keeper_axis_cell.text = "gap " ^ Masc_tui_keeper_age_ladder.unmeasured_mark
        ; tone = Attention
        } ]
  | No_gap -> []
;;

let stale_cells source_invalidations =
  if source_invalidations > 0 then
    [ { Masc_tui_keeper_axis_cell.text = Printf.sprintf "stale ×%d" source_invalidations
      ; tone = Attention
      } ]
  else []
;;

let span_since ~now at = Masc_tui_message_layout.span_text (max 0.0 (now -. at))

let cells ~now = function
  | Unknown -> [ unknown_cell ]
  | No_row -> []
  | Refused _ -> [ refused_cell ]
  | Row { lag; gap; updated_at; added; removed; source_invalidations; _ } ->
      let clock_cells =
        match updated_at with
        | Some at ->
            [ { Masc_tui_keeper_axis_cell.text =
                  Printf.sprintf "+%s +%d -%d" (span_since ~now at) added removed
              ; tone = Quiet
              } ]
        | None -> []
      in
      gap_cells gap @ [ cell_of_lag lag ] @ clock_cells @ stale_cells source_invalidations
;;

type 'a field =
  | Measured of 'a
  | Unmeasured
  | No_snapshot
  | Snapshot_unknown
  | Row_absent
  | Row_refused

let pass_end = function
  | Unknown -> Snapshot_unknown
  | No_row -> Row_absent
  | Refused _ -> Row_refused
  | Row { pass_end = Some ending; _ } -> Measured ending
  | Row { pass_end = None; _ } -> Unmeasured
;;

let updated_at = function
  | Unknown -> Snapshot_unknown
  | No_row -> Row_absent
  | Refused _ -> Row_refused
  | Row { updated_at = Some at; _ } -> Measured at
  | Row { updated_at = None; _ } -> No_snapshot
;;

let digest_at = function
  | Unknown -> Snapshot_unknown
  | No_row -> Row_absent
  | Refused _ -> Row_refused
  | Row { digest_at = Some at; _ } -> Measured at
  | Row { digest_at = None; _ } -> Unmeasured
;;

let age_bins = function
  | Unknown -> Snapshot_unknown
  | No_row -> Row_absent
  | Refused _ -> Row_refused
  | Row { age_bins = Some bins; _ } -> Measured bins
  | Row { age_bins = None; _ } -> Unmeasured
;;

let peak_lag readings =
  List.fold_left
    (fun peak -> function
      | Row { lag = Lag turns; _ } -> max peak turns
      | Row { lag = Lag_unmeasured; _ } | Unknown | No_row | Refused _ -> peak)
    0 readings
;;

let no_memory_cell = { Masc_tui_keeper_axis_cell.text = Masc_tui_theme.Glyph.no_value; tone = Quiet }

let field_cell ~unmeasured ~measured = function
  | Measured value -> measured value
  | Unmeasured -> { Masc_tui_keeper_axis_cell.text = unmeasured; tone = Quiet }
  | No_snapshot | Row_absent -> no_memory_cell
  | Snapshot_unknown -> unknown_cell
  | Row_refused -> refused_cell
;;

(* What the operator reads for how the last Librarian pass ended, on the
   Memory pane and in the memory view's ● column. The wire words name code
   paths ("not_committed"); these say what happened, in a word that fits the
   column. *)
let pass_word ending = Masc_tui_types.memory_pass_text ~ko:false ending
;;

(* A pass that broke is a failure. A pass that saved nothing, or a librarian
   with no lane to run on, keeps the Keeper's memory where it was. *)
let pass_tone = function
  | Tui_decode_memory_health.Pass_stopped _ | Tui_decode_memory_health.Pass_raised _ ->
      Masc_tui_keeper_axis_cell.Failure
  | Tui_decode_memory_health.Pass_not_committed
  | Tui_decode_memory_health.Pass_lane_unconfigured -> Masc_tui_keeper_axis_cell.Attention
  | Tui_decode_memory_health.Pass_pending pending ->
    if Masc.Keeper_librarian_pending.needs_attention pending
    then Masc_tui_keeper_axis_cell.Attention else Masc_tui_keeper_axis_cell.Quiet
  | Tui_decode_memory_health.Pass_off | Tui_decode_memory_health.Pass_drained
  | Tui_decode_memory_health.Pass_yielded_to_waiting_unit -> Masc_tui_keeper_axis_cell.Quiet
;;

let pass_cell reading =
  let durable = field_cell ~unmeasured:Masc_tui_keeper_age_ladder.unmeasured_mark
    ~measured:(fun ending -> { Masc_tui_keeper_axis_cell.text = pass_word ending; tone = pass_tone ending })
    (pass_end reading) in
  match reading with
  | Row { admission_wait = Some admission; _ } ->
    let pending = Tui_decode_memory_health.Pass_pending
      (Masc.Keeper_librarian_pending.admission_pending admission) in
    (match durable.tone with
     | Failure -> durable
     | Attention when pass_tone pending = Masc_tui_keeper_axis_cell.Quiet -> durable
     | Quiet | Attention ->
       let text = match admission with
         | Masc.Keeper_librarian_pending.Admission_waiting _ -> pass_word pending ^ " (admit)"
         | Admission_failed _ -> Masc_tui_types.memory_admission_text ~ko:false admission in
       { Masc_tui_keeper_axis_cell.text; tone = pass_tone pending })
  | Row { admission_wait = None; _ } | Unknown | No_row | Refused _ -> durable
;;

let updated_cell ~now reading =
  field_cell ~unmeasured:Masc_tui_keeper_age_ladder.unmeasured_mark
    ~measured:(fun at -> { Masc_tui_keeper_axis_cell.text = span_since ~now at; tone = Quiet })
    (updated_at reading)
;;

let fact_ages_cell reading =
  field_cell ~unmeasured:Masc_tui_keeper_age_ladder.unmeasured_mark
    ~measured:(fun bins ->
      { Masc_tui_keeper_axis_cell.text = Masc_tui_keeper_age_ladder.strip bins; tone = Quiet })
    (age_bins reading)
;;
