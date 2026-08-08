(** External JSON capability manifest for model-specific overrides.

    @since 0.188.0 *)

type base_label = string

let normalize_base_label raw = String.lowercase_ascii (String.trim raw)

let base_label_of_string raw =
  let normalized = normalize_base_label raw in
  if List.mem normalized Capability_vocab.base_label_values
  then Ok normalized
  else
    Error
      (Printf.sprintf
         "unknown base preset %S (canonical: %s)"
         normalized
         (String.concat ", " Capability_vocab.base_label_values))
;;

let base_label_to_string label = label

type entry =
  { id_prefix : string
  ; base_label : base_label option
  ; max_context_tokens : int option
  ; max_output_tokens : int option
  ; supports_tools : bool option
  ; supports_tool_choice : bool option
  ; supports_required_tool_choice : bool option
  ; supports_named_tool_choice : bool option
  ; supports_parallel_tool_calls : bool option
  ; assistant_tool_content_format : string option
  ; supports_reasoning : bool option
  ; supports_extended_thinking : bool option
  ; supports_reasoning_budget : bool option
  ; accepted_reasoning_efforts : string list option
    (** Optional subset of canonical reasoning effort values this model accepts
        (none / minimal / low / medium / high / xhigh). *)
  ; supports_response_format_json : bool option
  ; supports_structured_output : bool option
  ; supports_multimodal_inputs : bool option
  ; supports_image_input : bool option
  ; supports_audio_input : bool option
  ; supports_video_input : bool option
  ; supports_document_input : bool option
  ; supports_native_streaming : bool option
  ; supports_system_prompt : bool option
  ; supports_caching : bool option
  ; supports_prompt_caching : bool option
  ; supports_top_k : bool option
  ; supports_min_p : bool option
  ; supports_seed : bool option
  ; ignored_sampling_parameters : Capability_vocab.sampling_parameter list option
  ; supports_computer_use : bool option
  ; supports_code_execution : bool option
  ; thinking_control_format : Capability_vocab.thinking_control_format option
    (** Canonical thinking-wire format the model uses (none / thinking_object /
        thinking_object_adaptive / thinking_object_only / chat_template_kwargs /
        chat_template_token / reasoning_effort / enable_thinking). Parsed + applied in
        {!Capabilities.apply_manifest_entry}. Without this field a manifest
        entry silently dropped the model's thinking knob (RFC-OAS-023).

        Joined from the JSON [thinking_control_format] and [thinking_control_token]
        members at parse time: [chat_template_token] carries its token (for
        example [<|think|>]) in the [Chat_template_token] constructor, so a
        tokenless declaration — or a token without that format — fails closed in
        {!parse_entry} rather than raising when a request builder needs it. *)
  ; anthropic_thinking_control : Capability_vocab.anthropic_thinking_control option
  ; preserve_thinking_control_format : string option
    (** Canonical historical reasoning preservation wire format (none /
        thinking_object_keep_all / chat_template_kwargs_preserve_thinking /
        top_level_preserve_thinking / always_preserved). Parsed + applied in
        {!Capabilities.apply_manifest_entry}. *)
  ; reasoning_output_format : string option
    (** Canonical request-side reasoning output split control (none /
        split_reasoning_fields). Parsed + applied in
        {!Capabilities.apply_manifest_entry}. *)
  ; reasoning_streaming_format : string option
    (** Canonical streaming reasoning side-channel (default / none /
        template_parser / delta:<field>). Parsed + applied in
        {!Capabilities.apply_manifest_entry}. *)
  ; reasoning_replay : string option
    (** Optional multi-turn reasoning replay policy override (default / no_replay
        / drop_without_tool / preserve_always); applied in
        {!Capabilities.apply_manifest_entry}. *)
  }

(** A parsed capability manifest. *)
type t = entry list

(* Local result-syntax bindings so this file can use [let*] / [let+]
   without depending on [agent_sdk.base] (which would create a circular
   library dependency). *)
module Result_syntax = struct
  let ( let* ) = Result.bind
  let ( let+ ) x f = Result.map f x
end

(* ── JSON parsing helpers ───────────────────────────────── *)

let json_kind = function
  | `Null -> "null"
  | `Bool _ -> "bool"
  | `Int _ -> "int"
  | `Intlit _ -> "intlit"
  | `Float _ -> "float"
  | `String _ -> "string"
  | `Assoc _ -> "object"
  | `List _ -> "array"
  | `Tuple _ -> "tuple"
  | `Variant _ -> "variant"
