type t = {
  ok : bool;
  status : Unix.process_status;
  execution_time_ms : int;
  output : string option;
  stderr : string option;
  rest : (string * Yojson.Safe.t) list;
}

(* The members this reads into fields of its own. [typed] is required by the
   schema and says nothing a reader acts on, so it stays with the rest. *)
let read_members = [ "ok"; "status"; "execution_time_ms"; "output"; "stderr" ]

let of_result text =
  let ( let* ) = Option.bind in
  let* fields =
    match Yojson.Safe.from_string text with
    | exception Yojson.Json_error _ -> None
    | `Assoc fields -> Some fields
    | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
  in
  let member name = List.assoc_opt name fields in
  let string_member name =
    match member name with Some (`String value) -> Some value | Some _ | None -> None
  in
  let* ok = match member "ok" with Some (`Bool ok) -> Some ok | Some _ | None -> None in
  let* status =
    match Option.map Masc.Exec_core.process_status_of_json (member "status") with
    | Some (Ok status) -> Some status
    | Some (Error _) | None -> None
  in
  let* () = match member "typed" with Some (`Bool _) -> Some () | Some _ | None -> None in
  let* execution_time_ms =
    match member "execution_time_ms" with
    | Some (`Int ms) -> Some ms
    | Some _ | None -> None
  in
  let stderr = string_member "stderr" in
  (* The exit report writes a failing command's stderr under both names.
     Equal, they are one field; different, [error] is its own fact and
     stays. *)
  let error_repeats_stderr =
    match stderr, member "error" with
    | Some stderr, Some (`String error) -> String.equal stderr error
    | Some _, Some _ | None, _ | Some _, None -> false
  in
  let rest =
    List.filter
      (fun (name, _) ->
        (not (List.mem name read_members))
        && not (String.equal name "error" && error_repeats_stderr))
      fields
  in
  Some { ok; status; execution_time_ms; output = string_member "output"; stderr; rest }

let status_text t =
  let ended =
    match t.status with
    | Unix.WEXITED code -> Printf.sprintf "exit %d" code
    | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
    | Unix.WSTOPPED signal -> Printf.sprintf "stopped %d" signal
  in
  Printf.sprintf "%s \xc2\xb7 %d ms" ended t.execution_time_ms

let rec flatten path (json : Yojson.Safe.t) =
  match json with
  | `Assoc [] -> [ (path, "{}") ]
  | `Assoc fields ->
      List.concat_map (fun (name, value) -> flatten (path ^ "." ^ name) value) fields
  | `String value -> [ (path, value) ]
  | `Null -> [ (path, "null") ]
  | (`Bool _ | `Float _ | `Int _ | `Intlit _ | `List _) as scalar ->
      [ (path, Yojson.Safe.to_string scalar) ]

let rest_text t =
  match
    List.concat_map (fun (name, value) -> flatten name value) t.rest
  with
  | [] -> None
  | pairs ->
      Some
        (String.concat " \xc2\xb7 "
           (List.map (fun (path, value) -> path ^ "=" ^ value) pairs))
