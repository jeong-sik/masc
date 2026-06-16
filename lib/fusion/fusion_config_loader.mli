(** Fusion — runtime.toml [fusion] 섹션을 핸들러 시점에 로드한다.

    런타임은 파싱된 Otoml 핸들을 캐시/노출하지 않으므로 ([Runtime_toml.parse_file]가
    즉시 [Runtime_schema.config]로 소비), 다른 옵셔널 섹션 소비자(voice_config)와 같이
    호출 시점에 파일을 다시 읽는다. fusion 호출은 희소한 out-of-band 경로라 매-호출
    파싱이 hot path가 아니다.

    경로 해석은 [Config_dir_resolver]의 SSOT API([inputs_from_env]/[resolve_with]/
    [runtime_toml_filename])를 재사용한다 — 경로 리터럴을 복제하지 않는다
    ([Keeper_runtime_config]의 내부 패턴과 동일).

    설계 SSOT: docs/rfc/RFC-0251-fusion-panel-judge-deliberation.md §9 *)

(** [load ~base_path]: workspace base path 기준으로 runtime.toml의 [fusion]을 로드.

    - runtime.toml 부재 → [Ok Fusion_config.disabled] (opt-in OFF 기본).
    - [fusion] 섹션 부재 → [Ok Fusion_config.disabled].
    - 파싱/검증 실패 → [Error msg] (silent default로 압축하지 않음). *)
val load : base_path:string -> (Fusion_policy.t, string) result
