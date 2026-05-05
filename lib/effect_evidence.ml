(** Effect_evidence — Source-path evidence at the Mode_enforcer boundary.

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
  with Eio.Cancel.Cancelled _ as e -> raise e | _exn -> empty

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
