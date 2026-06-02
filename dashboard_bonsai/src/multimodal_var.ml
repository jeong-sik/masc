(** Bonsai.Expert.Var holding the current multimodal list response. *)

let var : Multimodal_types.response Bonsai.Expert.Var.t =
  Bonsai.Expert.Var.create Multimodal_types.empty_response
;;
