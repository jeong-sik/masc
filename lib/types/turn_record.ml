type prompt_block =
  { block : Prompt_block_id.t
  ; bytes : int
  ; digest : string
  }

type sampling =
  { temperature : float option
  ; top_p : float option
  ; max_tokens : int option
  ; thinking_budget : int option
  ; enable_thinking : bool option
  }

type usage =
  { input_tokens : int option
  ; output_tokens : int option
  }

type t =
  { keeper : string
  ; trace_id : string
  ; absolute_turn : int
  ; turn_ref : Ids.Turn_ref.t
  ; blocks : prompt_block list
  ; runtime_profile : string
  ; model : string option
  ; finish_reason : string option
  ; context_window : int option
  ; price_input_per_million : float option
  ; price_output_per_million : float option
  ; request_latency_ms : int option
  ; ttfrc_ms : float option
  ; sampling : sampling
  ; usage : usage
  ; ts : float
  }

(* ── Codec ─────────────────────────────────────────────── *)

let opt_field name to_json = function
  | Some value -> [ (name, to_json value) ]
  | None -> []

let prompt_block_to_json (b : prompt_block) : Yojson.Safe.t =
  `Assoc
    [ ("block", `String (Prompt_block_id.to_string b.block))
    ; ("bytes", `Int b.bytes)
    ; ("digest", `String b.digest)
    ]

