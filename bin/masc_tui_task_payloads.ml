type t = { source : Masc_domain.task list; values : Masc_domain.task list }
let empty = {source=[];values=[]}
let observe source = match source with [] -> empty | _ -> {source;values=source}
let values observation = observation.values

type comparison = { previous : t; current : t }
type preparation = Immediate of t | Compare of comparison
let prepare ~previous current =
  if previous.source==current.source then Immediate previous
  else match previous.values,current.values with
  | [],_ | _,[] -> Immediate current
  | _ -> Compare {previous;current}

module Ids = Map.Make (String)
let finish {previous;current} =
  let indexed=List.fold_left (fun indexed (task : Masc_domain.task) ->
    Ids.update task.id (function
      | None -> Some (Some task)
      | Some _ -> Some None) indexed) Ids.empty previous.values in
  let values=List.map (fun (task : Masc_domain.task) ->
    match Ids.find_opt task.id indexed with
    | Some (Some previous) when previous==task || Masc_domain.equal_task previous task -> previous
    | Some _ | None -> task) current.values in
  {source=current.source;values}
