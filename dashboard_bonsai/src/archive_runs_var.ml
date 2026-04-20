(** Bonsai.Expert.Var holding the current autoresearch loops response. *)

let var : Archive_runs_types.response Bonsai.Expert.Var.t =
  Bonsai.Expert.Var.create Archive_runs_types.fixture
;;
