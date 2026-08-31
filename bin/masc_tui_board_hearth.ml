open Masc_tui_types

let vocabulary posts =
  let counts = Hashtbl.create 32 in
  List.iter
    (fun (post : board_post) ->
      match Option.map String.trim post.bp_hearth with
      | Some hearth when not (String.equal hearth "") ->
          Hashtbl.replace counts hearth
            (1 + Option.value (Hashtbl.find_opt counts hearth) ~default:0)
      | Some _ | None -> ())
    posts;
  Hashtbl.fold (fun hearth count acc -> (hearth, count) :: acc) counts []
  |> List.sort (fun (left_hearth, left) (right_hearth, right) ->
         match Int.compare right left with
         | 0 -> String.compare left_hearth right_hearth
         | order -> order)
  |> List.map fst

let next ~current ~vocabulary =
  match current, vocabulary with
  | _, [] -> None
  | None, first :: _ -> Some first
  | Some current, vocabulary -> (
      match List.find_index (String.equal current) vocabulary with
      | None -> None
      | Some index -> List.nth_opt vocabulary (index + 1))
