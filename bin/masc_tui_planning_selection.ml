type navigation =
  | List_cursor of int
  | Detail_goal of {
      goal_id : string;
      cursor : int;
    }

let fallback_cursor ~cursor ids =
  min (max 0 cursor) (max 0 (List.length ids - 1))

let reconcile ~current_ids ~next_ids ~current =
  match current with
  | List_cursor cursor ->
      let selected_id =
        if cursor < 0 then None else List.nth_opt current_ids cursor
      in
      (match Option.bind selected_id (fun id -> List.find_index (String.equal id) next_ids) with
       | Some next_cursor -> List_cursor next_cursor
       | None -> List_cursor (fallback_cursor ~cursor next_ids))
  | Detail_goal { goal_id; cursor } ->
      (match List.find_index (String.equal goal_id) next_ids with
       | Some next_cursor -> Detail_goal { goal_id; cursor = next_cursor }
       | None -> List_cursor (fallback_cursor ~cursor next_ids))
