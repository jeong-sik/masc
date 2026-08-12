type dynamic_tool_result =
  { success : bool
  ; content : string
  ; abort_turn : string option
  }

type dynamic_tool =
  { name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  ; call : call_id:string -> Yojson.Safe.t -> dynamic_tool_result
  }

let dynamic_tool_bytes tools =
  List.fold_left
    (fun acc tool ->
       acc
       + String.length tool.name
       + String.length tool.description
       + String.length (Yojson.Safe.to_string tool.input_schema))
    0
    tools
;;
