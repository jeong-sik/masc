let ( let* ) = Result.bind

type arguments =
  | Known of Yojson.Safe.t
  | Unknown

type receipt =
  { thread_id : string
  ; turn_id : string
  ; call_id : string
  ; tool_name : string
  ; arguments : arguments
  ; response : Yojson.Safe.t
  }

let arguments_to_json = function
  | Known value -> `Assoc ["known", value]
  | Unknown -> `Assoc ["unknown", `Bool true]

let arguments_of_json = function
  | `Assoc ["known", value] -> Ok (Known value)
  | `Assoc ["unknown", `Bool true] -> Ok Unknown
  | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Error "invalid tool outbox arguments"

let to_json (result : receipt) =
  `Assoc ["thread_id", `String result.thread_id; "turn_id", `String result.turn_id;
    "call_id", `String result.call_id; "tool_name", `String result.tool_name;
    "arguments", arguments_to_json result.arguments; "response", result.response]

let host_to_json ~producer_id ~runtime_label ~turn_count ~invocation_index
    ~call_id ~tool_name ~arguments ~response =
  `Assoc ["host_invocation_index",`Int invocation_index;
    "host_producer_id",`String producer_id;
    "runtime_label",`String runtime_label;"host_turn_count",`Int turn_count;
    "call_id",`String call_id;"tool_name",`String tool_name;
    "arguments",arguments_to_json arguments;"response",response]

let filename json =
  Agent_core_sha256.(digest_string (Yojson.Safe.to_string json) |> to_hex) ^ ".json"

let validate ~path json =
  match json with
  | `Assoc fields ->
    let names = List.map fst fields in
    let names = List.sort String.compare names in
    let vendor = ["arguments"; "call_id"; "response"; "thread_id"; "tool_name"; "turn_id"] in
    let host = ["arguments"; "call_id"; "host_invocation_index"; "host_producer_id"; "host_turn_count";
      "response"; "runtime_label"; "tool_name"] in
    let strings_valid names = List.for_all (fun name -> match List.assoc_opt name fields with
      | Some (`String value) -> String.trim value <> ""
      | Some _ | None -> false) names in
    let* () =
      if names = vendor then
        if strings_valid ["thread_id"; "turn_id"; "call_id"; "tool_name"] then Ok ()
        else Error "invalid vendor tool outbox identity"
      else if names = host then
        if not (strings_valid ["host_producer_id"; "runtime_label"; "call_id"; "tool_name"])
        then Error "invalid host tool outbox identity"
        else
          let* () = match List.assoc_opt "host_producer_id" fields with
            | Some (`String value) -> Random_id.parse_uuid_v7 value |> Result.map (fun _ -> ())
            | Some _ | None -> Error "invalid host tool result producer" in
          let* () = match List.assoc_opt "host_invocation_index" fields with
            | Some (`Int value) when value >= 0 -> Ok ()
            | Some _ | None -> Error "invalid host tool invocation index" in
          (match List.assoc_opt "host_turn_count" fields with
           | Some (`Int value) when value >= 0 -> Ok ()
           | Some _ | None -> Error "invalid host tool result turn count")
      else Error "invalid tool outbox fields" in
    let* () = match List.assoc_opt "arguments" fields with
      | Some value -> arguments_of_json value |> Result.map (fun (_ : arguments) -> ())
      | None -> Error "invalid tool outbox arguments" in
    if Filename.basename path <> filename json then Error "tool outbox digest mismatch"
    else Ok ()
  | _ -> Error "tool outbox receipt must be an object"

