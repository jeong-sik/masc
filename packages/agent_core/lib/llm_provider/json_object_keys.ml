(* JSON does not forbid an object from binding the same key twice, and Yojson
   keeps both bindings in the assoc list while [Yojson.Safe.Util.member]
   answers with the first. A payload can therefore be read one way by the code
   that uses it and refused outright by a strict encoder downstream -- which is
   how a duplicate key in a tool payload failed whole keeper turns after the
   tool had already run (#31677, #31701, #32609).

   Resolving the ambiguity is a boundary job, and both boundaries -- the
   arguments a provider sends in and the payload a tool sends back -- need the
   same answer, so the rule lives here rather than being spelled twice.

   The FIRST binding wins. That is the one [member] already reads, so nothing
   downstream changes value; only the repeats go away. *)
let rec deduplicate json =
  match json with
  | `Assoc fields ->
    let _bound, dropped, rev_fields =
      List.fold_left
        (fun (bound, dropped, rev_fields) (name, value) ->
          if List.mem name bound
          then bound, name :: dropped, rev_fields
          else (
            let value, nested = deduplicate value in
            ( name :: bound
            , List.rev_append nested dropped
            , (name, value) :: rev_fields )))
        ([], [], [])
        fields
    in
    `Assoc (List.rev rev_fields), List.rev dropped
  | `List values ->
    let dropped, rev_values =
      List.fold_left
        (fun (dropped, rev_values) value ->
          let value, nested = deduplicate value in
          List.rev_append nested dropped, value :: rev_values)
        ([], [])
        values
    in
    `List (List.rev rev_values), List.rev dropped
  | (`String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null) as leaf ->
    leaf, []
;;
