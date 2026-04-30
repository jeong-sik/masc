(** Tier F2-ux — Bonsai.Expert.Var holders for the detail panel.

    Three independent vars; each parallel fetch ([/get] + [/provenance])
    writes only its own slot. The view reads all three reactively via
    [Bonsai.Expert.Var.value].

    Detail and provenance are now [_ fetch_state] (Idle/Loading/Loaded/
    NotFound/Error) so the panel can render distinct UI for each phase
    instead of collapsing all failure modes into a perpetual loading
    spinner. *)

let selected_id_var : string option Bonsai.Expert.Var.t =
  Bonsai.Expert.Var.create None
;;

let detail_var
  : Multimodal_detail_types.detail Multimodal_detail_types.fetch_state
      Bonsai.Expert.Var.t
  =
  Bonsai.Expert.Var.create Multimodal_detail_types.Idle
;;

let provenance_var
  : Multimodal_detail_types.provenance Multimodal_detail_types.fetch_state
      Bonsai.Expert.Var.t
  =
  Bonsai.Expert.Var.create Multimodal_detail_types.Idle
;;