;;

let member_bool key json =
  match Yojson.Safe.Util.member key json with
  | `Bool b -> Ok (Some b)
  | `Null -> Ok None
  | actual ->
    Error (Printf.sprintf "entry field %S expected bool, got %s" key (json_kind actual))
;;

let member_int key json =
  match Yojson.Safe.Util.member key json with
  | `Int n -> Ok (Some n)
  | `Intlit s ->
    (match int_of_string_opt s with
     | Some n -> Ok (Some n)
     | None ->
       Error
         (Printf.sprintf
            "entry field %S integer literal %S is out of native int range"
            key
            s))
  | `Null -> Ok None
  | actual ->
    Error (Printf.sprintf "entry field %S expected int, got %s" key (json_kind actual))
;;

let member_string_closed key json =
  match Yojson.Safe.Util.member key json with
  | `String s -> Ok (Some s)
  | `Null -> Ok None
  | actual ->
    Error (Printf.sprintf "entry field %S expected string, got %s" key (json_kind actual))
;;

let non_empty_member_string key json =
  let open Result_syntax in
  let* value = member_string_closed key json in
  match value with
  | None -> Ok None
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = ""
    then Error (Printf.sprintf "entry field %S must not be empty" key)
    else if raw <> trimmed
    then
      Error
        (Printf.sprintf "entry field %S must not have leading or trailing whitespace" key)
    else Ok (Some raw)
;;

let member_string_list key json =
  match Yojson.Safe.Util.member key json with
  | `List values ->
    let rec parse_values reversed = function
      | [] -> Ok (Some (List.rev reversed))
      | `String value :: rest -> parse_values (value :: reversed) rest
      | actual :: _ ->
        Error
          (Printf.sprintf
             "entry field %S expected string array, got %s array item"
             key
             (json_kind actual))
    in
    parse_values [] values
  | `Null -> Ok None
  | actual ->
    Error
      (Printf.sprintf
         "entry field %S expected string array, got %s"
         key
         (json_kind actual))
;;

let canonical_choice key ~allowed json =
  let open Result_syntax in
  let* value = member_string_closed key json in
  match value with
  | None -> Ok None
  | Some raw ->
    let normalized = String.lowercase_ascii (String.trim raw) in
    if List.mem normalized allowed
    then Ok (Some raw)
    else
      Error
        (Printf.sprintf
           "entry field %S has unknown value %S (canonical: %s)"
           key
           normalized
           (String.concat ", " allowed))
;;

let canonical_string_list key ~allowed json =
  let open Result_syntax in
  let* values = member_string_list key json in
  match values with
  | None -> Ok None
  | Some values ->
    let unknown =
      List.filter_map
        (fun raw ->
           let normalized = String.lowercase_ascii (String.trim raw) in
           if List.mem normalized allowed then None else Some normalized)
        values
    in
    (match unknown with
     | [] -> Ok (Some values)
     | values ->
       Error
         (Printf.sprintf
            "entry field %S has unknown value(s) %s (canonical: %s)"
            key
            (String.concat ", " values)
            (String.concat ", " allowed)))
;;

let canonical_sampling_parameters key json =
  let open Result_syntax in
  let* values = member_string_list key json in
  match values with
  | None -> Ok None
  | Some values ->
    let parsed, unknown =
      List.fold_right
        (fun raw (parsed, unknown) ->
           match Capability_vocab.sampling_parameter_of_string raw with
           | Some parameter -> parameter :: parsed, unknown
           | None -> parsed, String.lowercase_ascii (String.trim raw) :: unknown)
        values
        ([], [])
    in
    (match unknown with
     | [] -> Ok (Some parsed)
     | values ->
       Error
         (Printf.sprintf
            "entry field %S has unknown value(s) %s (canonical: %s)"
            key
            (String.concat ", " values)
            (String.concat ", " Capability_vocab.sampling_parameter_values)))
;;

let canonical_reasoning_streaming_format key json =
  let open Result_syntax in
  let* value = member_string_closed key json in
  match value with
  | None -> Ok None
  | Some raw ->
    (match Capability_vocab.reasoning_streaming_format_of_string raw with
     | Some _ -> Ok (Some raw)
     | None ->
       let normalized = String.lowercase_ascii (String.trim raw) in
       Error
         (Printf.sprintf
            "entry field %S has unknown value %S (canonical: %s)"
            key
            normalized
            Capability_vocab.reasoning_streaming_format_syntax))
