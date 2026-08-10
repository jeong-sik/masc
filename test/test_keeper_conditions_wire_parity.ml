(** Pin the [conditions] wire vocabulary across the encoder and the client
    schema.

    [Keeper_state_machine_types.conditions] is the SSOT.
    [Keeper_state_machine_json.conditions_to_json] serializes it, and the
    dashboard parses the result with a zod object in
    dashboard/src/api/schemas/keeper-composite.ts. zod strips keys the object
    does not declare, so a field added to the record and emitted by the encoder
    is dropped by the client without any error — the value simply is not there.

    That is how #26569 happened: the record and the encoder carried thirteen
    fields while the schema declared eleven, and [restart_requested] and
    [credential_archived] never reached the dashboard. Nothing failed; the
    fields were absent rather than wrong.

    Comparing the encoder's actual output keys to the schema's declared keys
    puts both ends of the wire in one assertion. The encoder side is read at
    runtime rather than from source, so a hand-written mapping that forgets a
    field fails here too. *)

open Masc

let schema_path = "../dashboard/src/api/schemas/keeper-composite.ts"

let read_file path =
  In_channel.with_open_text path In_channel.input_all

(* The zod block, not the whole file: several other objects in this schema
   carry snake_case keys, and matching them all would compare the wrong set. *)
let schema_condition_fields source =
  let marker = "conditions: object({" in
  let rec find_from index =
    if index + String.length marker > String.length source
    then None
    else if String.sub source index (String.length marker) = marker
    then Some (index + String.length marker)
    else find_from (index + 1)
  in
  match find_from 0 with
  | None -> None
  | Some start ->
    let rec close index depth =
      if index >= String.length source
      then None
      else (
        match source.[index] with
        | '(' -> close (index + 1) (depth + 1)
        | ')' when depth = 0 -> Some index
        | ')' -> close (index + 1) (depth - 1)
        | _ -> close (index + 1) depth)
    in
    (match close start 0 with
     | None -> None
     | Some stop ->
       let block = String.sub source start (stop - start) in
       let fields =
         String.split_on_char '\n' block
         |> List.filter_map (fun line ->
              let trimmed = String.trim line in
              match String.index_opt trimmed ':' with
              | None -> None
              | Some colon ->
                let name = String.sub trimmed 0 colon in
                let is_ident =
                  name <> ""
                  && String.for_all
                       (fun c ->
                         (c >= 'a' && c <= 'z') || c = '_' || (c >= '0' && c <= '9'))
                       name
                in
                if is_ident then Some name else None)
       in
       Some (List.sort_uniq String.compare fields))
;;

let encoder_fields () =
  match
    Keeper_state_machine_json.conditions_to_json
      Keeper_state_machine.default_conditions
  with
  | `Assoc pairs -> List.sort_uniq String.compare (List.map fst pairs)
  | _ -> failwith "conditions_to_json did not produce a JSON object"
;;

let () =
  let encoder = encoder_fields () in
  let source = read_file schema_path in
  let schema =
    match schema_condition_fields source with
    | Some fields -> fields
    | None ->
      Printf.eprintf
        "test_keeper_conditions_wire_parity: could not find `conditions: \
         object({` in %s — the schema moved or was renamed, so this check is \
         reading nothing.\n"
        schema_path;
      exit 1
  in
  (* A blind extractor and a genuinely empty schema look the same, so refuse
     to pass on an empty set from either side. *)
  if encoder = [] then (
    Printf.eprintf "test_keeper_conditions_wire_parity: encoder emitted no fields\n";
    exit 1);
  if schema = [] then (
    Printf.eprintf
      "test_keeper_conditions_wire_parity: parsed no fields out of %s\n"
      schema_path;
    exit 1);
  let missing = List.filter (fun f -> not (List.mem f schema)) encoder in
  let extra = List.filter (fun f -> not (List.mem f encoder)) schema in
  if missing <> [] || extra <> [] then (
    Printf.eprintf
      "test_keeper_conditions_wire_parity: encoder emits %d field(s), schema \
       declares %d\n"
      (List.length encoder) (List.length schema);
    if missing <> [] then
      Printf.eprintf
        "  emitted but not declared (zod drops these): %s\n"
        (String.concat ", " missing);
    if extra <> [] then
      Printf.eprintf
        "  declared but never emitted: %s\n"
        (String.concat ", " extra);
    exit 1);
  Printf.printf
    "test_keeper_conditions_wire_parity: OK - %d conditions fields agree\n"
    (List.length encoder)
;;
