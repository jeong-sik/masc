(** Tier F2 — Bonsai.Expert.Var holders for the detail panel.

    Three independent vars instead of one merged record so each
    parallel fetch ([/get] + [/provenance]) writes only its own slot
    without needing a synchronous peek of the other slot. The view
    reads all three reactively via [Bonsai.Expert.Var.value]. *)

let selected_id_var : string option Bonsai.Expert.Var.t =
  Bonsai.Expert.Var.create None
;;

let detail_var : Multimodal_detail_types.detail option Bonsai.Expert.Var.t =
  Bonsai.Expert.Var.create None
;;

let provenance_var
  : Multimodal_detail_types.provenance option Bonsai.Expert.Var.t
  =
  Bonsai.Expert.Var.create None
;;
