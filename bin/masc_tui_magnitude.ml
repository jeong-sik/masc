type band =
  | Leading
  | Ordinary
  | Below_even_share

(* Both comparisons are multiplied out rather than divided, so an entry sitting
   exactly on a boundary lands on the same side every time instead of on
   whichever side integer division rounded it to. *)
let band ~value ~total ~entries ~largest =
  if total <= 0 || entries < 2 || largest <= 0 || largest > total then Ordinary
    (* A distribution with no shape has nothing to point at. Where the largest
       entry is not even twice what an equal split would give it, the counts
       are all of a size and banding them says the opposite: three of the four
       goal phases here run 26, 26, 27, and marking three of them as leaders
       is emphasis with no reading behind it. *)
  else if largest * entries < total * 2 then Ordinary
  else if value * 2 >= largest then Leading
  else if value * entries < total then Below_even_share
  else Ordinary

let of_counts counts =
  let total = List.fold_left (fun sum (_, value) -> sum + value) 0 counts in
  let entries = List.length counts in
  let largest =
    List.fold_left (fun best (_, value) -> max best value) 0 counts
  in
  List.map
    (fun (label, value) ->
      (label, value, band ~value ~total ~entries ~largest))
    counts
