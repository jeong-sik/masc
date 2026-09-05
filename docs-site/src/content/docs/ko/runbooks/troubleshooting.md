---
title: 자주 발생하는 문제 및 복구 (Troubleshooting)
description: 포트 충돌, 락 파일 잔존, 모델 레이트 리밋 등 운영 중 마주치는 문제들의 진단과 복구 절차
---

## 1. 포트 8935가 이미 사용 중인 경우

MASC 서버가 비정상 종료된 후 포트가 점유되어 구동에 실패할 수 있습니다.

```bash
# 8935 포트 사용 프로세스 확인
lsof -i :8935

# 기존 프로세스 종료
kill -9 <PID>
```

---

## 2. 작업 공간 락(Lock) 및 스냅샷 복구

작업 저장소(`.masc/`)의 상태 파일이 손상되었거나 충돌이 발생한 경우:

```bash
# 상태 검증 스크립트 실행
scripts/verify-workspace-integrity.sh

# 백업 스냅샷으로부터 복구
cp .masc/recovery/snapshot-latest.jsonl .masc/states/active.jsonl
```

> ⚠️ **주의**: 헌법 원칙에 따라 복구 스냅샷은 읽기 전용 진단 용도이며, 임의로 변조된 상태를 강제 주입하지 않습니다.

---

## 3. LLM API Rate Limit 발생 시

Keeper가 연속적인 턴을 돌며 API 레이트 리밋에 걸린 경우:
- MASC 런타임이 자동으로 차순위 Provider(예: Anthropic Claude → OpenAI Codex → 로컬 모델)로 Failover를 시도합니다.
- TUI의 상태 바에서 현재 활성화된 Active Provider를 실시간으로 확인할 수 있습니다.