;;

let canonical_anthropic_thinking_control key json =
  let open Result_syntax in
  let* value = member_string_closed key json in
  match value with
  | None -> Ok None
  | Some raw ->
    (match Capability_vocab.anthropic_thinking_control_of_string raw with
     | Some control -> Ok (Some control)
     | None ->
       Error
         (Printf.sprintf
            "entry field %S has unknown value %S (canonical: %s)"
            key
            (String.lowercase_ascii (String.trim raw))
            (String.concat ", " Capability_vocab.anthropic_thinking_control_values)))
;;

let known_manifest_keys = [ "_comment"; "schema_version"; "models" ]

let known_entry_keys =
  [ "_comment"
  ; "id_prefix"
  ; "base"
  ; "max_context_tokens"
  ; "max_output_tokens"
  ; "supports_tools"
  ; "supports_tool_choice"
  ; "supports_required_tool_choice"
  ; "supports_named_tool_choice"
  ; "supports_parallel_tool_calls"
  ; "assistant_tool_content_format"
  ; "supports_reasoning"
  ; "supports_extended_thinking"
  ; "supports_reasoning_budget"
  ; "accepted_reasoning_efforts"
  ; "supports_response_format_json"
  ; "supports_structured_output"
  ; "supports_multimodal_inputs"
  ; "supports_image_input"
  ; "supports_audio_input"
  ; "supports_video_input"
  ; "supports_document_input"
  ; "supports_native_streaming"
  ; "supports_system_prompt"
  ; "supports_caching"
  ; "supports_prompt_caching"
  ; "supports_top_k"
  ; "supports_min_p"
  ; "supports_seed"
  ; "ignored_sampling_parameters"
  ; "supports_computer_use"
  ; "supports_code_execution"
  ; "thinking_control_format"
  ; "thinking_control_token"
  ; "anthropic_thinking_control"
  ; "preserve_thinking_control_format"
  ; "reasoning_output_format"
  ; "reasoning_streaming_format"
  ; "reasoning_replay"
  ]
;;

module String_set = Set.Make (String)

let duplicate_keys fields =
  let _, _, reversed =
    List.fold_left
      (fun (seen, reported, duplicates) (key, _) ->
         if String_set.mem key seen
         then
           if String_set.mem key reported
           then seen, reported, duplicates
           else seen, String_set.add key reported, key :: duplicates
         else String_set.add key seen, reported, duplicates)
      (String_set.empty, String_set.empty, [])
      fields
  in
  List.rev reversed
;;

