type command =
  | Prepare of { operation_id:string; tab_id:int; extension_id:string;
      directory:string; program:string; arguments:Yojson.Safe.t }
  | Invoke of { operation_id:string; program:string; arguments:Yojson.Safe.t }
  | Release of string
type error = Not_started | Outcome_unknown
open Result.Syntax
let to_json = function
  | Prepare {operation_id;tab_id;extension_id;directory;program;arguments} ->
    `Assoc ["kind",`String "prepare";"operation_id",`String operation_id;"tab_id",`Int tab_id;
      "extension_id",`String extension_id;"directory",`String directory;"program",`String program;"arguments",arguments]
  | Invoke {operation_id;program;arguments} -> `Assoc ["kind",`String "invoke";
      "operation_id",`String operation_id;"program",`String program;"arguments",arguments]
  | Release operation_id -> `Assoc ["kind",`String "release";"operation_id",`String operation_id]
let of_json value =
  let* value = Lane_addon_action.canonical value |> Result.map_error (fun _ -> ()) in
  match value with
  | `Assoc fields ->
    let text key = match List.assoc_opt key fields with
      | Some (`String value) when value<>"" && not (String.contains value '\000') -> Ok value
      | Some _ | None -> Error () in
    let exact keys = if List.sort String.compare (List.map fst fields)=List.sort String.compare keys
      then Ok () else Error () in
    let arguments () = match List.assoc_opt "arguments" fields with
      | Some (`Assoc _ as value) -> Ok value | Some _ | None -> Error () in
    let* operation_id = text "operation_id" in
    let* _ = Browser_lane.client_id_of_string operation_id |> Result.map_error (fun _ -> ()) in
    let* kind = text "kind" in
    (match kind with
     | "prepare" ->
       let* ()=exact ["kind";"operation_id";"tab_id";"extension_id";"directory";"program";"arguments"] in
       let* tab_id=match List.assoc_opt "tab_id" fields with Some (`Int id) when id>=0 -> Ok id | Some _|None -> Error () in
       let* extension_id=text "extension_id" in
       let* ()=if String.length extension_id=32 && String.for_all (fun c -> c>='a' && c<='p') extension_id
         then Ok () else Error () in
       let* directory=text "directory" in
       let* ()=if Filename.is_relative directory then Error () else Ok () in
       let* program=text "program" in let* arguments=arguments () in
       Ok (Prepare {operation_id;tab_id;extension_id;directory;program;arguments})
     | "invoke" ->
       let* ()=exact ["kind";"operation_id";"program";"arguments"] in
       let* program=text "program" in let* arguments=arguments () in Ok (Invoke {operation_id;program;arguments})
     | "release" -> let* ()=exact ["kind";"operation_id"] in Ok (Release operation_id)
     | _ -> Error ())
  | _ -> Error ()
