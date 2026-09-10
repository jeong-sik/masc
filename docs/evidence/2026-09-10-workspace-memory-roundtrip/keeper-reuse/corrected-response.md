같은 제안 ID로 전체 내용을 다시 조회했습니다(`keeper_workspace_memory_read`, 읽기 전용). **이전 결론은 틀렸고 정정합니다. 원문은 저장되어 있어서 읽을 수 있었습니다.**

## 정정 내용

- sources 4개(s1–s4)의 **실제 팩트 텍스트가 모두 저장**되어 있었고, 출처 저장소 종류는 전부 `"ordinary"`입니다. 원문 접근이 불가한 상태가 아니었습니다.
- 제가 앞서 `gaps`를 근거로 "원문 접근 불가"라 했던 것은 오독입니다. `gaps`는 각 Keeper의 `source_bound` 저장소에 관측이 없다(`missing`)는 뜻일 뿐, **`ordinary` 저장소에 저장된 출처 팩트 자체가 없다는 뜻이 아닙니다.** 저장소 종류의 부재와 원문의 부재를 뭉뚱그렸던 것입니다.

## 확인한 sources 실제 텍스트 (모두 `store: "ordinary"`)

| source_id | Keeper | 원문 텍스트 |
|---|---|---|
| s1 | writer | "Report R was generated as PDF." |
| s2 | reviewer | "Report R contains plain Markdown bytes; PDF generation failed." |
| s3 | analyst (fact_index 0) | "Measurement M was 12 seconds." |
| s4 | analyst (fact_index 1) | "Correction from the original log: measurement M was 21 seconds, not 12." |

- 상충(s1 대 s2): 전체 원문에서도 여전히 양립 불가이며, 제안은 이를 미해결 conflict로만 둡니다.
- 정정(s3 → s4): 원문 자체에 "원래 로그 기준 정정, 12초가 아니라 21초"라는 문구가 있어, 앞서 본 shared claim이 이 텍스트에 근거하고 있음을 직접 확인했습니다.

## 저장 사실과 독립 검증의 구분 (유지)

- **직접 확인한 사실**: 위 4개 원문 텍스트, 저장소 종류(`ordinary`), 스냅샷 해시 바인딩, 그리고 각 팩트의 origin 메타데이터(`kind: "authored"`, `trace_id: "synthetic-scenario"`).
- **독립 검증 여부**: 여전히 분리해야 합니다. 제안 상태는 `model_proposed`, `semantic_verification: "not_performed"`이고, 네 팩트 모두 authored(작성된 주장)로 기록되어 있습니다. 원문이 저장되어 읽을 수 있다는 것과, 그 내용이 제3자적으로 검증되었다는 것은 다릅니다. 따라서 "PDF인지 Markdown인지", "21초 정정의 진위"는 어느 쪽도 독립 검증된 사실이 아닙니다.
- **여전히 미확인**: writer/reviewer/analyst의 `source_bound` 저장소에는 관측이 없으므로, authored 원문을 뛰어넘는 별도 근거는 이 공간에 존재하지 않습니다.
