(** Env-var parsing helpers for the keeper memory bank.

    The public helper names are kept for call-site stability, but parsing now
    delegates to the config-layer memory env parser shared with Memory OS. *)

let memory_env_opt = Env_config_memory.env_opt
let memory_env_int_logged = Env_config_memory.get_int_logged
let memory_env_float_logged = Env_config_memory.get_float_positive_logged

let memory_env_bool_logged name ~default =
  Env_config_memory.get_bool_logged name ~default
;;

let memory_llm_summary_enabled () =
  memory_env_bool_logged "MASC_KEEPER_MEMORY_LLM_SUMMARY" ~default:false

(* RFC keeper-memory-consolidation Stage 1: memory_bank long-term inject의
   kill-switch. default=true → 동작 변화 0 (기존 inject 유지). 키 정의를 여기
   한 곳에 모아 keeper_turn 가드와 테스트가 같은 함수를 호출하게 한다 (SSOT). *)
let bank_longterm_inject_enabled () =
  memory_env_bool_logged "MASC_KEEPER_BANK_LONGTERM_INJECT" ~default:true

(* RFC keeper-memory-bank-write-reduction (parent: keeper-memory-consolidation
   Stage 3): explicit/tool-result/voice writes to the memory bank kill-switch.
   default=true → 동작 변화 0 (기존 write 유지). Setting it false stops feeding
   the deprecated append-only bank; continuity is unaffected because it comes
   from OAS checkpoint + typed MASC metadata, not .memory.jsonl. This is an
   explicit operator gate, not a heuristic that decides which memories survive
   (spec/12-memory-systems.md §Compaction) — when off, every writer skips
   uniformly and reports the skip through a typed outcome. *)
let bank_write_enabled () =
  memory_env_bool_logged "MASC_KEEPER_MEMORY_BANK_WRITE" ~default:true

let max_memory_text_length () =
  match memory_env_opt "MASC_KEEPER_MEMORY_MAX_LENGTH" with
  | None -> 4096
  | Some raw ->
      (match int_of_string_opt raw with
       | Some n when n > 0 -> n
       | _ -> 4096)
