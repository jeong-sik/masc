let next ~current ~census =
  match current, census with
  | _, [] -> None
  | None, (first, _) :: _ -> Some first
  | Some current, census -> (
      let names = List.map fst census in
      match List.find_index (String.equal current) names with
      | None -> None
      | Some index -> List.nth_opt names (index + 1))
