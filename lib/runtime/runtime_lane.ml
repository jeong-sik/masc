(** Runtime lane — ordered list of candidate runtime ids for keeper turn routing. *)

type t =
  { id : string
  ; candidates : string list
  ; default_effort : Llm_provider.Reasoning_effort.t option
  ; candidate_efforts : (string * Llm_provider.Reasoning_effort.t option) list
  }

let make ?default_effort ?(candidate_efforts = []) ~id candidates =
  { id; candidates; default_effort; candidate_efforts }
;;

let id t = t.id
let ordered_candidates t = t.candidates
let default_effort t = t.default_effort

let effort_for_candidate t runtime_id =
  match List.assoc_opt runtime_id t.candidate_efforts with
  | Some (Some _ as explicit) -> explicit
  | Some None | None -> t.default_effort
;;
