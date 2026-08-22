type selection_source =
  | List_cursor
  | Detail_post of string

let fallback_cursor ~cursor ids =
  min (max 0 cursor) (max 0 (List.length ids - 1))

let reconcile_cursor ~current_ids ~cursor ~source ~next_ids =
  let selected_id =
    match source with
    | Detail_post id -> Some id
    | List_cursor -> if cursor < 0 then None else List.nth_opt current_ids cursor
  in
  match selected_id with
  | Some id ->
      (match List.find_index (String.equal id) next_ids with
       | Some index -> index
       | None -> fallback_cursor ~cursor next_ids)
  | None -> fallback_cursor ~cursor next_ids
