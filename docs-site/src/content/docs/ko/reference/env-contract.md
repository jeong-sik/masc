---
title: 환경 변수 계약 (Env Contract)
description: MASC 시스템이 인식하고 우선순위를 부여하는 환경 변수 규격입니다.
---

MASC는 TOML 기반 설정을 기본으로 하되, 보안 토큰 및 실행 환경에 필요한 최소한의 환경 변수를 인식합니다.

## 핵심 환경 변수 목록

| 변수명 | 설명 | 기본값 / 예시 |
|---|---|---|
| `MASC_BASE_PATH` | MASC 작업 공간(`.masc/`)이 위치할 기준 루트 경로 | 현재 작업 디렉터리 (`.`) |
| `MASC_PORT` | MASC HTTP 및 MCP 서버 포트 | `8935` |
| `MASC_HOST` | 서버 바인딩 주소 | `127.0.0.1` |
| `MASC_LOG_LEVEL` | 로깅 레벨 (`debug`, `info`, `warn`, `error`) | `info` |

---

## Provider API 키

| 변수명 | 대상 프로바이더 |
|---|---|
| `ANTHROPIC_API_KEY` | Anthropic Claude 모델 구동용 |
| `OPENAI_API_KEY` | OpenAI GPT/Codex 모델 구동용 |
| `ELEVENLABS_API_KEY` | 음성 인터페이스(TTS/Voice) 구동용 |

> 📌 **원칙 (헌법 조항)**: 무분별한 환경 변수 증식(Env Var Sprawl)은 지양하며, 영속적인 설정값은 `.masc/config/*.toml`을 단일 진실 공급원(SSOT)으로 사용합니다.
