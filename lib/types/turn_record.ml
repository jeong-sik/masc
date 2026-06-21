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
  { execution_ids : Ids.Execution_id.t list
  ; keeper : string
  ; trace_id : string
  ; absolute_turn : int
  ; turn_ref : Ids.Turn_ref.t option
  ; blocks : prompt_block list
  ; runtime_profile : string
  ; model : string option
  ; finish_reason : string option
  ; context_window : int option
  ; price_input_per_million : float option
  ; price_output_per_million : float option
  ; request_latency_ms : int option
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
    ([ ( "execution_ids"
       , `List (List.map Ids.Execution_id.to_yojson r.execution_ids) )
     ; ("keeper", `String r.keeper)
     ; ("trace_id", `String r.trace_id)
     ; ("absolute_turn", `Int r.absolute_turn)
     ; ("blocks", `List (List.map prompt_block_to_json r.blocks))
     ; ("runtime_profile", `String r.runtime_profile)
     ]
    @ opt_field "turn_ref" Ids.Turn_ref.to_yojson r.turn_ref
    @ opt_field "model" (fun v -> `String v) r.model
    @ opt_field "finish_reason" (fun v -> `String v) r.finish_reason
    @ opt_field "context_window" (fun v -> `Int v) r.context_window
    @ opt_field "price_input_per_million" (fun v -> `Float v) r.price_input_per_million
    @ opt_field "price_output_per_million" (fun v -> `Float v) r.price_output_per_million
    @ opt_field "request_latency_ms" (fun v -> `Int v) r.request_latency_ms
    @ opt_field "temperature" (fun v -> `Float v) r.sampling.temperature
    @ opt_field "top_p" (fun v -> `Float v) r.sampling.top_p
    @ opt_field "max_tokens" (fun v -> `Int v) r.sampling.max_tokens
    @ opt_field "thinking_budget" (fun v -> `Int v) r.sampling.thinking_budget
    @ opt_field "enable_thinking" (fun v -> `Bool v) r.sampling.enable_thinking
    @ opt_field "input_tokens" (fun v -> `Int v) r.usage.input_tokens
    @ opt_field "output_tokens" (fun v -> `Int v) r.usage.output_tokens
    @ [ ("ts", `Float r.ts) ])

let ( let* ) = Result.bind

let member name fields = List.assoc_opt name fields

let require name fields =
  match member name fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "turn_record: missing field %S" name)

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
      let* ids_json = require "execution_ids" fields in
      let* execution_ids =
        match ids_json with
        | `List items ->
            collect_results [] (List.map Ids.Execution_id.of_yojson items)
        | _ -> Error "turn_record: execution_ids is not a list"
      in
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
      let* turn_ref = opt_member "turn_ref" fields as_turn_ref in
      let* model = opt_member "model" fields as_string in
      let* finish_reason = opt_member "finish_reason" fields as_string in
      let* context_window = opt_member "context_window" fields as_int in
      let* price_input_per_million = opt_member "price_input_per_million" fields as_float in
      let* price_output_per_million = opt_member "price_output_per_million" fields as_float in
      let* request_latency_ms = opt_member "request_latency_ms" fields as_int in
      let* temperature = opt_member "temperature" fields as_float in
      let* top_p = opt_member "top_p" fields as_float in
      let* max_tokens = opt_member "max_tokens" fields as_int in
      let* thinking_budget = opt_member "thinking_budget" fields as_int in
      let* enable_thinking = opt_member "enable_thinking" fields as_bool in
      let* input_tokens = opt_member "input_tokens" fields as_int in
      let* output_tokens = opt_member "output_tokens" fields as_int in
      let* ts_json = require "ts" fields in
      let* ts = as_float "ts" ts_json in
      Ok
        { execution_ids
        ; keeper
        ; trace_id
        ; absolute_turn
        ; turn_ref
        ; blocks
        ; runtime_profile
        ; model
        ; finish_reason
        ; context_window
        ; price_input_per_million
        ; price_output_per_million
        ; request_latency_ms
        ; sampling = { temperature; top_p; max_tokens; thinking_budget; enable_thinking }
        ; usage = { input_tokens; output_tokens }
        ; ts
        }
  | _ -> Error "turn_record: row is not an object"

(* ── Block diff ────────────────────────────────────────── *)

type block_diff =
  { added : prompt_block list
  ; removed : prompt_block list
  ; changed : (prompt_block * prompt_block) list
  }

let find_block blocks id =
  List.find_opt (fun (b : prompt_block) -> Prompt_block_id.equal b.block id) blocks

let dedupe_by_id blocks =
  List.fold_left
    (fun acc (b : prompt_block) ->
      if List.exists (fun (seen : prompt_block) ->
             Prompt_block_id.equal seen.block b.block)
           acc
      then acc
      else b :: acc)
    [] blocks
  |> List.rev

let diff_blocks ~(prev : t) ~(next : t) : block_diff =
  let prev_blocks = dedupe_by_id prev.blocks in
  let next_blocks = dedupe_by_id next.blocks in
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