let validate_closed_object ~scope ~known = function
  | `Assoc fields ->
    let duplicates = duplicate_keys fields in
    if duplicates <> []
    then
      Error
        (Printf.sprintf
           "%s contains duplicate field(s): %s"
           scope
           (String.concat ", " duplicates))
    else (
      let unknown =
        List.filter_map
          (fun (key, _) -> if List.mem key known then None else Some key)
          fields
      in
      match unknown with
      | [] -> Ok ()
      | keys ->
        Error
          (Printf.sprintf
             "%s contains unknown field(s): %s"
             scope
             (String.concat ", " keys)))
  | actual -> Error (Printf.sprintf "%s expected object, got %s" scope (json_kind actual))
;;

let parse_entry json =
  let open Result_syntax in
  let* () = validate_closed_object ~scope:"entry" ~known:known_entry_keys json in
  let* id_prefix =
    match non_empty_member_string "id_prefix" json with
    | Error _ as error -> error
    | Ok None -> Error "entry missing required \"id_prefix\" field"
    | Ok (Some id_prefix) -> Ok id_prefix
  in
  (* Validate [base] against the closed preset vocab at parse time (mirrors the
     other canonical fields below) so an unknown label fails closed instead of
     silently resolving to [default_capabilities] downstream (RFC-OAS-034). *)
  let* base_label_raw =
    canonical_choice "base" ~allowed:Capability_vocab.base_label_values json
  in
  let* base_label =
    match base_label_raw with
    | None -> Ok None
    | Some raw -> Result.map (fun label -> Some label) (base_label_of_string raw)
  in
  (* Read the raw label/token pair and decode it through the exact vocabulary
     authority. The codec owns label exactness, token exactness, and the
     cross-field invariant. *)
  let* thinking_control_format_raw =
    member_string_closed "thinking_control_format" json
  in
  let* thinking_control_token = member_string_closed "thinking_control_token" json in
  let* thinking_control_format =
    Capability_vocab.decode_optional_thinking_control_format
      ~label:thinking_control_format_raw
      ~token:thinking_control_token
    |> Result.map_error (fun error ->
      Printf.sprintf
        "entry %S %s"
        id_prefix
        (Capability_vocab.thinking_control_format_codec_error_to_string error))
  in
  let* anthropic_thinking_control =
    canonical_anthropic_thinking_control "anthropic_thinking_control" json
  in
  let* preserve_thinking_control_format =
    canonical_choice
      "preserve_thinking_control_format"
      ~allowed:Capability_vocab.preserve_thinking_control_format_values
      json
  in
  let* reasoning_output_format =
    canonical_choice
      "reasoning_output_format"
      ~allowed:Capability_vocab.reasoning_output_format_values
      json
  in
  let* reasoning_streaming_format =
    canonical_reasoning_streaming_format "reasoning_streaming_format" json
  in
  let* reasoning_replay =
    canonical_choice
      "reasoning_replay"
      ~allowed:Capability_vocab.reasoning_replay_values
      json
  in
  let* assistant_tool_content_format =
    canonical_choice
      "assistant_tool_content_format"
      ~allowed:Capability_vocab.assistant_tool_content_format_values
      json
  in
  let* accepted_reasoning_efforts =
    canonical_string_list
      "accepted_reasoning_efforts"
      ~allowed:Reasoning_effort.all_wire_values
      json
  in
  let* ignored_sampling_parameters =
    canonical_sampling_parameters "ignored_sampling_parameters" json
  in
  let* max_context_tokens = member_int "max_context_tokens" json in
  let* max_output_tokens = member_int "max_output_tokens" json in
  let* supports_tools = member_bool "supports_tools" json in
  let* supports_tool_choice = member_bool "supports_tool_choice" json in
  let* supports_required_tool_choice = member_bool "supports_required_tool_choice" json in
  let* supports_named_tool_choice = member_bool "supports_named_tool_choice" json in
  let* supports_parallel_tool_calls = member_bool "supports_parallel_tool_calls" json in
  let* supports_reasoning = member_bool "supports_reasoning" json in
  let* supports_extended_thinking = member_bool "supports_extended_thinking" json in
  let* supports_reasoning_budget = member_bool "supports_reasoning_budget" json in
  let* supports_response_format_json = member_bool "supports_response_format_json" json in
  let* supports_structured_output = member_bool "supports_structured_output" json in
  let* supports_multimodal_inputs = member_bool "supports_multimodal_inputs" json in
  let* supports_image_input = member_bool "supports_image_input" json in
  let* supports_audio_input = member_bool "supports_audio_input" json in
  let* supports_video_input = member_bool "supports_video_input" json in
  let* supports_document_input = member_bool "supports_document_input" json in
  let* supports_native_streaming = member_bool "supports_native_streaming" json in
  let* supports_system_prompt = member_bool "supports_system_prompt" json in
  let* supports_caching = member_bool "supports_caching" json in
  let* supports_prompt_caching = member_bool "supports_prompt_caching" json in
  let* supports_top_k = member_bool "supports_top_k" json in
  let* supports_min_p = member_bool "supports_min_p" json in
  let* supports_seed = member_bool "supports_seed" json in
  let* supports_computer_use = member_bool "supports_computer_use" json in
  let* supports_code_execution = member_bool "supports_code_execution" json in
  Ok
    { id_prefix
    ; base_label
    ; max_context_tokens
    ; max_output_tokens
    ; supports_tools
    ; supports_tool_choice
    ; supports_required_tool_choice
    ; supports_named_tool_choice
    ; supports_parallel_tool_calls
    ; assistant_tool_content_format
    ; supports_reasoning
    ; supports_extended_thinking
    ; supports_reasoning_budget
    ; accepted_reasoning_efforts
    ; supports_response_format_json
    ; supports_structured_output
    ; supports_multimodal_inputs
    ; supports_image_input
    ; supports_audio_input
    ; supports_video_input
    ; supports_document_input
    ; supports_native_streaming
    ; supports_system_prompt
    ; supports_caching
    ; supports_prompt_caching
    ; supports_top_k
    ; supports_min_p
    ; supports_seed
    ; ignored_sampling_parameters
    ; supports_computer_use
    ; supports_code_execution
    ; thinking_control_format
    ; anthropic_thinking_control
    ; preserve_thinking_control_format
    ; reasoning_output_format
    ; reasoning_streaming_format
    ; reasoning_replay
    }
;;

let of_json json =
  let open Result_syntax in
  let* () = validate_closed_object ~scope:"manifest" ~known:known_manifest_keys json in
  let schema_version =
    match Yojson.Safe.Util.member "schema_version" json with
    | `Int n -> n
    | _ -> 0
  in
  if schema_version <> 1
  then
    Error
      (Printf.sprintf
         "unsupported capability manifest schema_version: %d (expected 1)"
         schema_version)
  else
    let* model_items =
      match Yojson.Safe.Util.member "models" json with
      | `List items -> Ok items
      | `Null -> Ok []
      | actual ->
        Error
          (Printf.sprintf
             "capability manifest \"models\" must be a list, got %s"
             (json_kind actual))
    in
    let results = List.map parse_entry model_items in
    let oks, errors =
      List.partition_map
        (function
          | Ok e -> Left e
          | Error e -> Right e)
        results
    in
    if errors <> [] then Error (String.concat "; " errors) else Ok oks
