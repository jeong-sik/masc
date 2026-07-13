(** Neutral literal-word projections from typed Shell IR. *)

open Masc_exec

let literal_words_of_simple (simple : Shell_ir.simple) =
  let rec collect acc = function
    | [] -> Some (List.rev acc)
    | Shell_ir.Lit (value, _) :: rest -> collect (value :: acc) rest
    | Shell_ir.Concat _ :: _ | Shell_ir.Var _ :: _ -> None
  in
  match collect [] simple.args with
  | None -> None
  | Some args -> Some (Exec_program.to_string simple.bin :: args)
;;

let flat_stage_words (ir : Shell_ir.t) : string list =
  let rec collect acc = function
    | Shell_ir.Simple simple ->
      (match literal_words_of_simple simple with
       | Some words -> words :: acc
       | None -> acc)
    | Shell_ir.Pipeline stages -> List.fold_left collect acc stages
  in
  List.rev (collect [] ir) |> List.concat
;;
