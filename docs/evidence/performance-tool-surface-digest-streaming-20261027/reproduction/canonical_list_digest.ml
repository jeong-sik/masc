let iter_canonical_chunks ~to_json rows emit =
  (* 256 is Yojson.Safe.to_string's existing default initial buffer size.
     The buffer belongs to this invocation; Buffer.contents still copies one
     immutable row string, and to_string clears the buffer before/after use. *)
  let buffer = Buffer.create 256 in
  let emit_row row =
    to_json row
    |> Yojson.Safe.sort
    |> Yojson.Safe.to_string ~buf:buffer
    |> emit
  in
  let rec emit_rows = function
    | [] -> ()
    | [ row ] -> emit_row row
    | row :: rest ->
      emit_row row;
      emit ",";
      emit_rows rest
  in
  emit "[";
  emit_rows rows;
  emit "]"
;;

let digest ~to_json rows =
  Digestif.SHA256.digesti_string (iter_canonical_chunks ~to_json rows)
;;
