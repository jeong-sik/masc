(* See .mli. *)

let render ~rows ~to_json table =
  let lines =
    Hashtbl.fold
      (fun key value lines ->
         let line =
           match Hashtbl.find_opt rows key with
           | Some (written, line) when written == value -> line
           | Some _ | None ->
             let line = Yojson.Safe.to_string (to_json value) ^ "\n" in
             Hashtbl.replace rows key (value, line);
             line
         in
         line :: lines)
      table
      []
  in
  Hashtbl.filter_map_inplace
    (fun key kept -> if Hashtbl.mem table key then Some kept else None)
    rows;
  String.concat "" (List.rev lines)
;;
