(* See the .mli for why this axis exists and why it is static. *)

module String_set = Set.Make (String)

type outcome =
  { kept : Keeper_identity_tools.offered_tool list
  ; unnamed : string list
  }

let apply ~allow (offered : Keeper_identity_tools.offered_tool list) =
  match allow with
  | None -> { kept = offered; unnamed = [] }
  | Some names ->
    let wanted = List.to_seq names |> String_set.of_seq in
    let kept =
      List.filter
        (fun (tool : Keeper_identity_tools.offered_tool) ->
           String_set.mem tool.Keeper_identity_tools.schema.name wanted)
        offered
    in
    let held =
      List.to_seq kept
      |> Seq.map (fun (tool : Keeper_identity_tools.offered_tool) ->
           tool.Keeper_identity_tools.schema.name)
      |> String_set.of_seq
    in
    { kept; unnamed = String_set.diff wanted held |> String_set.elements }
;;
