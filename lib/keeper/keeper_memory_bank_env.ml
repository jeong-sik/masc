(** Env-var parsing helpers for the keeper memory bank.

    Four primitives — [memory_env_opt] strips empty/whitespace,
    [memory_env_int_logged] adds int parsing with WARN-on-invalid,
    [memory_env_float_logged] adds positive-float parsing, and
    [memory_env_bool_logged] adds bool parsing with the same shape —
    plus the two .mli-exposed consumers [memory_llm_summary_enabled]
    and [max_memory_text_length] that use them.

    Pure helpers (modulo [Log.Keeper.warn] on bad input). All callers
    are internal to [Keeper_memory_bank]; verbatim extract preserves
    the qualified in-module names via 5 parent aliases. *)

let memory_env_opt name =
  match Env_config_core.raw_value_opt name with
  | None -> None
  | Some raw ->
      let s = String.trim raw in
      if s = "" then None else Some s

let memory_env_int_logged name ~default =
  match memory_env_opt name with
  | None -> default
  | Some raw ->
      (match int_of_string_opt raw with
       | Some n -> n
       | None ->
           Log.Keeper.warn
             "invalid %s=%S; using default %d"
             name raw default;
           default)

let memory_env_float_logged name ~default =
  match memory_env_opt name with
  | None -> default
  | Some raw ->
      (match float_of_string_opt raw with
       | Some n when n > 0.0 -> n
       | _ ->
           Log.Keeper.warn
             "invalid %s=%S; using default %.3f"
             name raw default;
           default)

let memory_env_bool_logged name ~default =
  match memory_env_opt name with
  | None -> default
  | Some raw ->
      match String.lowercase_ascii raw with
      | "1" | "true" | "yes" | "on" | "enabled" -> true
      | "0" | "false" | "no" | "off" | "disabled" -> false
      | _ ->
          Log.Keeper.warn
            "invalid %s=%S; using default %b"
            name raw default;
          default

let memory_llm_summary_enabled () =
  memory_env_bool_logged "MASC_KEEPER_MEMORY_LLM_SUMMARY" ~default:false

(* RFC keeper-memory-consolidation Stage 1: memory_bank long-term inject의
   kill-switch. default=true → 동작 변화 0 (기존 inject 유지). 키 정의를 여기
   한 곳에 모아 keeper_turn 가드와 테스트가 같은 함수를 호출하게 한다 (SSOT). *)
let bank_longterm_inject_enabled () =
  memory_env_bool_logged "MASC_KEEPER_BANK_LONGTERM_INJECT" ~default:true

let max_memory_text_length () =
  match memory_env_opt "MASC_KEEPER_MEMORY_MAX_LENGTH" with
  | None -> 4096
  | Some raw ->
      (match int_of_string_opt raw with
       | Some n when n > 0 -> n
       | _ -> 4096)
