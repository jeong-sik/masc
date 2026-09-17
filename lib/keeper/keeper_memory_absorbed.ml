(* Absorbed memory records (RFC-0456 §4.2). See the interface for the contract. *)

module W = Keeper_memory_os_types

let ( let* ) = Result.bind
let suffix = ".memory-absorbed.jsonl"

let path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ suffix)
;;

type record =
  { recorded_at : float
  ; trace_id : string
  ; memory_id : string
  ; into : string
  ; fact : W.fact
  }

let field_recorded_at = "recorded_at"
let field_trace_id = "trace_id"
let field_memory_id = "memory_id"
let field_into = "into"
let field_fact = "fact"

let fields = [ field_recorded_at; field_trace_id; field_memory_id; field_into; field_fact ]

let validate (r : record) =
  let* () =
    if Float.is_finite r.recorded_at
    then Ok ()
    else W.wire_fail [ W.Wire_field field_recorded_at ] W.Not_finite
  in
  let* () =
    if W.is_memory_id r.memory_id
    then Ok ()
    else W.wire_fail [ W.Wire_field field_memory_id ] (W.Not_a_memory_id r.memory_id)
  in
  let* () =
    if W.is_memory_id r.into
    then Ok ()
    else W.wire_fail [ W.Wire_field field_into ] (W.Not_a_memory_id r.into)
  in
  (* A fact that absorbs itself names nothing; a row whose id is not its fact's
     identity would answer a search with text the id does not name. *)
  let* () =
    if String.equal r.memory_id r.into
    then W.wire_fail [ W.Wire_field field_into ] (W.Duplicate_entry r.into)
    else Ok ()
  in
  let identity = W.memory_id r.fact in
  if String.equal identity r.memory_id
  then Ok r
  else W.wire_fail [ W.Wire_field field_memory_id ] (W.Not_a_memory_id r.memory_id)
;;

let record_to_json (r : record) =
  `Assoc
    [ field_recorded_at, `Float r.recorded_at
    ; field_trace_id, `String r.trace_id
    ; field_memory_id, `String r.memory_id
    ; field_into, `String r.into
    ; field_fact, W.fact_to_json r.fact
    ]
;;

let record_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc assoc ->
    let* () = W.exact_field_names_result fields assoc in
    let* recorded_at = W.wire_number_field field_recorded_at assoc in
    let* trace_id = W.wire_string_field field_trace_id assoc in
    let* memory_id = W.wire_string_field field_memory_id assoc in
    let* into = W.wire_string_field field_into assoc in
    let* fact =
      match List.assoc_opt field_fact assoc with
      | Some fact_json ->
        W.fact_of_json fact_json
        |> Result.map_error (fun (error : W.wire_error) ->
          { error with W.path = W.Wire_field field_fact :: error.W.path })
      | None -> W.wire_fail [ W.Wire_field field_fact ] W.Expected_object
    in
    validate { recorded_at; trace_id; memory_id; into; fact }
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    W.wire_here W.Expected_object
;;

type append_error =
  | Invalid_record of W.wire_error
  | Write_failed of
      { path : string
      ; message : string
      }

let append_error_to_string = function
  | Invalid_record error -> "absorbed memory record rejected: " ^ W.wire_error_to_string error
  | Write_failed { path; message } ->
    Printf.sprintf "absorbed memory append failed path=%s: %s" path message
;;

let append_all ~keepers_dir ~keeper_id records =
  let rec validated acc = function
    | [] -> Ok (List.rev acc)
    | record :: rest ->
      (match validate record with
       | Ok record -> validated (record_to_json record :: acc) rest
       | Error error -> Error (Invalid_record error))
  in
  match validated [] records with
  | Error _ as error -> error
  | Ok [] -> Ok ()
  | Ok (_ :: _ as lines) ->
    let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
    (try Ok (Fs_compat.append_jsonl_batch path lines) with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Error (Write_failed { path; message = Printexc.to_string exn }))
;;

type read_error =
  | Not_json of string
  | Malformed of W.wire_error

let read_error_to_string = function
  | Not_json message -> "absorbed memory line is not valid JSON: " ^ message
  | Malformed error -> "absorbed memory line rejected: " ^ W.wire_error_to_string error
;;

let read ~keepers_dir ~keeper_id =
  let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  match Fs_compat.load_file_opt path with
  | None -> []
  | Some contents ->
    String.split_on_char '\n' contents
    |> List.filter (fun line -> not (String.equal (String.trim line) ""))
    |> List.mapi (fun index line ->
      ( index + 1
      , match Yojson.Safe.from_string line with
        | json -> Result.map_error (fun error -> Malformed error) (record_of_json json)
        | exception Yojson.Json_error message -> Error (Not_json message) ))
;;
