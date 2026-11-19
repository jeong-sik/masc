type 'line too_tall =
  | Cut_with of 'line
  | Fold

let default_max_rows = 12

let fit_tallest ?cap ~budget ~tallest ~too_tall ~blank shown =
  let budget = Int.max 0 budget in
  let tallest = Int.max tallest (List.length shown) in
  let padded height lines =
    lines @ List.init (Int.max 0 (height - List.length lines)) (fun _ -> blank)
  in
  match too_tall with
  | Fold ->
      let ceiling =
        match cap with
        | Some limit -> Int.max 0 (Int.min budget limit)
        | None -> budget
      in
      if tallest <= ceiling then padded tallest shown else []
  | Cut_with overflow ->
      let limit = Option.value ~default:default_max_rows cap in
      let ceiling = Int.max 0 (Int.min budget limit) in
      let height = Int.min ceiling tallest in
      if List.length shown <= height then padded height shown
      else if height >= 2 then List.take (height - 1) shown @ [ overflow ]
      else List.take height shown

let fit ?cap ~budget ~rows ~detail ~too_tall ~blank shown =
  let tallest =
    List.fold_left (fun tallest row -> Int.max tallest (List.length (detail row))) 0 rows
  in
  fit_tallest ?cap ~budget ~tallest ~too_tall ~blank shown
