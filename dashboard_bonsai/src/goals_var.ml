(** Bonsai.Expert.Var holding the current goals tree response. *)

let var : Goals_types.response Bonsai.Expert.Var.t =
  Bonsai.Expert.Var.create Goals_types.fixture
;;
