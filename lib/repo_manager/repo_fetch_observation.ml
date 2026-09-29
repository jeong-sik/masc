type t =
  { common_dir : string
  ; origin_url : string
  ; target_ref : string
  ; oid : string
  ; observed_at_unix : int
  }

let filename = "masc-target-ref-observation.json"

let is_oid value =
  String.length value = 40
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value

let read ~common_dir =
  try
    let common_dir = Filename.realpath common_dir in
    let path = Filename.concat common_dir filename in
    match Yojson.Safe.from_file path with
    | `Assoc fields ->
      (match List.assoc_opt "common_dir" fields,
             List.assoc_opt "origin_url" fields,
             List.assoc_opt "target_ref" fields,
             List.assoc_opt "oid" fields,
             List.assoc_opt "observed_at_unix" fields with
       | Some (`String recorded_dir), Some (`String origin_url),
         Some (`String target_ref), Some (`String oid), Some (`Int observed_at_unix)
         when String.equal recorded_dir common_dir && is_oid oid
              && observed_at_unix > 0 ->
         Some { common_dir; origin_url; target_ref; oid; observed_at_unix }
       | _ -> None)
    | _ -> None
  with
  | Sys_error _ | Unix.Unix_error _ | Yojson.Json_error _ -> None
;;

let write ~common_dir observation =
  try
    let common_dir = Filename.realpath common_dir in
    let path = Filename.concat common_dir filename in
    let temporary = Filename.temp_file ~temp_dir:common_dir ".masc-target-ref-" ".tmp" in
    let payload =
      Yojson.Safe.to_string
        (`Assoc
           [ "common_dir", `String common_dir
           ; "origin_url", `String observation.origin_url
           ; "target_ref", `String observation.target_ref
           ; "oid", `String observation.oid
           ; "observed_at_unix", `Int observation.observed_at_unix
           ])
    in
    Fun.protect
      ~finally:(fun () -> if Sys.file_exists temporary then Sys.remove temporary)
      (fun () ->
         let output = open_out_bin temporary in
         Fun.protect
           ~finally:(fun () -> close_out_noerr output)
           (fun () -> output_string output payload);
         Unix.rename temporary path);
    Ok ()
  with
  | Sys_error message -> Error message
  | Unix.Unix_error (code, operation, path) ->
    Error (Printf.sprintf "%s %s: %s" operation path (Unix.error_message code))
;;
