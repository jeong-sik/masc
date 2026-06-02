(** Tier F4 — Bonsai.Expert.Var holders for the gallery filter.

    Three independent filter dimensions; each operator-set field is
    set independently so toggling one does not clobber the others.

    [None] for kind/created_by means "any value matches" (no filter
    on that dimension). [""] for search means "no text filter". *)

let kind_var : string option Bonsai.Expert.Var.t =
  Bonsai.Expert.Var.create None
;;

let created_by_var : string option Bonsai.Expert.Var.t =
  Bonsai.Expert.Var.create None
;;

let search_var : string Bonsai.Expert.Var.t =
  Bonsai.Expert.Var.create ""
;;

let clear_all () : unit =
  Bonsai.Expert.Var.set kind_var None;
  Bonsai.Expert.Var.set created_by_var None;
  Bonsai.Expert.Var.set search_var ""
;;
