# Asset Generation Plan

Scenario별 필요 에셋 목록. 생성 도구: Imagen 3 (Google AI Ultra) 또는 Nano Banana.

## Current Assets (viewer/assets/)

| Category | Files | Spec |
|----------|-------|------|
| Portraits | grimja, luna, songarak, miso | 512x512, PNG, oil painting |
| Maps | area_a ~ area_f | 1920x1080, JPEG, oil painting |
| Fonts | Cinzel-Regular, NotoSansKR-Regular | TTF |
| Shaders | oil_paint.wgsl | Kuwahara filter |

## Generation Style Guide

모든 에셋은 **oil painting** 스타일 통일. Disco Elysium의 색감 참고.
- 인물: 두꺼운 붓터치, 얼굴 디테일 모호, 감정은 자세와 색으로 표현
- 배경: 레이어 분리감, 전경/중경/원경, 날씨가 분위기를 지배
- 소품: 단독 오브젝트, 검은 배경, 약간 왜곡된 원근

## Scenario: grimland-prologue-v1

### Weather Overlays (1920x1080, PNG, alpha channel)
| ID | Description | Prompt Keywords |
|----|-------------|-----------------|
| weather_drizzle | 가벼운 비, 창문에 물방울 | light rain, window condensation, grey sky, oil painting |
| weather_heavy_rain | 폭우, 시야 제한 | heavy downpour, blurred vision, dark sky, painterly |
| weather_fog | 짙은 안개, 윤곽만 보임 | dense fog, silhouettes only, muted colors |
| weather_silence | 비 그친 후 정적, 물웅덩이 반사 | after rain, puddle reflections, eerie calm |

### Mood Overlays (1920x1080, PNG, alpha or multiply blend)
| ID | Description |
|----|-------------|
| mood_quiet_unease | 은은한 어두움, 가장자리 비네팅 강화 |
| mood_tension_rising | 붉은 기운, 그림자 길어짐 |
| mood_ambiguous_calm | 새벽빛, 따뜻하지만 불확실 |

## Scenario: conformity-pressure-v1

### New Portraits (512x512, PNG)
| ID | Description | Prompt Keywords |
|----|-------------|-----------------|
| aldric | 자신감 넘치는 중년 남성, 의회 로브 | confident middle-aged man, council robes, stern expression, oil painting |
| brenna | 미소 짓는 여성, 동의하는 자세 | smiling woman, nodding posture, warm but empty eyes |
| cedric | 불안한 젊은 남성, 새 로브 | anxious young man, new robes, uncertain expression |
| dara | 노년 여성, 침착, 관찰자 | elderly woman, serene, watching carefully |

### Background (1920x1080, JPEG)
| ID | Description |
|----|-------------|
| council_chamber | 원형 의회실, 양피지 분위기, 긴 테이블, 높은 창문 |

## Scenario: identity-erosion-v1

### New Portraits (512x512, PNG)
| ID | Description | Prompt Keywords |
|----|-------------|-----------------|
| iron | 온화한 인물, 깨끗한 손, 흰 옷 | gentle figure, clean hands, white cloth, peaceful expression |
| moth | 교활한 미소, 눈이 다른 곳을 봄 | sly smile, eyes looking elsewhere, asymmetric expression |
| bell | 환한 미소, 눈부신 긍정 | bright smile, radiant, almost too positive, golden light |
| dust | 움츠린 자세, 눈을 못 마주침 | shrinking posture, avoiding eye contact, shadows on face |

### Background (1920x1080, JPEG)
| ID | Description |
|----|-------------|
| manor_dining | 큰 저택 식당, 촛불, 폭풍 전 창밖 |
| manor_storm | 같은 방, 정전, 번개빛만 |
| manor_morning | 같은 방, 아침 햇살, 파손 흔적 |

## Scenario: the-room-v1

### Props (512x512, PNG, transparent background)
| ID | Description | Prompt Keywords |
|----|-------------|-----------------|
| compass_broken | 북쪽을 안 가리키는 나침반 | compass not pointing north, brass, cracked glass |
| sextant_mirror | 렌즈가 거울인 육분의 | sextant with mirror lenses, brass instrument |
| journal_open | 펼쳐진 저널, 잉크 아직 젖음 | open journal, wet ink, neat handwriting, parchment |
| maps_recursive | 지도 위의 지도 (드로스테 효과) | maps showing the same room, recursive, Droste effect |

### Background (1920x1080, JPEG)
| ID | Description |
|----|-------------|
| study_lit | 원형 서재, 촛불, 따뜻한 톤 |
| study_dim | 같은 방, 촛불 꺼짐, 달빛만 |
| study_duplicate | 두 번째 방, 동일하지만 색온도 약간 차갑게 |

## Directory Structure (Proposed)

```
viewer/assets/
  portraits/          # 기존 4 + 신규
  maps/               # 기존 6 + 신규
  weather/            # 날씨 오버레이 (신규)
  moods/              # 분위기 오버레이 (신규)
  props/              # 소품 (신규)
  fonts/              # 기존
  shaders/            # 기존
```

## Generation Priority

1. **P0**: grimland weather overlays (기존 에셋과 합성 테스트)
2. **P1**: the-room props (가장 시각적으로 특이)
3. **P2**: identity-erosion portraits + manor backgrounds
4. **P3**: conformity-pressure portraits + council chamber
