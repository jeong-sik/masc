type t =
  { seq : int
  ; revision : int
  ; at : float
  ; line_at : int
  ; source : Keeper_memory_os_current_types.source
  ; added : Keeper_memory_os_types.fact list
  ; removed : (Keeper_memory_os_types.fact * Librarian_effects.removal) list
  }

let of_commit ~line_at (commit : Librarian_log.commit) =
  { seq = commit.seq; revision = commit.revision; at = commit.at; line_at
  ; source = Librarian_log.memory_source commit.cause
  ; added = commit.effects.added; removed = commit.effects.removed }
;;

let to_json c =
  let removed (fact, removal) =
    `Assoc [ "fact", Keeper_memory_os_types.fact_to_json fact
           ; "removal", Librarian_log_codec.removal_to_json removal ]
  in
  `Assoc [ "seq", `Int c.seq; "revision", `Int c.revision; "at", `Float c.at
         ; "line_at", `Int c.line_at; "source", Keeper_memory_os_snapshot_codec.source_to_json c.source
         ; "added", `List (List.map Keeper_memory_os_types.fact_to_json c.added)
         ; "removed", `List (List.map removed c.removed) ]
;;

let fingerprint c =
  Digestif.SHA256.digest_string (Yojson.Safe.to_string (to_json { c with line_at = 0 }))
  |> Digestif.SHA256.to_raw_string
;;

let same_event a b =
  Yojson.Safe.equal (to_json { a with line_at = 0 }) (to_json { b with line_at = 0 })
;;

let of_json = function
  | `Assoc fields ->
    let open Keeper_memory_os_types in
    let open Result.Syntax in
    let* () = exact_field_names_result [ "seq"; "revision"; "at"; "line_at"; "source"; "added"; "removed" ] fields in
    let* seq = wire_int_field "seq" fields and* revision = wire_int_field "revision" fields in
    let* at = wire_number_field "at" fields and* line_at = wire_int_field "line_at" fields in
    let* raw = wire_json_field "source" fields in
    let* source = Keeper_memory_os_snapshot_codec.source_of_json raw in
    let list key decode =
      let* items = wire_list_field key fields in
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | item :: rest -> let* value = decode item in loop (value :: acc) rest
      in
      loop [] items
    in
    let* added = list "added" fact_of_json in
    let* removed = list "removed" Librarian_log_codec.removed_of_json in
    if seq < 1 then wire_fail [ Wire_field "seq" ] Not_positive
    else if revision < 0 then wire_fail [ Wire_field "revision" ] Negative
    else if line_at < 0 then wire_fail [ Wire_field "line_at" ] Negative
    else if not (Float.is_finite at) then wire_fail [ Wire_field "at" ] Not_finite
    else Ok { seq; revision; at; line_at; source; added; removed }
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Keeper_memory_os_types.wire_here Expected_object
;;
