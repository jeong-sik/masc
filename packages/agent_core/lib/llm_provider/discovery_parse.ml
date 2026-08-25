(* See discovery_parse.mli for module rationale. *)

type model_info =
  { id : string
  ; owned_by : string
  }

type server_props =
  { total_slots : int
  ; ctx_size : int
  ; model : string
  }

type slot_status =
  { total : int
  ; busy : int
  ; idle : int
  }

let field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let parse_models json =
  let parse_model index = function
    | `Assoc _ as item ->
      (match field "id" item, field "owned_by" item with
       | Some (`String id), Some (`String owned_by)
         when String.trim id <> "" && String.trim owned_by <> "" -> Ok { id; owned_by }
       | Some (`String id), _ when String.trim id = "" ->
         Error (Printf.sprintf "data[%d].id must be non-empty" index)
       | Some (`String _), Some (`String _) ->
         Error (Printf.sprintf "data[%d].owned_by must be non-empty" index)
       | Some (`String _), Some _ ->
         Error (Printf.sprintf "data[%d].owned_by must be a string" index)
       | Some (`String _), None ->
         Error (Printf.sprintf "data[%d].owned_by is missing" index)
       | Some _, _ -> Error (Printf.sprintf "data[%d].id must be a string" index)
       | None, _ -> Error (Printf.sprintf "data[%d].id is missing" index))
    | _ -> Error (Printf.sprintf "data[%d] must be a JSON object" index)
  in
  match field "data" json with
  | Some (`List items) ->
    let rec loop index acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        (match parse_model index item with
         | Ok model -> loop (index + 1) (model :: acc) rest
         | Error _ as error -> error)
    in
    loop 0 [] items
  | Some _ -> Error "data must be a JSON list"
  | None -> Error "response must be a JSON object with a data field"
;;

let parse_props json =
  match field "total_slots" json, field "default_generation_settings" json with
  | Some (`Int total_slots), Some (`Assoc _ as settings) when total_slots > 0 ->
    (match field "n_ctx" settings, field "model" settings with
     | Some (`Int ctx_size), Some (`String model)
       when ctx_size > 0 && String.trim model <> "" -> Ok { total_slots; ctx_size; model }
     | Some (`Int ctx_size), _ when ctx_size <= 0 -> Error "n_ctx must be positive"
     | Some (`Int _), Some (`String _) -> Error "model must be non-empty"
     | Some (`Int _), Some _ -> Error "model must be a string"
     | Some (`Int _), None -> Error "model is missing"
     | Some _, _ -> Error "n_ctx must be an integer"
     | None, _ -> Error "n_ctx is missing")
  | Some (`Int total_slots), _ when total_slots <= 0 ->
    Error "total_slots must be positive"
  | Some (`Int _), Some _ -> Error "default_generation_settings must be an object"
  | Some (`Int _), None -> Error "default_generation_settings is missing"
  | Some _, _ -> Error "total_slots must be an integer"
  | None, _ -> Error "total_slots is missing"
;;

let parse_slots json =
  let parse_busy index = function
    | `Assoc _ as slot ->
      (match field "is_processing" slot with
       | Some (`Bool processing) -> Ok processing
       | Some _ ->
         Error (Printf.sprintf "slots[%d].is_processing must be a boolean" index)
       | None -> Error (Printf.sprintf "slots[%d].is_processing is missing" index))
    | _ -> Error (Printf.sprintf "slots[%d] must be a JSON object" index)
  in
  match json with
  | `List items ->
    let rec loop index busy = function
      | [] ->
        let total = index in
        Ok { total; busy; idle = total - busy }
      | item :: rest ->
        (match parse_busy index item with
         | Ok is_busy -> loop (index + 1) (if is_busy then busy + 1 else busy) rest
         | Error _ as error -> error)
    in
    loop 0 0 items
  | _ -> Error "slots response must be a JSON list"
;;
