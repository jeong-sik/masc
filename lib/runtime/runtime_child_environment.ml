let entry_name entry =
  match String.index_opt entry '=' with
  | Some index -> String.sub entry 0 index
  | None -> entry
;;

(* A child that sees a name twice reads the first ([getenv] walks the array
   from its start), so an inherited entry would win over one appended after
   it. *)
let set entries environment =
  let names = List.map fst entries in
  let inherited =
    Array.to_list environment
    |> List.filter (fun entry -> not (List.mem (entry_name entry) names))
  in
  Array.of_list (inherited @ List.map (fun (name, value) -> name ^ "=" ^ value) entries)
;;
