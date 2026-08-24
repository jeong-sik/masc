type navigation =
  | List_cursor of int
  | Detail_keeper of {
      keeper_name : string;
      cursor : int;
    }
  | Logs_keeper of {
      keeper_name : string;
      cursor : int;
    }
  | Calls_keeper of {
      keeper_name : string;
      cursor : int;
    }
  | Message_keeper of {
      keeper_name : string;
      cursor : int;
    }

type message_switch =
  | No_alternative
  | Switch_to of {
      keeper_name : string;
      cursor : int;
    }

let fallback_cursor ~cursor ids =
  min (max 0 cursor) (max 0 (List.length ids - 1))

let find_index name ids = List.find_index (String.equal name) ids

let next_message_target ~current_keeper ~keeper_ids =
  let rec locate cursor = function
    | [] -> None
    | keeper_name :: remaining ->
        if String.equal current_keeper keeper_name then Some (cursor, remaining)
        else locate (cursor + 1) remaining
  in
  match keeper_ids with
  | [] -> No_alternative
  | [ keeper_name ] ->
      if String.equal current_keeper keeper_name then No_alternative
      else Switch_to { keeper_name; cursor = 0 }
  | first_keeper :: _ -> (
      match locate 0 keeper_ids with
      | None -> Switch_to { keeper_name = first_keeper; cursor = 0 }
      | Some (cursor, next_keeper :: _) ->
          Switch_to { keeper_name = next_keeper; cursor = cursor + 1 }
      | Some (_, []) -> Switch_to { keeper_name = first_keeper; cursor = 0 })

let reconcile ~current_ids ~next_ids ~current =
  match current with
  | List_cursor cursor ->
      let selected_id =
        if cursor < 0 then None else List.nth_opt current_ids cursor
      in
      (match Option.bind selected_id (fun id -> find_index id next_ids) with
       | Some next_cursor -> List_cursor next_cursor
       | None -> List_cursor (fallback_cursor ~cursor next_ids))
  | Detail_keeper { keeper_name; cursor } ->
      (match find_index keeper_name next_ids with
       | Some next_cursor -> Detail_keeper { keeper_name; cursor = next_cursor }
       | None -> List_cursor (fallback_cursor ~cursor next_ids))
  | Logs_keeper { keeper_name; cursor } ->
      (match find_index keeper_name next_ids with
       | Some next_cursor -> Logs_keeper { keeper_name; cursor = next_cursor }
       | None -> List_cursor (fallback_cursor ~cursor next_ids))
  | Calls_keeper { keeper_name; cursor } ->
      (match find_index keeper_name next_ids with
       | Some next_cursor -> Calls_keeper { keeper_name; cursor = next_cursor }
       | None -> List_cursor (fallback_cursor ~cursor next_ids))
  | Message_keeper { keeper_name; cursor } ->
      let cursor =
        match find_index keeper_name next_ids with
        | Some next_cursor -> next_cursor
        | None -> fallback_cursor ~cursor next_ids
      in
      Message_keeper { keeper_name; cursor }
