type code =
  | Activity_disabled
  | Activity_unobserved
  | Workspace_precondition_failed
  | Worker_unavailable
  | Outcome_unknown
[@@deriving enumerate]

let code_to_wire = function
  | Activity_disabled -> "activity_disabled"
  | Activity_unobserved -> "activity_unobserved"
  | Workspace_precondition_failed -> "workspace_precondition_failed"
  | Worker_unavailable -> "worker_unavailable"
  | Outcome_unknown -> "outcome_unknown"
;;

let code_of_wire wire =
  List.find_opt (fun code -> String.equal (code_to_wire code) wire) all_of_code
;;

type refusal = { code : code option; message : string option }

let encode ?code message : Yojson.Safe.t =
  let code = match code with
    | None -> []
    | Some code -> [ "code", `String (code_to_wire code) ] in
  `Assoc (code @ [ "ok", `Bool false; "message", `String message ])
;;

open Result.Syntax

let decode : Yojson.Safe.t -> (refusal, string) result = function
  | `Assoc fields ->
    let names = List.map fst fields in
    if List.length names <> List.length (List.sort_uniq String.compare names)
    then Error "refusal has repeated fields"
    else (
      match List.assoc_opt "ok" fields with
      | Some (`Bool false) ->
        let* code =
          match List.assoc_opt "code" fields with
          | None -> Ok None
          | Some (`String wire) ->
            (match code_of_wire wire with
             | Some code -> Ok (Some code)
             | None -> Error (Printf.sprintf "refusal code %S is not known" wire))
          | Some _ -> Error "refusal code must be a string" in
        let* message =
          match List.assoc_opt "message" fields with
          | None -> Ok None
          | Some (`String message) -> Ok (Some message)
          | Some _ -> Error "refusal message must be a string" in
        Ok { code; message }
      | Some _ | None -> Error "body is not a refusal (ok=false is required)")
  | _ -> Error "refusal body must be an object"
;;

type pixel_reference = { revision : string; width : int; height : int }
type pixel_response = Full_frame | Retained_pixels of pixel_reference option
type tick = { frames : int option; pixel_response : pixel_response }

let sha256_hex_length = 64

let decode_pixel_reference = function
  | `Assoc fields when List.length fields = 3 ->
      (match List.assoc_opt "revision" fields, List.assoc_opt "width" fields,
             List.assoc_opt "height" fields with
       | Some (`String revision), Some (`Int width), Some (`Int height)
         when String.length revision = sha256_hex_length && width > 0 && height > 0
              && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) revision ->
           Ok { revision; width; height }
       | _ -> Error "known_pixels requires a SHA256 revision and positive width/height")
  | _ -> Error "known_pixels requires exactly revision, width and height"

let decode_tick : Yojson.Safe.t -> (tick, string) result = function
  | `Assoc fields ->
      let names = List.map fst fields in
      let* () =
        if List.length names <> List.length (List.sort_uniq String.compare names)
           || List.exists (fun name -> not (List.mem name ["frames"; "pixel_response"; "known_pixels"])) names
        then Error "tick has duplicate or unknown fields" else Ok () in
      let* frames = match List.assoc_opt "frames" fields with
        | None -> Ok None
        | Some (`Int n) -> Ok (Some n)
        | Some _ -> Error "frames must be an integer" in
      let* pixel_response =
        match List.assoc_opt "pixel_response" fields, List.assoc_opt "known_pixels" fields with
        | None, None -> Ok Full_frame
        | Some (`String "retained"), None -> Ok (Retained_pixels None)
        | Some (`String "retained"), Some value ->
            Result.map (fun reference -> Retained_pixels (Some reference)) (decode_pixel_reference value)
        | _ -> Error "known_pixels requires pixel_response=retained" in
      Ok { frames; pixel_response }
  | _ -> Error "tick body must be an object"