let to_json (r : t) : Yojson.Safe.t =
  `Assoc
    ([ ("keeper", `String r.keeper)
     ; ("trace_id", `String r.trace_id)
     ; ("absolute_turn", `Int r.absolute_turn)
     ; ("blocks", `List (List.map prompt_block_to_json r.blocks))
     ; ("runtime_profile", `String r.runtime_profile)
     ]
    @ [ ("turn_ref", Ids.Turn_ref.to_yojson r.turn_ref) ]
    @ opt_field "model" (fun v -> `String v) r.model
    @ opt_field "finish_reason" (fun v -> `String v) r.finish_reason
    @ opt_field "context_window" (fun v -> `Int v) r.context_window
    @ opt_field "price_input_per_million" (fun v -> `Float v) r.price_input_per_million
    @ opt_field "price_output_per_million" (fun v -> `Float v) r.price_output_per_million
    @ opt_field "request_latency_ms" (fun v -> `Int v) r.request_latency_ms
    @ opt_field "ttfrc_ms" (fun v -> `Float v) r.ttfrc_ms
    @ opt_field "temperature" (fun v -> `Float v) r.sampling.temperature
    @ opt_field "top_p" (fun v -> `Float v) r.sampling.top_p
    @ opt_field "max_tokens" (fun v -> `Int v) r.sampling.max_tokens
    @ opt_field "thinking_budget" (fun v -> `Int v) r.sampling.thinking_budget
    @ opt_field "enable_thinking" (fun v -> `Bool v) r.sampling.enable_thinking
    @ opt_field "input_tokens" (fun v -> `Int v) r.usage.input_tokens
    @ opt_field "output_tokens" (fun v -> `Int v) r.usage.output_tokens
    @ [ ("ts", `Float r.ts) ])

let ( let* ) = Result.bind

module String_set = Set.Make (String)

let invalid_numeric name reason =
  Error (Printf.sprintf "turn_record: field %S %s" name reason)

let validate_nonnegative_int name value =
  if value >= 0 then Ok () else invalid_numeric name "must be nonnegative"

let validate_optional_nonnegative_int name = function
  | None -> Ok ()
  | Some value -> validate_nonnegative_int name value

let validate_nonnegative_float name value =
  if not (Float.is_finite value)
  then invalid_numeric name "must be finite"
  else if value < 0.0
  then invalid_numeric name "must be nonnegative"
  else Ok ()

let validate_optional_nonnegative_float name = function
  | None -> Ok ()
  | Some value -> validate_nonnegative_float name value

let validate_blocks blocks =
  let rec loop seen = function
    | [] -> Ok ()
    | (block : prompt_block) :: rest ->
      let block_id = Prompt_block_id.to_string block.block in
      let* () = validate_nonnegative_int "blocks[].bytes" block.bytes in
      if String_set.mem block_id seen
      then
        Error
          (Printf.sprintf
             "turn_record: duplicate prompt block id %S"
             block_id)
      else if not (Prompt_block_id.equal block.block (Prompt_block_id.of_string block_id))
      then
        Error
          (Printf.sprintf
             "turn_record: non-canonical prompt block id %S"
             block_id)
      else loop (String_set.add block_id seen) rest
  in
  loop String_set.empty blocks

let make
      ~keeper
      ~trace_id
      ~absolute_turn
      ~blocks
      ~runtime_profile
      ~model
      ~finish_reason
      ~context_window
      ~price_input_per_million
      ~price_output_per_million
      ~request_latency_ms
      ~ttfrc_ms
      ~sampling
      ~usage
      ~ts
  =
  let* () =
    if absolute_turn > 0
    then Ok ()
    else Error "turn_record: absolute_turn must be positive"
  in
  let* () =
    if String.equal trace_id ""
    then Error "turn_record: trace_id must not be empty"
    else Ok ()
  in
  let* () = validate_blocks blocks in
  let* () = validate_optional_nonnegative_int "context_window" context_window in
  let* () =
    validate_optional_nonnegative_float
      "price_input_per_million"
      price_input_per_million
  in
  let* () =
    validate_optional_nonnegative_float
      "price_output_per_million"
      price_output_per_million
  in
  let* () =
    validate_optional_nonnegative_int "request_latency_ms" request_latency_ms
  in
  let* () = validate_optional_nonnegative_float "ttfrc_ms" ttfrc_ms in
  let* () =
    validate_optional_nonnegative_float "temperature" sampling.temperature
  in
  let* () = validate_optional_nonnegative_float "top_p" sampling.top_p in
  let* () = validate_optional_nonnegative_int "max_tokens" sampling.max_tokens in
  let* () =
    validate_optional_nonnegative_int
      "thinking_budget"
      sampling.thinking_budget
  in
  let* () = validate_optional_nonnegative_int "input_tokens" usage.input_tokens in
  let* () = validate_optional_nonnegative_int "output_tokens" usage.output_tokens in
  let* () = validate_nonnegative_float "ts" ts in
  Ok
    { keeper
    ; trace_id
    ; absolute_turn
    ; turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn
    ; blocks
    ; runtime_profile
    ; model
    ; finish_reason
    ; context_window
    ; price_input_per_million
    ; price_output_per_million
    ; request_latency_ms
    ; ttfrc_ms
    ; sampling
    ; usage
    ; ts
    }

let member name fields = List.assoc_opt name fields

let require name fields =
  match member name fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "turn_record: missing field %S" name)

let allowed_fields =
  [ "keeper"
  ; "trace_id"
  ; "absolute_turn"
  ; "turn_ref"
  ; "blocks"
  ; "runtime_profile"
  ; "model"
  ; "finish_reason"
  ; "context_window"
  ; "price_input_per_million"
  ; "price_output_per_million"
  ; "request_latency_ms"
  ; "ttfrc_ms"
  ; "temperature"
  ; "top_p"
  ; "max_tokens"
  ; "thinking_budget"
  ; "enable_thinking"
  ; "input_tokens"
  ; "output_tokens"
  ; "ts"
  ]

let validate_object_fields ~context ~allowed fields =
  let rec loop seen = function
    | [] -> Ok ()
    | (name, _) :: rest when List.mem name seen ->
        Error (Printf.sprintf "turn_record: %s duplicate field %S" context name)
    | (name, _) :: _ when not (List.mem name allowed) ->
        Error (Printf.sprintf "turn_record: %s unexpected field %S" context name)
    | (name, _) :: rest -> loop (name :: seen) rest
  in
  loop [] fields

let validate_fields fields =
  validate_object_fields ~context:"row" ~allowed:allowed_fields fields

let prompt_block_fields = [ "block"; "bytes"; "digest" ]

let as_string name = function
  | `String s -> Ok s
  | _ -> Error (Printf.sprintf "turn_record: field %S is not a string" name)

let as_int name = function
  | `Int i -> Ok i
  | _ -> Error (Printf.sprintf "turn_record: field %S is not an int" name)

let as_float name = function
  | `Float f -> Ok f
  | `Int i -> Ok (float_of_int i)
  | _ -> Error (Printf.sprintf "turn_record: field %S is not a number" name)

let opt_member name fields decode =
  match member name fields with
  | None -> Ok None
  | Some value ->
      let* decoded = decode name value in
      Ok (Some decoded)

let as_bool name = function
  | `Bool b -> Ok b
  | _ -> Error (Printf.sprintf "turn_record: field %S is not a bool" name)

let as_turn_ref name json =
  match Ids.Turn_ref.of_yojson json with
  | Ok t -> Ok t
  | Error e -> Error (Printf.sprintf "turn_record: field %S: %s" name e)

let prompt_block_of_json (json : Yojson.Safe.t) : (prompt_block, string) result =
  match json with
  | `Assoc fields ->
      let* () =
        validate_object_fields ~context:"block" ~allowed:prompt_block_fields
          fields
      in
      let* block_json = require "block" fields in
      let* block_name = as_string "block" block_json in
      let* bytes_json = require "bytes" fields in
      let* bytes = as_int "bytes" bytes_json in
      let* digest_json = require "digest" fields in
      let* digest = as_string "digest" digest_json in
      Ok { block = Prompt_block_id.of_string block_name; bytes; digest }
  | _ -> Error "turn_record: block entry is not an object"

let rec collect_results acc = function
  | [] -> Ok (List.rev acc)
  | item :: rest -> (
      match item with
      | Ok value -> collect_results (value :: acc) rest
      | Error _ as e -> e)

let of_json (json : Yojson.Safe.t) : (t, string) result =
  match json with
  | `Assoc fields ->
      let* () = validate_fields fields in
      let* keeper_json = require "keeper" fields in
      let* keeper = as_string "keeper" keeper_json in
      let* trace_json = require "trace_id" fields in
      let* trace_id = as_string "trace_id" trace_json in
      let* turn_json = require "absolute_turn" fields in
      let* absolute_turn = as_int "absolute_turn" turn_json in
      let* blocks_json = require "blocks" fields in
      let* blocks =
        match blocks_json with
        | `List items -> collect_results [] (List.map prompt_block_of_json items)
        | _ -> Error "turn_record: blocks is not a list"
      in
      let* profile_json = require "runtime_profile" fields in
      let* runtime_profile = as_string "runtime_profile" profile_json in
      let* turn_ref_json = require "turn_ref" fields in
      let* turn_ref = as_turn_ref "turn_ref" turn_ref_json in
      let* model = opt_member "model" fields as_string in
      let* finish_reason = opt_member "finish_reason" fields as_string in
      let* context_window = opt_member "context_window" fields as_int in
      let* price_input_per_million = opt_member "price_input_per_million" fields as_float in
      let* price_output_per_million = opt_member "price_output_per_million" fields as_float in
      let* request_latency_ms = opt_member "request_latency_ms" fields as_int in
      let* ttfrc_ms = opt_member "ttfrc_ms" fields as_float in
      let* temperature = opt_member "temperature" fields as_float in
      let* top_p = opt_member "top_p" fields as_float in
      let* max_tokens = opt_member "max_tokens" fields as_int in
      let* thinking_budget = opt_member "thinking_budget" fields as_int in
      let* enable_thinking = opt_member "enable_thinking" fields as_bool in
      let* input_tokens = opt_member "input_tokens" fields as_int in
      let* output_tokens = opt_member "output_tokens" fields as_int in
      let* ts_json = require "ts" fields in
      let* ts = as_float "ts" ts_json in
      let* record =
        make
          ~keeper
          ~trace_id
          ~absolute_turn
          ~blocks
          ~runtime_profile
          ~model
          ~finish_reason
          ~context_window
          ~price_input_per_million
          ~price_output_per_million
          ~request_latency_ms
          ~ttfrc_ms
          ~sampling:
            { temperature; top_p; max_tokens; thinking_budget; enable_thinking }
          ~usage:{ input_tokens; output_tokens }
          ~ts
      in
      if Ids.Turn_ref.equal turn_ref record.turn_ref
      then Ok record
      else Error "turn_record: turn_ref does not match trace_id/absolute_turn"
  | _ -> Error "turn_record: row is not an object"

(* ── Block diff ────────────────────────────────────────── *)

type block_diff =
  { added : prompt_block list
  ; removed : prompt_block list
  ; changed : (prompt_block * prompt_block) list
  }

let find_block blocks id =
  List.find_opt (fun (b : prompt_block) -> Prompt_block_id.equal b.block id) blocks

let diff_blocks ~(prev : t) ~(next : t) : block_diff =
  let prev_blocks = prev.blocks in
  let next_blocks = next.blocks in
  let added =
    List.filter
      (fun (b : prompt_block) -> find_block prev_blocks b.block = None)
      next_blocks
  in
  let removed =
    List.filter
      (fun (b : prompt_block) -> find_block next_blocks b.block = None)
      prev_blocks
  in
  let changed =
    List.filter_map
      (fun (next_b : prompt_block) ->
        match find_block prev_blocks next_b.block with
        | Some prev_b when not (String.equal prev_b.digest next_b.digest) ->
            Some (prev_b, next_b)
        | Some _ | None -> None)
      next_blocks
  in
  { added; removed; changed }

let entries_with_diffs (records : t list) : (t * block_diff option) list =
  (* A diff is only meaningful against the previous record of the SAME
     trace: a generation boundary legitimately replaces the whole
     assembly, and that diff would be noise rather than signal. *)
  let rec walk prev = function
    | [] -> []
    | record :: rest ->
        let diff =
          match prev with
          | Some p when String.equal p.trace_id record.trace_id ->
              Some (diff_blocks ~prev:p ~next:record)
          | Some _ | None -> None
        in
        (record, diff) :: walk (Some record) rest
  in
  walk None records
