# MASC v2 — Keeper Agent 대시보드 시안

**상태**: 디자인 시안 (design mockup). 구현 상태를 나타내지 않는다.
**생성일**: 2026-07-04
**출처**: standalone HTML export (`MASC Keeper Agent (standalone)`). 원본 HTML은 base64 이미지 인라인으로 약 23MB라 저장소에 커밋하지 않는다. 이 문서는 렌더링 스크린샷 1장으로 화면 구성을 기록한다.

![MASC v2 Keeper Agent 대시보드 시안](./assets/2026-07-04-masc-v2-keeper-agent.png)

## 화면 구성

세 열(column) 레이아웃이다.

| 영역 | 내용 |
|------|------|
| **좌측 레일** | Keeper roster. 상태별 그룹(실행 중 / 대기 / 중지)과 상태 배지(Running, Paused, Compacting, Draining, Overflowed, Crashed, Dead). 상단에 필터 탭(전체 / 실행 / 주의)과 정렬. |
| **중앙** | 선택한 Keeper의 턴 상세. 작업 과정을 단계별로 표시(THINKING / REASONING / TOOL), tool 실행 시간, OCaml 코드 블록/diff, 경고 박스, 검증 상태. 하단에 메시지 입력. |
| **우측 패널** | 런타임 정보(모델 라벨, 컨텍스트 한도, 샘플링 파라미터, capability 배지), 컨텍스트 사용률과 compact 컨트롤, 컴팩션 스냅샷 / 메모리 보기, 소유 태스크(상태 배지 포함). |

## 대응 관계 (시안 ↔ 현재 대시보드)

시안의 좌측 레일 surface 구성은 현재 대시보드의 `Keepers` surface에 대응한다. 대시보드 surface/section의 정본 정의는 `dashboard/src/config/navigation.ts`(`DASHBOARD_SURFACES`, `DASHBOARD_SECTION_ITEMS`)에 있다. README의 `## Dashboard` 표를 함께 참고한다.

시안에 표시된 keeper 이름·모델 라벨·태스크 ID·수치는 목업 값이며 운영 데이터가 아니다.

## 인터랙티브 원본

원본은 클릭 가능한 standalone HTML이다. 저장소에는 정적 스크린샷만 둔다. 인터랙티브 버전이 필요하면 원본 HTML을 브라우저로 직접 열거나 별도 호스팅으로 공유한다.