;;

let load_file path =
  let open Result_syntax in
  let* json =
    try Ok (Yojson.Safe.from_file path) with
    | Sys_error msg ->
      Error (Printf.sprintf "cannot read capability manifest %s: %s" path msg)
    | Yojson.Json_error msg ->
      Error (Printf.sprintf "capability manifest JSON parse error in %s: %s" path msg)
  in
  of_json json
;;

(* ── Lookup ─────────────────────────────────────────────── *)

let lookup (t : t) model_id =
  let m = String.lowercase_ascii model_id in
  List.find_opt
    (fun entry ->
       let prefix = String.lowercase_ascii entry.id_prefix in
       String.starts_with ~prefix m)
    t
;;

(* ── Global manifest ───────────────────────────────────────
   Embedding applications explicitly parse and install a manifest. *)

(* Process-wide runtime override. [Atomic.t] makes [set_global] /
   [clear_global] / [global] safe under OCaml 5 multi-domain concurrency
   (cf. [lib/llm_provider/pricing.ml]'s [_overrides] table). *)
let runtime_override : t option Atomic.t = Atomic.make None
let set_global m = Atomic.set runtime_override (Some m)
let clear_global () = Atomic.set runtime_override None
let global () = Atomic.get runtime_override

(* ── Inline tests ───────────────────────────────────────── *)

[@@@coverage off]

let%test "of_json: valid manifest parses successfully" =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"my-llm","base":"openai_chat","max_context_tokens":131072,"supports_tools":true}]}|}
  in
  match of_json json with
  | Ok [ entry ] ->
    entry.id_prefix = "my-llm"
    && entry.base_label = Some "openai_chat"
    && entry.max_context_tokens = Some 131072
    && entry.supports_tools = Some true
  | Ok _ | Error _ -> false
;;

let%test "of_json: parses Anthropic thinking policy as typed declaration" =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"claude-future","anthropic_thinking_control":"adaptive_only"}]}|}
  in
  match of_json json with
  | Ok [ { anthropic_thinking_control = Some Capability_vocab.Adaptive_only; _ } ] -> true
  | Ok _ | Error _ -> false
;;

let%test "of_json: rejects unknown Anthropic thinking policy" =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"claude-future","anthropic_thinking_control":"guessing"}]}|}
  in
  match of_json json with
  | Error _ -> true
  | Ok _ -> false
;;

let%test "of_json: wrong schema_version returns error" =
  let json = Yojson.Safe.from_string {|{"schema_version":2,"models":[]}|} in
  match of_json json with
  | Error msg -> String.length msg > 0
  | Ok _ -> false
;;

let%test "of_json: missing schema_version returns error" =
  let json = Yojson.Safe.from_string {|{"models":[]}|} in
  match of_json json with
  | Error _ -> true
  | Ok _ -> false
;;

