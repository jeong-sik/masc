(* See .mli. *)

let render ~rows ~to_json table =
  let total_len, lines_rev =
    Hashtbl.fold
      (fun key value (total, lines) ->
         let line =
           match Hashtbl.find_opt rows key with
           | Some (written, line) when written == value -> line
           | Some _ | None ->
             let line = Yojson.Safe.to_string (to_json value) ^ "\n" in
             Hashtbl.replace rows key (value, line);
             line
         in
         total + String.length line, line :: lines)
      table
      (0, [])
  in
  (* Every live key in [table] is now present in [rows], so stale keys exist
     iff [rows] has more entries than [table]. *)
  if Hashtbl.length rows > Hashtbl.length table then
    Hashtbl.filter_map_inplace
      (fun key kept -> if Hashtbl.mem table key then Some kept else None)
      rows;
  if total_len = 0 then ""
  else begin
    let out = Bytes.create total_len in
    let rec blit dst = function
      | [] -> ()
      | line :: rest ->
        let len = String.length line in
        let start = dst - len in
        Bytes.blit_string line 0 out start len;
        blit start rest
    in
    blit total_len lines_rev;
    Bytes.unsafe_to_string out
  end
;;
