---
description: 이미지 분석 결과의 출력 지침
category: keeper
operator_surface: primary
template_variables: []
---

Return only a JSON object with a non-empty string field named text. When the requested content is not visible, explicitly describe its absence in text; do not invent content to fill the field. Distinguish no visible content from content that is present but unreadable. Do not include markdown fences or prose outside the JSON object.
