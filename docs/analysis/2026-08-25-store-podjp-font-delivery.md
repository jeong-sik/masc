# 스토어 · POD-JP 폰트 전달 구조 문제 (2026-08-25 조사)

`kidsnote-web-store` 의 폰트가 느린 경로로, 필요 이상으로, 중복해서 나가고 있다.
두 갈래(스토어 홈 / POD-JP 미리보기)로 조사했는데 **뿌리가 같다**.

조사 계기: 8/18 Mason 의 "스토어 홈 탭 진입 속도 저하" 신고와, 8/25 Rudy 의 "POD-JP
최종 미리보기 로더 4~5초" 보고.

---

## 1. 한 줄 요약

`public/fonts/` 에 있는 큰 폰트들이 **CDN 을 안 타고 앱 서버에서 직접 나간다.**
그 위에 (a) 스토어는 같은 폰트를 두 경로로 두 번 받고 (b) POD-JP 는 이모지 폰트
21.9MB 를 콘텐츠와 무관하게 항상 받는다.

이 구조는 **2026-01-26 PK-31525 (PR #921)** 부터다. 8/8 CDN 이전이나 이번 JP 작업과 무관하다.

---

## 2. 왜 CDN 을 안 타나

`next.config.mjs` 의 `assetPrefix: process.env.ASSETS_PATH` 는 **`_next/static/*` 에만**
적용된다. `public/` 에 놓인 파일은 Next 가 앱 서버에서 그대로 서빙한다.

| 위치 | 나가는 곳 | 캐시 |
|---|---|---|
| `lib/fonts/*` → next/font → `_next/static/media/` | CDN | immutable |
| `public/fonts/*` | 앱 origin | `max-age=0` |

`public/fonts/` 에 있는 것 (약 31MB):

```
public/fonts/TossFaceFont.ttf           12,730,928
public/fonts/NotoColorEmoji.ttf         10,673,480
public/fonts/PretendardJPVariable.woff2  5,730,460   (운영 미배포 — 404)
public/fonts/PretendardVariable.woff2    2,057,688
public/fonts/fonts.css                       2,580
```

`fonts.css` 가 이들을 리터럴 family 이름으로 `@font-face` 선언한다. 백엔드 Playwright
PDF 렌더링이 이 리터럴 이름에 의존하므로 **그냥 지울 수 없다** (`public/fonts/fonts.css:86` 주석).

---

## 3. 확정된 사실

### 3-1. 스토어 홈 — 같은 폰트를 두 번 받는다

진입 1회 폰트 **5.59MB / 6개** (서울 유선, 콜드 캐시, 실제 Chromium 측정).

```
2,057,688  CDN    _next/static/media/ff840cfebfb63b0c-s.p.woff2  (next/font, immutable)
2,057,688  origin /fonts/PretendardVariable.woff2                (fonts.css, max-age=0)
1,016,996  CDN    5ea664d2e56e7f74-s.p.ttf   ← HGSoftGGothicssi-80g   ┐
  330,968  CDN    c45538b7e4e4118e-s.p.ttf   ← SourceSerif SemiBold   │ 소비자 0
  330,584  CDN    e8c6aa3e74247fd4-s.p.ttf   ← SourceSerif Regular    │
   67,060  CDN    7473fd86ae9e9622-s.p.woff  ← Nunito-ExtraBold       ┘
```

- 위 두 파일은 **sha256 동일** (`9599f12fd42fc0bce1cd50b47a0c022e108d7aa64dd0d1bb0ed44f3282d900b4`)
- 렌더에 쓰이는 건 **origin 사본** — `pages/_app.tsx:43`, `components/GlobalStyles/GlobalStyles.tsx:24,46` 이
  리터럴 `'Pretendard'` 를 쓰고 이게 `fonts.css` 로 풀린다. CDN 사본은 preload 만 되고 안 쓰인다
- 미사용 4종은 `--font-hgsoft` / `--font-source-serif` / `--font-nunito` 를 **읽는 코드가 0건**.
  Kidsnotebook 컴포넌트는 전부 리터럴 이름으로 `fonts.css` 를 쓴다
- 파일 ↔ 원본 대응은 `lib/fonts/*` 와 **바이트 크기 정확 일치**로 확인

**효과 (회선 스로틀링, 각 3회 중앙값)** — 중복 사본 + 미사용 4종(전송 2.55MB)을 차단하고 측정:

| 회선 | FCP | 로딩 완료 |
|---|---|---|
| 4G (4Mbps/50ms) | 2,864ms → 1,612ms | 10,478ms → 5,404ms |
| 약한 LTE (1.6Mbps/150ms) | 6,868ms → 3,548ms | 26,363ms → 13,255ms |

`font-display: swap` 이라 렌더를 막지는 않지만 `rel="preload"` 가 붙어 있어서, 첫 화면에
필요한 JS·CSS 보다 먼저 대역폭을 가져간다. 그래서 회선이 좁으면 FCP 까지 끌려온다.

### 3-2. POD-JP 미리보기 — 이모지 폰트 21.9MB 를 항상 받는다

`https://store-kcsandbox-01.kidsnote.com/pod/kidsnotebook-jp/preview/<photobookId>` 3회 측정:

```
시작 → 완료      크기          파일                        호스트
2590 → 4182ms   11,947,921B   TossFaceFont.ttf            origin
2590 → 3962ms    9,951,183B   NotoColorEmoji.ttf          origin
1189 → 1571ms    5,730,760B   PretendardJPVariable.woff2  origin
 415 → 2568ms    (5개)        _next/static/media/*        CDN(.co)
```

마지막 폰트 완료 **4,182 / 4,354 / 4,550ms** — Rudy 가 보고한 "로더 4~5초" 와 일치.

**콘텐츠 의존이 아니라 무조건이다.** `components/KidsnotebookJp/utils/themeFonts.ts` 의
`getThemeFontFaceRequests()`:

```js
const faces: JpWebFont[] = [NOTO_SANS_JP_FACE];
if (display && display !== NOTO_SANS_JP_FACE) faces.push(display);
faces.push(PRETENDARD_JP_FACE, SYMBOLS_2_FACE, ...EMOJI_FACES);   // ← 조건 없음
```

테마 장식 face 만 `if` 가 붙고 `EMOJI_FACES` 는 무조건 들어간다. `text` 도 콘텐츠가 아니라
`face.sampleText` 고정값(대표 글리프 U+2728 SPARKLES)이다.

**이유**: 캡처 시점에 폰트가 미로드면 이모지가 폴백 글리프로 PDF 에 굳는다. 인쇄 충실도를
지키려고 강제 로드한다 (`themeFonts.ts` 주석, `containers/pod/kidsnotebook-jp/utils/fontsReady.ts`).

**결과**: 이모지를 안 쓴 책, 카오모지(`ツ` 같은 가나 문자 — JP 폰트가 덮는다)만 쓴 책도
21.9MB 를 똑같이 받는다.

### 3-3. 게이트가 CSS 설정을 덮는다

`lib/configs/next-font-jp.ts` 는 잘 설정돼 있다.

```js
display: 'swap',
preload: false,     // 주석: 기본값(true)은 7.2MB를 고우선순위 preload로 주입해
adjustFontFallback: false,   //     모바일 첫 진입 대역폭을 API·LCP와 경합시킨다
```

그런데 `containers/pod/kidsnotebook-jp/preview/index.tsx:163` 이
`waitForThemeFontsSettled(themeId)` 를 await 한다. `document.fonts.load()` 를 기다리므로
**`font-display: swap` 이 무력화**된다. CSS 로 고칠 수 없고 게이트를 손봐야 한다.

### 3-4. 운영 origin 이 샌드박스보다 느리다

`TossFaceFont.ttf` (12.7MB), **번갈아** 4회 (순차로 재면 회선 변동에 오염된다):

```
        운영                샌드박스           비율
run1   4.585s              1.395s            3.3x
run2   3.580s              1.259s            2.8x
run3   3.303s              1.508s            2.2x
run4   4.300s              2.434s            1.8x
```

둘 다 `cf-ray` 없음 — **CDN 없이 직접 서빙**. 샌드박스는 `Server: nginx`, 운영은 헤더 미노출.

→ 이 증상은 **운영 배포로 사라지지 않는다.** 오히려 더 크게 나올 수 있다.

### 3-5. CDN 존 플랜이 도메인별로 다르다

```
static.kidsnote.net    (운영)      ICN 서울      TTFB 111ms
static.kidsnote.co     (샌드박스)   HKG 홍콩      TTFB 545ms
contents.kidsnote.net  (운영)      ICN 서울      TTFB 101ms
contents.kidsnote.co   (샌드박스)   SIN 싱가포르   TTFB 538ms
```

8/19 인프라팀이 `kidsnote.net` 만 유료 플랜으로 올렸다. `kidsnote.co` 는 그대로다.
샌드박스 수치(TCP 183 / TLS 368 / TTFB 545)가 조치 전 운영(211 / 391 / 574)과 거의 같다.

**단, POD-JP 4~5초의 지배적 원인은 이게 아니다.** 이모지 폰트는 CDN 이 아니라 origin 에서 온다.

### 3-6. brotli 가 안 나간다

`static.kidsnote.net` 의 JS 자산:

```
Accept-Encoding: gzip                     → gzip,      203,227
Accept-Encoding: br                       → 압축 없음, 734,943
Accept-Encoding: zstd                     → 압축 없음, 734,943
Accept-Encoding: gzip, deflate, br, zstd  → gzip,      203,227   (브라우저 기본)
```

직접 압축하면 brotli 162,747 (gzip 대비 −19.9%). 초기 진입 자산 8개 합계 339KB → 280KB (−58KB).

Cloudflare 문서상 Pro·Business 기본은 Brotli 인데 gzip 이 나간다. 존 설정이거나, 업로드 시
이미 gzip 으로 압축해 올린 걸 Cloudflare 가 그대로 내보내는 것 중 하나.
<https://developers.cloudflare.com/speed/optimization/content/compression/> (2026-08-25 확인)

---

## 4. 미확정 / 열린 질문

| 항목 | 상태 |
|---|---|
| 샌드박스가 8/7 대비 3~4배 느려짐 | `themeFonts.ts` 주석에 `Tossface 0.45s / NotoColorEmoji 0.37s (2026-08-07, sandbox01)` 기록. 오늘은 1.6s / 1.4s. 원인 미조사 |
| `SYMBOLS_2_FACE` 크기 | next/font 서브셋이라 CDN 경로. 크기 자체는 미측정이나 문제 목록에서 제외 |
| 화면용 / 캡처용 게이트 분리 가능성 | **기각** — §10-2. 분리하면 화면(시스템 이모지)과 인쇄(Tossface)가 갈린다 |
| 로더 표시 시간 자체 | 폰트 완료 시각(4.2~4.6초)과 로더 해제 시각이 일치하는지는 **측정 안 함**. 시각이 겹친다는 것뿐 |
| 이모지 사용 책 비율 | 무조건 로드라 무관해졌지만, 개선 우선순위 판단에는 필요할 수 있음 |

---

## 5. 손댈 수 있는 것

### 스토어 홈

1. **미사용 3종 제거** — `lib/configs/next-font.ts` 의 `localFont()` **선언 자체**를 지운다.
   `GlobalStyles.tsx` 에서 import 만 지우면 안 된다 (§7 참조)
2. **렌더 폰트를 CDN 사본으로** — 리터럴 `'Pretendard'` → next/font family.
   `var(--font-pretendard)` 는 검증 필요 (§7 참조)
3. 완료 판정: **폰트 파일 2개 이하 / 전송 2.1MB 이하** (지금 6개 / 5.59MB)
4. 선례: `lib/configs/next-font-jp.ts` 가 `preload: false` + 게이트 방식으로 이미 정리돼 있다

### POD-JP

1. **콘텐츠에 실제로 이모지가 있을 때만** 강제 로드 — 21.9MB 가 대부분 사라진다.
   같은 조건이 화면·캡처 양쪽에 동일하게 옳다 (§10-2, 화면/캡처 분리는 기각)
2. **CDN 이전** — `public/fonts/` → `_next/static` 경로. 양은 그대로지만 운영에서 2~3배.
   `fonts.css` 와 BE PDF 렌더러가 `/fonts/` 경로에 묶여 있어 두 소비자를 같이 봐야 한다
3. **서브셋** — 이모지 폰트는 서브셋이 표준 해법. 사용자 입력이라 동적 서브셋 필요

### 인프라

1. `kidsnote.co` 존 플랜 — 샌드박스·CBT 가 운영과 다른 경로를 쓰는 동안 QA 에서 속도 판정이 어렵다
2. brotli — 존 설정인지 업로드 시 사전 압축인지 확인

---

## 6. 재현 방법

```bash
# CDN 존 응답 지점
for h in static.kidsnote.net static.kidsnote.co contents.kidsnote.net contents.kidsnote.co; do
  printf '%-24s ' "$h"; curl -sS "https://$h/cdn-cgi/trace" | rg '^colo='
done

# 운영 vs 샌드박스 origin — 반드시 번갈아 (순차는 회선 변동에 오염됨)
U1=https://store.kidsnote.com/fonts/TossFaceFont.ttf
U2=https://store-kcsandbox-01.kidsnote.com/fonts/TossFaceFont.ttf
for i in 1 2 3 4; do
  printf 'run%d 운영 %s 샌드 %s\n' "$i" \
    "$(curl -sS -o /dev/null -w '%{time_total}s' $U1)" \
    "$(curl -sS -o /dev/null -w '%{time_total}s' $U2)"
done

# 압축 협상 (상태 코드·크기 같이 볼 것)
for ae in identity gzip br zstd; do
  printf '%-10s ' "$ae"
  curl -sS -o /dev/null -D - -H "Accept-Encoding: $ae" \
    -w 'size=%{size_download}\n' \
    https://static.kidsnote.net/prod/fe/store/_next/static/chunks/pages/_app-225d6df5033c43fb.js \
    | rg -i '^content-encoding|size='
done
```

**POD-JP 화면 측정**은 샌드박스 세션이 필요하다.

```bash
cd <repo>/.worktrees/<podjp-branch>
mkdir -p .tmp/knqa && install -m 600 /dev/null .tmp/knqa/credentials
printf '<id>\n<pw>\n' > .tmp/knqa/credentials
KNQA_API=https://api-kcsandbox-01.kidsnote.com \
KNQA_STORE=https://store-kcsandbox-01.kidsnote.com \
  bash e2e/print-qa/knqa-login.sh && rm -f .tmp/knqa/credentials
set -a && . .tmp/knqa/env.sh && set +a
```

세션 수명 약 2시간. **만료가 인증 에러가 아니라 콘텐츠 대기 타임아웃으로 위장**한다 —
스켈레톤이 안 걷히면 하네스 버그를 의심하기 전에 재로그인부터.

env 키는 `PODJP_ACCESS_TOKEN` / `PODJP_SESSIONID` / `PODJP_CPSIG` /
`PODJP_CHILD_ID` / `PODJP_PHOTOBOOK_ID` (전부 `PODJP_` 접두).

측정은 Playwright 로 쿠키 3종(`access_token`·`sessionid`·`cpSignature_sessionid`,
domain `.kidsnote.com`)을 심고 Resource Timing 을 읽으면 된다.

---

## 7. 다음 세션이 반복하지 말 것

오늘 결론이 네 번 뒤집혔다. 전부 **측정 전에 이야기를 만든 지점**이었다.

1. **`GlobalStyles.tsx` 에서 import 만 지우면 폰트가 안 줄어든다.**
   직접 빌드해서 확인했다 — preload 링크는 5개 → 1개로 줄지만 실제 다운로드는 5개 그대로다.
   next/font 는 번들러 로더라 `lib/configs/next-font.ts` 가 import 되는 순간 그 안의
   `localFont()` **선언 전부**를 산출물로 뽑는다. 선언 자체를 지워야 한다.

2. **리터럴 → `var(--font-pretendard)` 는 그대로 하면 폰트가 죽는다.**
   로컬에서 변수가 `:root` 에서 빈 값이 되며 `font-family` 가 무효화돼 기본 폰트(Times)로
   떨어졌다. 로컬 환경 오염(`fonts.css` 404) 가능성이 있어 단정은 못 하지만,
   `fonts.css`(head link)와 GlobalStyles(body emotion)가 같은 변수를 다른 값으로 정의해
   **순서에 기대는 구조**인 건 확실하다. 검증 없이 바꾸지 말 것.

3. **`curl -I` 로 헤더만 보면 상태 코드가 안 보인다.**
   `PretendardJPVariable.woff2` 의 `no-store` 헤더를 "캐시 금지"로 읽었는데, 실제로는
   운영에서 **404 HTML 페이지**의 헤더였다. 항상 `http_code` / `content_type` / `size` 를 같이 볼 것.

4. **한 환경의 결론을 다른 환경에 옮기지 말 것.**
   샌드박스 origin 은 14MB/s 로 빨라서 "CDN 옮겨도 별 차이 없다"가 맞았는데, 운영 origin 은
   그 절반 이하라 결론이 뒤집힌다.

5. **순차 측정 금지.** 운영 2.5s / 샌드 0.7s 로 쟀다가 나중에 3.9s / 1.6s 가 나왔다.
   절대값은 둘 다 2배 넘게 변했는데 **비율은 유지**됐다. 번갈아 재야 한다.

6. **크기·해시는 대상 브랜치에서 읽을 것.** 폰트 크기를 다른 워크트리에서 읽어
   `MPLUS 4종 4.16MB` 라고 했는데 freezing 브랜치에는 **5종 5.30MB** 였다.

7. **타이밍으로 메커니즘을 추론하지 말 것.** 이모지 폰트가 FCP 이후 2.6초에 시작하길래
   "콘텐츠 의존"이라고 추론했는데, 코드를 보니 게이트 실행 시점이었을 뿐 **무조건 로드**였다.

---

## 8. 관련 코드 경로

```
next.config.mjs:40                                    assetPrefix (= _next/static 만)
lib/configs/next-font.ts                              KR 폰트 5종 선언 (preload 켜짐)
lib/configs/next-font-jp.ts                           JP 폰트 선언 (preload:false + 게이트) ← 선례
components/GlobalStyles/GlobalStyles.tsx:5-8,15-18,24,46   미사용 import + 리터럴 Pretendard
pages/_app.tsx:43                                     리터럴 Pretendard
pages/_document.tsx:48 / app/layout.tsx:61            fonts.css 전역 로드
public/fonts/fonts.css                                리터럴 @font-face (BE PDF 렌더링용)
components/KidsnotebookJp/utils/themeFonts.ts         getThemeFontFaceRequests (EMOJI_FACES 무조건)
containers/pod/kidsnotebook-jp/utils/fontsReady.ts    waitForThemeFontsSettled
containers/pod/kidsnotebook-jp/preview/index.tsx:163  게이트 호출 (최종 미리보기)
containers/pod/kidsnotebook-jp/context/PageLoadingContext.tsx   로더 (해제는 pathname 변경, 10초 상한)
```

---

## 9. 티켓 · 커뮤니케이션 (2026-08-25 기준)

| | |
|---|---|
| PK-38394 | `[FE] 스토어 — 탭 진입 초기 로딩 성능 개선`. Open, 정다빈. 5태스크 9.5일 묶음. 측정 코멘트 등록함(`180977`) |
| PK-31525 / PR #921 | `public/fonts/` 구조가 처음 들어온 곳 (2026-01-26) |
| PR #1437 | `feature/freezing-2026.825.0/main` → `develop`. Draft. 배포 후 Ready → 머지 → #1405 닫기 |
| PR #1405 | `[Gitflow] POD-JP (WIP)` → develop. 내용이 freezing 에 전부 포함(파일 100/100 일치)되어 중복 |
| Slack `C08EL5L2ZEH` | 통합이슈 P3. 리전 이슈 종결 + 폰트 분리 제안 + brotli 요청 전송함 |
| Slack `C08P2KPRF6V` | POD-JP. 1차(존 차이) → 정정(실측, origin 폰트가 지배적) 전송함 |

**8/19 인프라 조치**(steven.d): `kidsnote.net` 유료 플랜 전환, Smart Tiered Cache,
`Timing-Allow-Origin` 헤더 추가. `kidsnote.co` 는 대상 아님. **티켓 없이 Slack 스레드에만 기록됨.**

---

## 10. 해결 방법 설계 (같은 날 오후, freezing-2026.825.0 기준 추가 확인)

Jeffrey 결정(스레드 15:03·15:09): 운영 회귀가 아니므로 오늘 배포 먼저, 개선은 배포 후.
따라서 아래는 전부 배포 후 별도 PR 트랙이다.

### 10-1. 소비면 전수 — 이모지 로드는 미리보기만의 문제가 아니다

`getThemeFontFaceRequests()`(EMOJI_FACES 무조건 포함)는 두 갈래로 소비된다:

```
waitForThemeFontsSettled (게이트 — await, 로더를 잡고 있음)
  containers/pod/kidsnotebook-jp/preview/index.tsx:163              최종 미리보기
  containers/pod/kidsnotebook-jp/preview/cover/usePrintCoverData.ts:160   표지
useThemeMeasureFont (check + load — load 가 다운로드를 시작함)
  preview/index.tsx · editor/preview/KidsnotebookPreview.tsx
  editor/hooks/useKidsnotebookEditorData.ts · confirm/KidsnotebookConfirm.tsx
  edit-mode-select/KidsnotebookEditModeSelect.tsx
  components/KidsnotebookJp/components/inner-page/InnerPageContent.tsx
```

편집기·확정·모드선택 진입에서도 21.9MB 다운로드가 시작된다 (로더로 막지는 않지만
대역폭을 쓰고 `isSettled` 지연으로 페이지 수 확정이 늦어진다). 고칠 곳은
`getThemeFontFaceRequests` 한 곳이고, 소비면 전부가 같이 좋아진다.

### 10-2. 방향: 화면/캡처 분리가 아니라 콘텐츠 조건부

§4 의 "화면용/캡처용 게이트 분리"는 기각한다. 분리하면 화면은 시스템 이모지(Apple),
인쇄는 Tossface 로 갈려 T/C(화면-인쇄 동일성)를 스스로 깬다. 대신 **콘텐츠에 이모지가
있을 때만** EMOJI_FACES 를 요청 목록에 넣는다 — 같은 조건이 화면·캡처 양쪽에 같은
이유로 옳고, 컨텍스트 감지(webdriver 판별 등)가 필요 없다.

- 시그니처: `getThemeFontFaceRequests(slug, size, contentText?)`.
  `contentText` 생략 = 현행(전부 로드) — 못 옮긴 호출부는 느릴 뿐 안전하다.
- 판정: `/[\p{Extended_Pictographic}\p{Regional_Indicator}️⃣]/u` 계열.
  오탐(불필요 로드)은 안전, 미탐만 위험 — 넓게 잡는다. 텍스트 소스는 필드 나열 대신
  `JSON.stringify(workspaceData)` 스캔이 누락 0 (키·URL 에 이모지 없으므로 과잉도 무해).
- 카오모지(`ツ` 등)는 가나 문자라 JP face 가 덮는다 — 미탐 아님.
- 효과: 이모지 없는 책은 21.9MB → 0. 남는 바닥은 PretendardJP 5.7MB(origin) +
  CDN faces(샌드박스 실측 완료 시각 2.57s) — 로더 4.2~4.6s → 약 2.6s.

### 10-3. CDN 이전 실행 경로 — 업로더 선례가 이미 있다

`app.config.js` 가 `.next/static` 과 함께 **`public/locales` 를 이미 R2 에 업로드한다**
(`Dockerfile.gha` USE_R2, PK-35103). `public/fonts` 추가는 같은 패턴이다.

- `fonts.css` 는 빌드 시 생성으로 바꿔 `src` 만 `${ASSETS_PATH}/fonts/...` 를 가리키게
  한다. link href(`/fonts/fonts.css`)와 family 리터럴 이름은 그대로 → **BE 무변경**.
- CORS: next/font 파일이 이미 static.kidsnote.net 에서 브라우저로 로드되고 있으므로
  존에 ACAO 가 있다. 구현 시 `curl -H 'Origin: https://store.kidsnote.com'` 재검증.
- 캐시: `public/fonts` 파일명은 해시가 아니다 → 버전 프리픽스(`/fonts/v2/`) 또는
  빌드 스코프 키 필수. 없으면 파일 교체 시 CDN 스테일.

### 10-4. 운영 cap 산술 — 배포 직후 관측 포인트

`FONTS_READY_CAP_MS = 5000`. 운영 origin 실측이 TossFace 12.7MB 단독 3.3~4.6s 이므로
27.6MB 동시 다운로드는 cap 을 넘길 가능성이 높다.

- 사용자 화면: 로더가 cap+settle(~5.3s)에서 잘리고, 늦게 도착한 폰트는 화면에서
  스왑된다. 깨지지 않고 늦다.
- BE 캡처: 서버 대역폭이라 별개. cap 도달 시 `[PK-37701] print fonts settle capped`
  reportError 가 남는다 — **배포 후 Datadog 에서 이 문자열이 지표**. cray 팀 PDF
  샘플링에 이모지 포함 책 1권 이상 포함을 요청할 것.

### 10-5. 배너 질문 (Rudy 15:35) — FE 배포와 무관

스토어 홈 배너는 `GET /api/v1/main/banner/?type=5` 응답을 그대로 렌더한다
(`containers/store-main/hooks/queries/useGetBanner.ts`). FE 에 국가/JP 필터 없음.
freezing 브랜치도 배너 코드 무변경 (`git diff develop...freezing -- containers/store-main/`
8파일, 배너 경로 없음).

→ 실서버에서 안 보이는 것은 BE 타겟팅 평가 결과이고, 오늘 FE 배포로 자연히
나타난다고 보장할 수 없다. 확인 경로: 타겟 계정 기준 배너 API 응답에 해당 배너가
있는지 (어드민 세팅 + BE). 단 배너 랜딩(JP 상품 상세)은 새 FE 라우트라 배포 전
실서버에선 어차피 열리지 않는다 — 노출과 랜딩은 별개 문제.

### 10-6. 실행 순서

| 순서 | 내용 | 범위 |
|---|---|---|
| 오늘 | 배포·라이브 QA 우선(Jeffrey 지시), 배너 질문 답변, Datadog cap 로그 모니터 | — |
| PR 1 | 이모지 조건부 로드 (§10-2) + 판정 유닛테스트 | FE only, themeFonts·fontsReady·호출부 |
| PR 2 | `public/fonts` → R2 (§10-3) + PDF 샘플링 검증 | FE + 배포설정, BE 협조 |
| 백로그 | 이모지 TTF→woff2 실측, 동적 서브셋 RFC, kidsnote.co 존(인프라), brotli(요청됨) | — |
| 별도 | 스토어 홈 미사용 폰트·중복 다운로드는 PK-38394 트랙 (실측 코멘트 전달됨) | — |