let%test "of_json: entry missing id_prefix returns error" =
  let json =
    Yojson.Safe.from_string {|{"schema_version":1,"models":[{"base":"openai_chat"}]}|}
  in
  match of_json json with
  | Error _ -> true
  | Ok _ -> false
;;

let%test "of_json: empty models list is valid" =
  let json = Yojson.Safe.from_string {|{"schema_version":1,"models":[]}|} in
  match of_json json with
  | Ok entries -> entries = []
  | Error _ -> false
;;

let%test "of_json: missing models defaults to empty manifest" =
  let json = Yojson.Safe.from_string {|{"schema_version":1}|} in
  match of_json json with
  | Ok entries -> entries = []
  | Error _ -> false
;;

let%test "of_json: non-list models returns error" =
  let json = Yojson.Safe.from_string {|{"schema_version":1,"models":"oops"}|} in
  match of_json json with
  | Error msg -> String.contains msg 'm'
  | Ok _ -> false
;;

let%test "lookup: prefix match is case-insensitive" =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"My-Model","supports_tools":true}]}|}
  in
  match of_json json with
  | Ok manifest ->
    (match lookup manifest "my-model-q4" with
     | Some entry -> entry.supports_tools = Some true
     | None -> false)
  | Error _ -> false
;;

let%test "lookup: no match returns None" =
  let json =
    Yojson.Safe.from_string {|{"schema_version":1,"models":[{"id_prefix":"model-a"}]}|}
  in
  match of_json json with
  | Ok manifest -> lookup manifest "model-b" = None
  | Error _ -> false
;;

let%test "lookup: first matching entry wins" =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"model","max_context_tokens":8192},{"id_prefix":"model","max_context_tokens":4096}]}|}
  in
  match of_json json with
  | Ok manifest ->
    (match lookup manifest "model-v1" with
     | Some entry -> entry.max_context_tokens = Some 8192
     | None -> false)
  | Error _ -> false
;;

let%test "lookup: exact prefix match" =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"exact-model"}]}|}
  in
  match of_json json with
  | Ok manifest ->
    Option.is_some (lookup manifest "exact-model")
    && Option.is_none (lookup manifest "other-model")
  | Error _ -> false
;;

let%test "of_json: unknown entry fields return error" =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"m","base_label":"openai_chat"}]}|}
  in
  match of_json json with
  | Error msg -> String.equal msg "entry contains unknown field(s): base_label"
  | Ok _ -> false
;;

let%test "of_json: unknown root fields return error" =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"m"}],"future_field":"ignored"}|}
  in
  match of_json json with
  | Error msg -> String.equal msg "manifest contains unknown field(s): future_field"
  | Ok _ -> false
;;

let%test "of_json: unknown base preset returns error, not silent default" =
  (* A [base] value outside the closed preset vocab must fail closed at parse
     rather than resolve to [default_capabilities] downstream (RFC-OAS-034). *)
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"m","base":"not_a_preset"}]}|}
  in
  match of_json json with
  | Error _ -> true
  | Ok _ -> false
;;

let%test "set_global / clear_global: runtime override roundtrips" =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"runtime-override-token-9fX","base":"openai_chat"}]}|}
  in
  match of_json json with
  | Error _ -> false
  | Ok manifest ->
    (* Always restore process-global state on exit so a failure in this
       test cannot leak the override into siblings (order-dependent
       failure source). *)
    Fun.protect ~finally:clear_global (fun () ->
      set_global manifest;
      let observed_after_set =
        match global () with
        | Some entries ->
          List.exists (fun e -> e.id_prefix = "runtime-override-token-9fX") entries
        | None -> false
      in
      clear_global ();
      let observed_after_clear = Option.is_none (global ()) in
      observed_after_set && observed_after_clear)
;;

let%test "set_global installs runtime override and returns it from global ()" =
  let json =
    Yojson.Safe.from_string
      {|{"schema_version":1,"models":[{"id_prefix":"override-precedence-test"}]}|}
  in
  match of_json json with
  | Error _ -> false
  | Ok manifest ->
    Fun.protect ~finally:clear_global (fun () ->
      set_global manifest;
      match global () with
      | None -> false
      | Some m ->
        (* Option.get/Result.get_ok would raise on the unhappy path and
             skip [clear_global] — Fun.protect's finally restores state
             either way, but matching explicitly avoids relying on
             exception flow. *)
        Option.is_some (lookup m "override-precedence-test-v2"))
;;
