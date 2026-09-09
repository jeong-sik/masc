(** Neutral literal-word projections from typed Shell IR. *)

open Masc_exec

let literal_words_of_simple (simple : Shell_ir.simple) =
  let rec collect acc = function
    | [] -> Some (List.rev acc)
    | Shell_ir.Lit (value, _) :: rest -> collect (value :: acc) rest
    | Shell_ir.Concat _ :: _ | Shell_ir.Var _ :: _ | Shell_ir.Subst _ :: _ -> None
  in
  match collect [] simple.args with
  | None -> None
  | Some args -> Some (Exec_program.to_string simple.bin :: args)
;;

let flat_stage_words (ir : Shell_ir.t) : string list =
  let rec collect acc = function
    | Shell_ir.Simple simple ->
      let acc =
        match literal_words_of_simple simple with
        | Some words -> words :: acc
        | None -> acc
      in
      (* A substitution's children run real commands; log sanitizing must
         see their words too, even though the stage holding them is not
         literal. *)
      List.fold_left
        collect
        acc
        (List.concat_map
           Shell_ir.subst_children_of_arg
           (simple.Shell_ir.args @ List.map snd simple.Shell_ir.env))
    | Shell_ir.Pipeline stages -> List.fold_left collect acc stages
    | Shell_ir.Sequence { head; tail } ->
      List.fold_left
        (fun acc (_connector, part) -> collect acc part)
        (collect acc head)
        tail
  in
  List.rev (collect [] ir) |> List.concat
;;
