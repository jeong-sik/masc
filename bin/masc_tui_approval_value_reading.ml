type t =
  { scope : unit ref
  ; gate_id : string
  ; encoded_input : string
  ; mutable fields : (string * Yojson.Safe.t) list
  ; restore_scroll : int
  }

let encode fields = Yojson.Safe.to_string (`Assoc fields)

let has_strings fields =
  List.exists
    (fun (_, value) ->
      match value with
      | `String _ -> true
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ -> false)
    fields

let create ~scope ~gate_id ~fields ~restore_scroll =
  { scope; gate_id; encoded_input = encode fields; fields; restore_scroll }

let matches reading ~scope ~gate_id ~fields =
  if reading.scope != scope || not (String.equal reading.gate_id gate_id) then false
  else if reading.fields == fields then true
  else if String.equal reading.encoded_input (encode fields) then begin
    (* A successful poll may allocate the same immutable input again. Keep its
       identity so subsequent frames do not serialize the whole input. *)
    reading.fields <- fields;
    true
  end else false

let restore_scroll reading = reading.restore_scroll
