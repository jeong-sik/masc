(** Effect_evidence -- Source-path evidence at the Mode_enforcer boundary.

    @since SafeAuto source-path boundary *)

type t = {
  source_path : string option;
  source_line : int option;
}

let empty = { source_path = None; source_line = None }

let is_populated (ev : t) = ev.source_path <> None

let of_json (json : Yojson.Safe.t) : t =
  let open Yojson.Safe.Util in
  try
    let source_path =
      match json |> member "source_path" with
      | `String s -> Some s
      | _ -> None
    in
    let source_line =
      match json |> member "source_line" with
      | `Int n -> Some n
      | _ -> None
    in
    { source_path; source_line }
  with Eio.Cancel.Cancelled _ as e -> raise e
     | _exn ->
       (* JSON shape mismatch (e.g. wrong type for a field) -- treat as no
          evidence rather than propagating a parse failure. Source-path fields
          are optional enrichment on OAS effects evidence; callers decide
          whether absence is a blocking gap for their proof surface. *)
       empty

let of_json_list (json : Yojson.Safe.t) : (t list, string) result =
  match json with
  | `List items -> Ok (List.map of_json items)
  | _ -> Error "expected JSON array of effect evidence records"

let any_source_path_present events =
  List.exists is_populated events

let check_any_source_path_present events =
  if any_source_path_present events then Ok ()
  else Error "effects evidence is missing source_path at Mode_enforcer boundary"

let to_json_fields (ev : t) : (string * Yojson.Safe.t) list =
  let fields = [] in
  let fields =
    match ev.source_path with
    | Some p -> ("source_path", `String p) :: fields
    | None -> fields
  in
  let fields =
    match ev.source_line with
    | Some n -> ("source_line", `Int n) :: fields
    | None -> fields
  in
  List.sort (fun (a, _) (b, _) -> String.compare a b) fields
