# 색상과 다이어그램

노드 색상은 `classDef`와 `style`, 연결선은 `linkStyle`로 지정합니다.
지정한 색은 밝은·어두운 터미널에서도 유지됩니다. 기본 노드와 그룹은
터미널 팔레트에 맞춰 표시됩니다. 의미는 색상과 함께 이름·모양·선으로 구분하세요.

## 작업 흐름

```mermaid
flowchart LR
 subgraph work[작업 상태]
  A[요청 접수]:::pending --> B{검토}:::review
  B -->|통과| C([완료]):::done
  B -.->|보완| D[재시도]:::retry
 end
 classDef pending fill:#dbeafe,stroke:#2563eb,color:#172554,stroke-width:2px
 classDef review fill:#fef3c7,stroke:#d97706,color:#451a03,stroke-width:2px
 classDef done fill:#dcfce7,stroke:#16a34a,color:#052e16,stroke-width:2px
 classDef retry fill:#fee2e2,stroke:#dc2626,color:#450a0a,stroke-width:2px
 linkStyle 0 stroke:#60a5fa,stroke-width:3px
```

## 기본 테마와 그룹 색상

```mermaid
flowchart LR
 subgraph plain[터미널 기본 테마]
  E[기본 노드] --> F[다른 노드]
 end
 subgraph custom[작성한 그룹 색상]
  G[검토 요청] --> H[처리]
 end
 F --> G
 style custom fill:#dbeafe,fill-opacity:1,stroke:#2563eb,color:#172554,stroke-width:2px
 linkStyle 1,2 stroke:#64748b,stroke-width:2px
```

## 시퀀스

```mermaid
sequenceDiagram
 participant U as 사용자
 participant K as Keeper
 participant A as 아티팩트
 U->>K: 결과 문서 요청
 activate K
 K->>A: 문서 게시
 A-->>K: 저장 확인
 K-->>U: 문서와 다이어그램
 deactivate K
```

## 일정

```mermaid
gantt
 title 아티팩트 개선 일정
 dateFormat YYYY-MM-DD
 section 구현
 색상과 테마 :done, colors, 2026-10-25, 1d
 다이어그램 검증 :active, qa, after colors, 1d
 section 검토
 독립 리뷰 :review, after qa, 1d
```

## 마인드맵

```mermaid
mindmap
 root((MASC))
  문서
   본문
   표
  다이어그램
   색상
   테마
  미리보기
   확대
   이동
```

## 원형 차트

```mermaid
pie title 예제 작업 분포
 "완료" : 6
 "검토" : 3
 "대기" : 2
```

## 막대 차트

```mermaid
xychart-beta
 title "예제 처리량"
 x-axis [Mon, Tue, Wed, Thu]
 y-axis "작업 수" 0 --> 10
 bar [4, 7, 6, 9]
```

문서에서 `Ctrl-O`로 그림을 열고, `,`와 `.`로 그림을 선택할 수 있습니다.
Kitty 그래픽을 지원하는 터미널에서는 `+`/`-` 확대, 방향키 이동,
`0` 전체 맞춤, `v` 원문 전환을 사용할 수 있습니다.
