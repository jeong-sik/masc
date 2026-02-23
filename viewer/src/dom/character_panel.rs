use bevy::prelude::*;

use crate::assets;
use crate::dom::escape::html_escape;
use crate::game::components::{Actor, Skill};
use crate::game::state::TurnProgressState;
use wasm_bindgen::closure::Closure;
use wasm_bindgen::JsCast;

/// Snapshot of actor state used for change detection.
/// Re-render only fires when this changes.
#[derive(Clone, PartialEq)]
pub struct ActorSnapshot {
    id: String,
    hp: i32,
    hp_known: bool,
    max_hp_known: bool,
    mp: i32,
    mp_known: bool,
    max_mp_known: bool,
    is_dead: bool,
    atk_known: bool,
    def_known: bool,
    int_known: bool,
    luck_known: bool,
    buff_count: usize,
    debuff_count: usize,
    skill_count: usize,
    condition_count: usize,
    equip_count: usize,
    relation_count: usize,
    contribution_score: i32,
    contribution_last_reason: String,
    contribution_reasons_fingerprint: String,
    relationship_fingerprint: String,
}

/// Tracks the last known state so we only re-render on change.
#[derive(Resource, Default)]
pub struct CharacterPanelCache {
    pub last_snapshot: Vec<(String, i32, bool, bool, bool, bool, bool)>,
    pub last_full: Vec<ActorSnapshot>,
    pub last_progress_signature: String,
}

pub(crate) const DEFAULT_ACTOR_INSPECTOR_EMPTY_MESSAGE: &str = "파티원을 선택하면 상세 정보가 표시됩니다.";
pub(crate) const DEFAULT_ACTOR_INSPECTOR_NO_DIALOGUE_MESSAGE: &str = "최근 대사 없음";

/// Determines HP bar color class based on percentage.
fn hp_class(hp: i32, max_hp: i32) -> &'static str {
    let pct = if max_hp > 0 { hp * 100 / max_hp } else { 0 };
    match pct {
        0..=25 => "critical",
        26..=60 => "wounded",
        _ => "healthy",
    }
}

/// Determines MP bar color class based on percentage.
fn mp_class(mp: i32, max_mp: i32) -> &'static str {
    let pct = if max_mp > 0 { mp * 100 / max_mp } else { 0 };
    match pct {
        0..=20 => "mp-depleted",
        21..=50 => "mp-low",
        _ => "mp-full",
    }
}

fn parse_bool_attr(value: Option<&str>) -> bool {
    value
        .map(|value| value.trim())
        .filter(|value| !value.is_empty())
        .is_some_and(|value| matches!(value, "1" | "true" | "on" | "yes"))
}

fn metric_text(current: i32, current_known: bool, max: i32, max_known: bool) -> String {
    if current_known {
        if max_known {
            format!("{current} / {max}")
        } else if max > 0 {
            format!("{} / 미확인 최대", current)
        } else {
            current.to_string()
        }
    } else {
        "미확인".to_string()
    }
}

fn metric_text_class(current_known: bool, max_known: bool) -> &'static str {
    if !current_known {
        "actor-metric-unknown"
    } else if max_known {
        "actor-metric-known"
    } else {
        "actor-metric-partial"
    }
}

fn known_stat_text(value: i32, known: bool) -> String {
    if known {
        value.to_string()
    } else {
        "-".to_string()
    }
}

/// Returns a class icon symbol for visual identity in the party panel.
fn class_icon(class: &str) -> &'static str {
    match class.to_lowercase().as_str() {
        "fighter" | "warrior" | "knight" | "paladin" => "\u{2694}\u{FE0F}",
        "wizard" | "mage" | "sorcerer" => "\u{1F52E}",
        "rogue" | "thief" | "assassin" | "ranger" => "\u{1F5E1}\u{FE0F}",
        "cleric" | "priest" | "healer" => "\u{2728}",
        "bard" => "\u{1F3B6}",
        "druid" => "\u{1F33F}",
        "monk" => "\u{1F94B}",
        _ => "\u{1F6E1}\u{FE0F}",
    }
}

/// Normalizes class name to a CSS-safe identifier for data-class attribute.
fn class_slug(class: &str) -> String {
    class
        .to_lowercase()
        .replace(|c: char| !c.is_ascii_alphanumeric(), "-")
}

fn dom_safe_id(value: &str) -> String {
    let mut out = String::new();
    let mut prev_hyphen = false;
    for ch in value.trim().chars() {
        let ch = ch.to_ascii_lowercase();
        if ch.is_ascii_alphanumeric() || ch == '_' || ch == '-' {
            out.push(ch);
            prev_hyphen = false;
        } else {
            if !prev_hyphen && !out.is_empty() {
                out.push('-');
                prev_hyphen = true;
            }
        }
    }
    let collapsed = out.trim_matches('-').to_string();
    let normalized = if collapsed.is_empty() {
        "actor".to_string()
    } else {
        collapsed
    };
    if normalized.chars().next().is_some_and(|ch| ch.is_ascii_digit()) {
        format!("a-{}", normalized)
    } else {
        normalized
    }
}

fn ensure_unique_dom_id(base: &str, seen: &mut std::collections::HashSet<String>) -> String {
    if seen.insert(base.to_string()) {
        return base.to_string();
    }
    for suffix in 2..1000 {
        let candidate = format!("{base}-{suffix}");
        if seen.insert(candidate.clone()) {
            return candidate;
        }
    }
    base.to_string()
}

/// Icon for a condition name.
fn condition_icon(name: &str) -> &'static str {
    match name.to_lowercase().as_str() {
        "poisoned" => "\u{2620}\u{FE0F}",
        "stunned" => "\u{1F4AB}",
        "charmed" => "\u{1F496}",
        "frightened" => "\u{1F631}",
        "blinded" => "\u{1F576}\u{FE0F}",
        "paralyzed" => "\u{26A1}",
        "prone" => "\u{1F938}",
        "restrained" => "\u{26D3}\u{FE0F}",
        "invisible" => "\u{1F47B}",
        "blessed" => "\u{2728}",
        "burning" => "\u{1F525}",
        "frozen" | "cold" => "\u{2744}\u{FE0F}",
        "sleeping" | "unconscious" => "\u{1F4A4}",
        _ => "\u{26A0}\u{FE0F}",
    }
}

/// Icon for an equipment slot.
fn slot_icon(slot: &str) -> &'static str {
    match slot.to_lowercase().as_str() {
        "weapon" | "main hand" | "mainhand" => "\u{2694}\u{FE0F}",
        "off hand" | "offhand" | "shield" => "\u{1F6E1}\u{FE0F}",
        "armor" | "body" | "chest" => "\u{1F6E1}\u{FE0F}",
        "head" | "helmet" | "helm" => "\u{1FA96}",
        "ring" | "accessory" => "\u{1F48D}",
        "amulet" | "necklace" => "\u{1F4FF}",
        "boots" | "feet" => "\u{1F97E}",
        "gloves" | "hands" => "\u{1F9E4}",
        "cloak" | "cape" | "back" => "\u{1F9E3}",
        _ => "\u{1F4E6}",
    }
}

/// Formats a modifier with sign: +2, -1, +0.
fn fmt_modifier(m: i32) -> String {
    if m >= 0 {
        format!("+{}", m)
    } else {
        format!("{}", m)
    }
}

fn normalize_lore_key(raw: &str) -> String {
    raw.trim().to_ascii_lowercase().replace(['-', ' '], "_")
}

fn collect_actor_aliases(actor_id: &str, actor_name: &str, keeper: &str) -> Vec<String> {
    let mut aliases = Vec::new();
    let mut seen = std::collections::HashSet::new();

    let push_alias = |raw: &str, aliases: &mut Vec<String>, seen: &mut std::collections::HashSet<String>| {
        let trimmed = raw.trim().to_ascii_lowercase();
        if trimmed.is_empty() {
            return;
        }

        let compact = trimmed.replace(['_', '-'], "");
        let plain = trimmed
            .chars()
            .filter(|ch| ch.is_ascii_alphanumeric() || *ch == '-' || *ch == '_')
            .collect::<String>();
        for candidate in [trimmed.clone(), compact, plain] {
            if !candidate.is_empty() && seen.insert(candidate.clone()) {
                aliases.push(candidate);
            }
        }

        if let Some((head, _)) = trimmed.split_once('-') {
            if seen.insert(head.to_string()) {
                aliases.push(head.to_string());
            }
        }
        if let Some((head, _)) = trimmed.split_once('_') {
            if seen.insert(head.to_string()) {
                aliases.push(head.to_string());
            }
        }

        if let Some((head, _)) = trimmed.rsplit_once('-') {
            if seen.insert(head.to_string()) {
                aliases.push(head.to_string());
            }
        }

        if let Some((head, _)) = trimmed.rsplit_once('_') {
            if seen.insert(head.to_string()) {
                aliases.push(head.to_string());
            }
        }
    };

    let push_tokens = |raw: &str,
                       aliases: &mut Vec<String>,
                       seen: &mut std::collections::HashSet<String>| {
        let normalized = raw.trim().to_ascii_lowercase();
        if normalized.is_empty() {
            return;
        }

        for token in normalized
            .split(|ch| matches!(ch, '=' | ';' | ',' | '|' | '/' | '\\' | '(' | ')' | '[' | ']' | '{' | '}'))
        {
            let token = token.trim();
            if token.is_empty() {
                continue;
            }

            push_alias(token, aliases, seen);
            for word in token.split_whitespace() {
                if !word.trim().is_empty() {
                    push_alias(word.trim(), aliases, seen);
                }
            }
        }
    };

    push_tokens(actor_id, &mut aliases, &mut seen);
    for token in actor_name.split_whitespace().filter(|token| !token.trim().is_empty()) {
        push_tokens(token, &mut aliases, &mut seen);
    }
    push_tokens(keeper, &mut aliases, &mut seen);
    aliases
}

fn identity_token(raw: &str) -> String {
    raw.trim()
        .to_ascii_lowercase()
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .collect()
}

fn identity_matches(a: &str, b: &str) -> bool {
    let a = a.trim().to_ascii_lowercase();
    let b = b.trim().to_ascii_lowercase();
    if a.is_empty() || b.is_empty() {
        return false;
    }
    let compact_a = identity_token(&a);
    let compact_b = identity_token(&b);

    a == b
        || compact_a == compact_b
        || compact_a == b
        || a == compact_b
        || compact_a.ends_with(&compact_b)
        || compact_b.ends_with(&compact_a)
}

struct SkillLore {
    description: &'static str,
    hint: &'static str,
    dnd5_check: &'static str,
}

fn known_skill_lore(skill_name: &str) -> Option<SkillLore> {
    match normalize_lore_key(skill_name).as_str() {
        "frontline_shield" => Some(SkillLore {
            description: "전열에서 아군을 감싸 피해를 흡수하며 진형 붕괴를 막습니다.",
            hint: "보스나 집중 사격 타이밍 직전에 선언하면 아군 생존률이 크게 오릅니다.",
            dnd5_check: "STR(운동) 기반 보호 판정 또는 Protection 반응 운용",
        }),
        "oath_intercept" => Some(SkillLore {
            description: "맹세 대상에게 향한 타격선으로 끼어들어 피해를 가로챕니다.",
            hint: "직전 턴에 위협을 확정한 적에게 반응형으로 연계하면 효율이 높습니다.",
            dnd5_check: "반응(Reaction) 기반 차단, STR(운동) 또는 CON 내성 보조",
        }),
        "morale_anchor" => Some(SkillLore {
            description: "동요한 아군의 전의를 묶어 공포/혼란 이후 흐름을 회복합니다.",
            hint: "연속 실패나 다운 직후 사기 복구용으로 사용하면 턴 손실을 줄입니다.",
            dnd5_check: "CHA(설득) 또는 공연 계열 보조 체크",
        }),
        "deception_feint" => Some(SkillLore {
            description: "거짓 동작으로 적 판단을 흔들어 빈틈을 만듭니다.",
            hint: "정면 돌파보다 교란이 필요한 국면에서 효과적입니다.",
            dnd5_check: "CHA(기만) 체크",
        }),
        "favor_broker" => Some(SkillLore {
            description: "관계/빚을 거래해 협력이나 정보 제공을 이끌어냅니다.",
            hint: "NPC 또는 파티 설득 상황에서 선택지를 늘릴 때 사용하세요.",
            dnd5_check: "CHA(설득) + WIS(통찰) 조합 체크",
        }),
        "shadow_entry" => Some(SkillLore {
            description: "그림자 동선을 타고 경계망 안쪽으로 침투합니다.",
            hint: "탐지 리스크가 높은 구간을 넘어야 할 때 가장 안정적입니다.",
            dnd5_check: "DEX(은신) 체크",
        }),
        "supply_scan" => Some(SkillLore {
            description: "보급/자원 상태를 점검해 부족 항목을 조기에 찾습니다.",
            hint: "장기전 직전이나 이벤트 전환 전에 사용하면 손실을 줄입니다.",
            dnd5_check: "INT(조사) 체크",
        }),
        "ration_shift" => Some(SkillLore {
            description: "자원 배분을 재조정해 생존 시간을 늘립니다.",
            hint: "당장 화력보다 지속력이 중요한 턴에 우선 사용하세요.",
            dnd5_check: "WIS(생존) 또는 INT 기반 운영 체크",
        }),
        "logistics_patch" => Some(SkillLore {
            description: "끊긴 보급 동선을 임시 복구해 팀 운영을 안정화합니다.",
            hint: "연속 이벤트로 소모가 누적될 때 유지력 확보에 핵심입니다.",
            dnd5_check: "INT(조사) + WIS(생존) 조합 체크",
        }),
        "omen_trace" => Some(SkillLore {
            description: "징조를 해석해 다음 장면의 위험 분기를 예측합니다.",
            hint: "불확실한 분기에서 먼저 써서 실패 비용이 큰 선택지를 피하세요.",
            dnd5_check: "INT(비전학) 또는 INT(종교학) 체크",
        }),
        "arc_flash" => Some(SkillLore {
            description: "짧은 비전 폭발로 적 전열을 흔들며 공간을 확보합니다.",
            hint: "아군이 묶였거나 도주 루트를 열어야 할 때 선행기로 쓰세요.",
            dnd5_check: "주문 공격(Spell Attack) 또는 INT(비전학) 보조 체크",
        }),
        "ward_bloom" => Some(SkillLore {
            description: "보호 장을 펼쳐 광역 피해를 줄이고 회복 창을 만듭니다.",
            hint: "광역 피해가 예고된 턴에 선사용하면 파티 안정성이 크게 오릅니다.",
            dnd5_check: "방호 계열 운용, INT(비전학) + WIS(의학) 보조 체크",
        }),
        "mark_prey" => Some(SkillLore {
            description: "적 한 명을 추적 표식으로 지정해 파티의 집중 화력을 유도합니다.",
            hint: "라운드 초반에 위협도가 높은 목표를 먼저 지정하면 효율이 큽니다.",
            dnd5_check: "WIS(지각) 또는 WIS(생존) 체크",
        }),
        "silent_route" => Some(SkillLore {
            description: "소음과 시야 노출을 줄여 우회/잠입 루트를 확보합니다.",
            hint: "정면 충돌 전에 위치를 바꾸거나 기습 각도를 만들 때 사용하세요.",
            dnd5_check: "DEX(은신) + WIS(지각) 체크",
        }),
        "finisher_strike" => Some(SkillLore {
            description: "체력이 깎인 목표를 마무리하는 처형형 기술입니다.",
            hint: "아군의 선행 피해 후 연계하면 성공 판정이 잘 나옵니다.",
            dnd5_check: "근접/원거리 공격 굴림(STR/DEX) 체크",
        }),
        "field_mend" => Some(SkillLore {
            description: "현장에서 빠르게 상처를 봉합해 전열 붕괴를 막습니다.",
            hint: "집중 공격받는 아군에게 먼저 써서 다운을 방지하세요.",
            dnd5_check: "WIS(의학) 체크",
        }),
        "truce_window" => Some(SkillLore {
            description: "짧은 휴전 창을 만들어 협상/재정비 턴을 확보합니다.",
            hint: "적이 강하거나 정보가 부족할 때 시간을 벌기 좋습니다.",
            dnd5_check: "CHA(설득) 또는 WIS(통찰) 체크",
        }),
        "resolve_hymn" => Some(SkillLore {
            description: "파티의 동요를 진정시키고 의지를 끌어올리는 결의 기술입니다.",
            hint: "연속 실패 뒤 사기 회복용으로 쓰면 흐름 복구에 유리합니다.",
            dnd5_check: "CHA(공연) 또는 CHA(설득) 체크",
        }),
        _ => None,
    }
}

fn trait_icon(name: &str) -> &'static str {
    match normalize_lore_key(name).as_str() {
        "suspicious" => "\u{1F575}\u{FE0F}",
        "precise" => "\u{1F3AF}",
        "vengeful" => "\u{1F525}",
        "calm" => "\u{1F9D8}",
        "self_sacrificing" => "\u{1FA79}",
        "idealistic" => "\u{2728}",
        "calculating" => "\u{1F9E0}",
        "charming" => "\u{1F48E}",
        "risk_seeking" => "\u{1F3B2}",
        "stubborn" => "\u{1FAA8}",
        "protective" => "\u{1F6E1}\u{FE0F}",
        "honor_bound" => "\u{2696}\u{FE0F}",
        "intense" => "\u{1F525}",
        "empathetic" => "\u{1FA76}",
        "fatalistic" => "\u{1F52E}",
        "pragmatic" => "\u{2699}\u{FE0F}",
        "frugal" => "\u{1F4B0}",
        "impatient" => "\u{23F1}\u{FE0F}",
        _ => "\u{1F4CC}",
    }
}

fn trait_description(name: &str) -> String {
    match normalize_lore_key(name).as_str() {
        "suspicious" => "배신 가능성을 먼저 계산해 위험 징후 탐지에 강합니다.".to_string(),
        "precise" => "정확도 중심으로 행동해 단일 목표 처리 성공률이 높습니다.".to_string(),
        "vengeful" => "피해를 입은 뒤 반격 의지가 강해 추격/마무리에 유리합니다.".to_string(),
        "calm" => "혼전에서도 판단이 흔들리지 않아 안정적인 선택을 유지합니다.".to_string(),
        "self_sacrificing" => "팀 보호를 우선해 방어/치유 선택을 자주 성공시킵니다.".to_string(),
        "idealistic" => "가치 기반 선택을 선호해 협상/중재 상황에서 힘을 발휘합니다.".to_string(),
        "calculating" => "확률과 대가를 계산해 손익이 좋은 경로를 찾아냅니다.".to_string(),
        "charming" => "대화 압박을 완화하고 설득/관계 형성 판정에 유리합니다.".to_string(),
        "risk_seeking" => "높은 위험의 대가를 노려 큰 전환점을 만드는 성향입니다.".to_string(),
        "stubborn" => "의지가 강해 정신 내성/버티기 상황에서 쉽게 물러서지 않습니다.".to_string(),
        "protective" => "아군 대신 맞거나 엄호하는 선택을 우선합니다.".to_string(),
        "honor_bound" => {
            "약속과 규율을 중시해 협상/명예 관련 장면에서 신뢰를 얻습니다.".to_string()
        },
        "intense" => "집중력이 높아 짧은 폭발력이나 몰입이 필요한 장면에 강합니다.".to_string(),
        "empathetic" => "상대 감정 신호를 잘 읽어 통찰/중재 상황에서 유리합니다.".to_string(),
        "fatalistic" => "불리한 상황을 감수하고 큰 대가를 선택하는 경향이 있습니다.".to_string(),
        "pragmatic" => "당장 생존과 효율을 우선해 자원 운용 판단이 빠릅니다.".to_string(),
        "frugal" => "소모를 줄여 장기전에서 팀 유지력을 끌어올립니다.".to_string(),
        "impatient" => "결단은 빠르지만 장기 설정보다 즉시 행동을 선호합니다.".to_string(),
        _ => "상황 선택에 성향 보정을 주는 캐릭터 특성입니다.".to_string(),
    }
}

fn fallback_skill_description(_actor: &Actor, skill_name: &str, modifier: i32) -> String {
    if let Some(lore) = known_skill_lore(skill_name) {
        return lore.description.to_string();
    }
    let key = skill_name.trim().to_ascii_lowercase();
    if key.contains("heal") || key.contains("cure") || key.contains("치유") {
        "아군 체력을 회복하거나 상태를 안정화합니다.".to_string()
    } else if key.contains("guard")
        || key.contains("defend")
        || key.contains("block")
        || key.contains("방어")
    {
        "피해를 줄이거나 아군을 보호하는 방어 기술입니다.".to_string()
    } else if key.contains("slash")
        || key.contains("strike")
        || key.contains("attack")
        || key.contains("베기")
    {
        "근접 중심 단일 대상 공격에 유리한 기술입니다.".to_string()
    } else if key.contains("fire")
        || key.contains("ice")
        || key.contains("bolt")
        || key.contains("blast")
        || key.contains("마법")
    {
        "원거리/속성 기반 공격 판정에 유리한 기술입니다.".to_string()
    } else if key.contains("stealth")
        || key.contains("hide")
        || key.contains("sneak")
        || key.contains("은신")
    {
        "탐지 회피, 기습, 잠입 상황에서 효율이 높습니다.".to_string()
    } else if key.contains("charm")
        || key.contains("taunt")
        || key.contains("persuade")
        || key.contains("협상")
    {
        "대화/심리전/주의 분산 계열 행동에 유리합니다.".to_string()
    } else {
        format!("관련 행동 판정 보정: {}", fmt_modifier(modifier))
    }
}

fn fallback_skill_hint(actor: &Actor, skill_name: &str) -> String {
    if let Some(lore) = known_skill_lore(skill_name) {
        return lore.hint.to_string();
    }
    let key = skill_name.trim().to_ascii_lowercase();
    let base = if key.contains("heal") || key.contains("cure") || key.contains("치유") {
        "전열 유지가 급할 때 우선 사용하면 안정적입니다.".to_string()
    } else if key.contains("guard")
        || key.contains("defend")
        || key.contains("block")
        || key.contains("방어")
    {
        "적의 강한 차례 직전에 사용하면 생존력이 크게 오릅니다.".to_string()
    } else if key.contains("stealth")
        || key.contains("hide")
        || key.contains("sneak")
        || key.contains("은신")
    {
        "정면 교전보다 선제/우회 루트 선택 시 효과가 큽니다.".to_string()
    } else {
        "행동 탭에서 스킬 성격에 맞는 키워드를 고르면 성공률이 올라갑니다.".to_string()
    };
    if actor.persona.trim().is_empty() {
        base
    } else {
        format!("{base} 페르소나: {}", actor.persona.trim())
    }
}

fn fallback_skill_dnd5(skill_name: &str) -> String {
    if let Some(lore) = known_skill_lore(skill_name) {
        return lore.dnd5_check.to_string();
    }
    let key = skill_name.trim().to_ascii_lowercase();
    if key.contains("heal") || key.contains("cure") || key.contains("치유") {
        "D&D5 권장 체크: WIS(의학)".to_string()
    } else if key.contains("guard")
        || key.contains("defend")
        || key.contains("block")
        || key.contains("방어")
    {
        "D&D5 권장 체크: STR(운동) + 반응(Reaction)".to_string()
    } else if key.contains("stealth")
        || key.contains("hide")
        || key.contains("sneak")
        || key.contains("은신")
    {
        "D&D5 권장 체크: DEX(은신)".to_string()
    } else if key.contains("charm")
        || key.contains("deception")
        || key.contains("persuade")
        || key.contains("협상")
    {
        "D&D5 권장 체크: CHA(기만/설득)".to_string()
    } else if key.contains("arc")
        || key.contains("spell")
        || key.contains("omen")
        || key.contains("magic")
        || key.contains("마법")
    {
        "D&D5 권장 체크: INT(비전학) 또는 주문 공격".to_string()
    } else {
        "D&D5 권장 체크: 관련 능력치 체크(상황 기반)".to_string()
    }
}

fn skill_copy(skill: &Skill, actor: &Actor) -> (String, String, String) {
    let modifier = skill.modifier();
    let description = if skill.description.trim().is_empty() {
        fallback_skill_description(actor, &skill.name, modifier)
    } else {
        skill.description.trim().to_string()
    };
    let usage_hint = if skill.usage_hint.trim().is_empty() {
        fallback_skill_hint(actor, &skill.name)
    } else {
        skill.usage_hint.trim().to_string()
    };
    let dnd5_check = fallback_skill_dnd5(&skill.name);
    (description, usage_hint, dnd5_check)
}

fn actor_initials(name: &str, id: &str) -> String {
    let mut initials = String::new();
    for token in name.split_whitespace().take(2) {
        if let Some(ch) = token.chars().next() {
            initials.push(ch.to_ascii_uppercase());
        }
    }
    if initials.is_empty() {
        for token in id.split(['-', '_']).take(2) {
            if let Some(ch) = token.chars().next() {
                initials.push(ch.to_ascii_uppercase());
            }
        }
    }
    if initials.is_empty() {
        "AI".to_string()
    } else {
        initials
    }
}

fn portrait_url_for_actor(actor: &Actor) -> Option<String> {
    let mut keys = Vec::new();

    let id = actor.id.trim().to_ascii_lowercase();
    if !id.is_empty() {
        keys.push(id.clone());
        if let Some((head, _)) = id.split_once('-') {
            keys.push(head.to_string());
        }
        if let Some((head, _)) = id.split_once('_') {
            keys.push(head.to_string());
        }
    }

    let name = actor.name.trim().to_ascii_lowercase();
    if !name.is_empty() {
        keys.push(name.clone());
        if let Some(first) = name.split_whitespace().next() {
            keys.push(first.to_string());
        }
    }

    for key in keys {
        if let Some(path) = assets::portrait_for(&key) {
            return Some(format!("/assets/{}", path));
        }
    }
    None
}

/// Reads the current collapse state from the DOM to preserve it across re-renders.
/// Returns a set of section IDs that are currently expanded.
#[cfg(target_arch = "wasm32")]
fn read_collapse_state(document: &web_sys::Document) -> std::collections::HashSet<String> {
    use wasm_bindgen::JsCast;
    let mut expanded = std::collections::HashSet::new();
    if let Ok(inputs) = document.query_selector_all("input.section-toggle") {
        for i in 0..inputs.length() {
            if let Some(node) = inputs.item(i) {
                if let Some(input) = node.dyn_ref::<web_sys::HtmlInputElement>() {
                    if input.checked() {
                        expanded.insert(input.id());
                    }
                }
            }
        }
    }
    expanded
}

#[cfg(not(target_arch = "wasm32"))]
fn read_collapse_state() -> std::collections::HashSet<String> {
    std::collections::HashSet::new()
}

fn compact_inline(raw: &str) -> String {
    raw.split_whitespace().collect::<Vec<_>>().join(" ")
}

struct ActorDialogueRow {
    source: String,
    text: String,
}

fn classify_actor_log_source(entry: &web_sys::Element) -> String {
    let class_name = entry.class_name().to_ascii_lowercase();
    if class_name.contains("history-event") {
        let kind = entry.get_attribute("data-kind").unwrap_or_default();
        let log_kind = entry.get_attribute("data-log-kind").unwrap_or_default();
        let kind_label = match kind.as_str() {
            "dice" => "주사위",
            "turn" => "턴",
            "progress" => "진행",
            "system" => "시스템",
            "narrative" => "내러티브",
            _ => "이벤트",
        };
        let tone = match log_kind.as_str() {
            "action" => "액션",
            "outcome" => "결과",
            "debug" => "디버그",
            "system" => "시스템",
            _ => "이벤트",
        };
        return format!("{kind_label}({tone})");
    }
    if class_name.contains("dice-entry") {
        return "주사위".to_string();
    }
    if class_name.contains("narrative-entry") {
        let phase = entry.get_attribute("data-phase").unwrap_or_default();
        return if phase.trim().is_empty() {
            "내러티브".to_string()
        } else {
            format!("내러티브({phase})")
        };
    }
    "로그".to_string()
}

pub(crate) fn render_actor_inspector_empty(document: &web_sys::Document, message: &str) {
    if let Some(panel) = document.get_element_by_id("actor-inspector") {
        panel.set_inner_html(&format!(
            "<div class=\"actor-inspector-empty\">{}</div>",
            html_escape(message)
        ));
    }
}

fn collect_recent_actor_dialogues(
    document: &web_sys::Document,
    actor_id: &str,
    actor_name: &str,
    keeper: &str,
) -> Vec<ActorDialogueRow> {
    let Ok(entries) = document.query_selector_all(
        "#narrative-log .narrative-entry, #session-history .history-event, #dice-log .dice-entry"
    ) else {
        return Vec::new();
    };
    let actor_id = actor_id.trim().to_ascii_lowercase();
    let actor_name = actor_name.trim().to_ascii_lowercase();
    let keeper = keeper.trim().to_ascii_lowercase();
    let aliases = collect_actor_aliases(&actor_id, &actor_name, &keeper);
    let mut normalized_identities = Vec::with_capacity(aliases.len() * 2 + 3);
    for alias in aliases.iter() {
        let alias = alias.trim();
        if alias.is_empty() {
            continue;
        }
        let compact = alias.replace(['_', '-'], "");
        if !compact.is_empty() {
            normalized_identities.push(compact);
        }
        normalized_identities.push(alias.to_string());
    }
    normalized_identities.push(actor_id.clone());
    normalized_identities.push(actor_name.clone());
    normalized_identities.push(keeper);
    normalized_identities.push(actor_id.replace('_', ""));
    normalized_identities.push(actor_name.replace('_', ""));
    normalized_identities.sort();
    normalized_identities.dedup();
    normalized_identities.retain(|item| !item.is_empty());

    let exact_match = |value: &str, identity: &str| {
        if identity.is_empty() {
            return false;
        }
        let value = value.trim().to_ascii_lowercase();
        let compact_value = value.replace(['_', '-'], "");
        value == identity || compact_value == identity || compact_value.ends_with(identity)
    };

    let mut rows = Vec::new();

    let len = entries.length();
    for idx in (0..len).rev() {
        let Some(node) = entries.item(idx) else {
            continue;
        };
        let Some(entry) = node.dyn_ref::<web_sys::Element>() else {
            continue;
        };

        let actor_id_candidates = [
            entry.get_attribute("data-actor-id").unwrap_or_default(),
            entry
                .query_selector(".history-actor")
                .ok()
                .flatten()
                .and_then(|actor_el| actor_el.text_content())
                .unwrap_or_default(),
        ];
        let actor_name_candidates = [
            entry.get_attribute("data-actor-name").unwrap_or_default(),
            entry
                .get_attribute("data-speaker")
                .unwrap_or_default(),
            entry
                .query_selector(".history-actor")
                .ok()
                .flatten()
                .and_then(|actor_el| actor_el.text_content())
                .unwrap_or_default(),
        ];
        let text = compact_inline(&entry.text_content().unwrap_or_default());
        let is_speaker_match = actor_id_candidates
            .iter()
            .chain(actor_name_candidates.iter())
            .any(|candidate| {
                normalized_identities
                    .iter()
                    .any(|identity| exact_match(candidate, identity))
            });

        if !is_speaker_match {
            continue;
        }

        let source = classify_actor_log_source(entry);
        let clipped = if text.chars().count() > 140 {
            let mut short = text.chars().take(140).collect::<String>();
            short.push_str("...");
            short
        } else {
            text
        };
        rows.push(ActorDialogueRow {
            source,
            text: clipped,
        });
        if rows.len() >= 4 {
            break;
        }
    }
    rows.reverse();
    rows
}

fn render_actor_inspector(document: &web_sys::Document, selected: &web_sys::Element) {
    let Some(panel) = document.get_element_by_id("actor-inspector") else {
        return;
    };
    let actor_id = selected
        .get_attribute("data-actor-id")
        .unwrap_or_default()
        .trim()
        .to_string();
    if actor_id.is_empty() {
        render_actor_inspector_empty(document, DEFAULT_ACTOR_INSPECTOR_EMPTY_MESSAGE);
        return;
    }

    let actor_name = selected
        .get_attribute("data-actor-name")
        .unwrap_or_default()
        .trim()
        .to_string();
    let actor_class = selected
        .get_attribute("data-actor-class")
        .unwrap_or_default()
        .trim()
        .to_string();
    let keeper = selected
        .get_attribute("data-keeper")
        .unwrap_or_default()
        .trim()
        .to_string();
    let runtime_state = selected
        .get_attribute("data-runtime-state")
        .unwrap_or_default()
        .trim()
        .to_string();
    let runtime_reason = selected
        .get_attribute("data-runtime-reason")
        .unwrap_or_default()
        .trim()
        .to_string();
    let archetype = selected
        .get_attribute("data-archetype")
        .unwrap_or_default()
        .trim()
        .to_string();
    let persona = selected
        .get_attribute("data-persona")
        .unwrap_or_default()
        .trim()
        .to_string();
    let contribution_score = selected
        .get_attribute("data-contribution-score")
        .unwrap_or_default()
        .trim()
        .to_string();
    let contribution_reason = selected
        .get_attribute("data-contribution-reason")
        .unwrap_or_default()
        .trim()
        .to_string();
    let contribution_score_value = contribution_score
        .trim()
        .parse::<i32>()
        .unwrap_or(0);
    let contribution_reasons = selected
        .get_attribute("data-contribution-reasons")
        .unwrap_or_default()
        .split('|')
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .collect::<Vec<_>>();
    let hp = selected
        .get_attribute("data-hp")
        .and_then(|value| value.parse::<i32>().ok())
        .unwrap_or(0);
    let max_hp = selected
        .get_attribute("data-max-hp")
        .and_then(|value| value.parse::<i32>().ok())
        .unwrap_or(0);
    let mp = selected
        .get_attribute("data-mp")
        .and_then(|value| value.parse::<i32>().ok())
        .unwrap_or(0);
    let max_mp = selected
        .get_attribute("data-max-mp")
        .and_then(|value| value.parse::<i32>().ok())
        .unwrap_or(0);
    let hp_known = parse_bool_attr(selected.get_attribute("data-hp-known").as_deref());
    let max_hp_known = parse_bool_attr(selected.get_attribute("data-max-hp-known").as_deref());
    let mp_known = parse_bool_attr(selected.get_attribute("data-mp-known").as_deref());
    let max_mp_known = parse_bool_attr(selected.get_attribute("data-max-mp-known").as_deref());
    let atk = selected
        .get_attribute("data-atk")
        .and_then(|value| value.parse::<i32>().ok())
        .unwrap_or(0);
    let def = selected
        .get_attribute("data-def")
        .and_then(|value| value.parse::<i32>().ok())
        .unwrap_or(0);
    let int = selected
        .get_attribute("data-int")
        .and_then(|value| value.parse::<i32>().ok())
        .unwrap_or(0);
    let lck = selected
        .get_attribute("data-luck")
        .and_then(|value| value.parse::<i32>().ok())
        .unwrap_or(0);
    let atk_known = parse_bool_attr(selected.get_attribute("data-atk-known").as_deref());
    let def_known = parse_bool_attr(selected.get_attribute("data-def-known").as_deref());
    let int_known = parse_bool_attr(selected.get_attribute("data-int-known").as_deref());
    let luck_known = parse_bool_attr(selected.get_attribute("data-luck-known").as_deref());
    let relationship_rows = selected
        .get_attribute("data-relationships")
        .unwrap_or_default()
        .split('|')
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .collect::<Vec<_>>();
    let dialogue_rows = collect_recent_actor_dialogues(document, &actor_id, &actor_name, &keeper);

    let dialogue_html = if dialogue_rows.is_empty() {
        format!(
            "<div class=\"actor-inspector-empty-sub\">{}</div>",
            DEFAULT_ACTOR_INSPECTOR_NO_DIALOGUE_MESSAGE
        )
    } else {
        dialogue_rows
            .iter()
            .map(|line| {
                format!(
                    "<div class=\"actor-inspector-line\"><span class=\"actor-inspector-source\">{}</span><span class=\"actor-inspector-line-text\">{}</span></div>",
                    html_escape(&line.source),
                    html_escape(&line.text)
                )
            })
            .collect::<Vec<_>>()
            .join("")
    };
    let relation_html = if relationship_rows.is_empty() {
        "<span class=\"actor-inspector-muted\">관계 없음</span>".to_string()
    } else {
        relationship_rows
            .iter()
            .map(|line| format!("<span class=\"actor-rel-chip\">{}</span>", html_escape(line)))
            .collect::<Vec<_>>()
            .join("")
    };
    let contribution_reason_html = if contribution_reason.is_empty() {
        "<span class=\"actor-inspector-muted\">기여 사유 없음</span>".to_string()
    } else {
        html_escape(&contribution_reason)
    };
    let contribution_score_class = if contribution_score_value > 0 {
        "actor-score-positive"
    } else if contribution_score_value < 0 {
        "actor-score-negative"
    } else {
        "actor-score-neutral"
    };
    let contribution_score_text = if contribution_score_value > 0 {
        format!("+{}", contribution_score_value)
    } else {
        contribution_score_value.to_string()
    };
    let contribution_reasons_html = if contribution_reasons.is_empty() {
        String::new()
    } else {
        format!(
            "<div class=\"actor-inspector-line\">최근 사유: {}</div>",
            html_escape(&contribution_reasons.join(" · "))
        )
    };
    let hp_display = metric_text(hp, hp_known, max_hp, max_hp_known);
    let mp_display = metric_text(mp, mp_known, max_mp, max_mp_known);
    let hp_display_class = metric_text_class(hp_known, max_hp_known);
    let mp_display_class = metric_text_class(mp_known, max_mp_known);
    let hp_known_badge = if hp_known {
        if max_hp_known {
            "확인됨"
        } else {
            "부분 확인"
        }
    } else {
        "미확인"
    };
    let mp_known_badge = if mp_known {
        if max_mp_known {
            "확인됨"
        } else {
            "부분 확인"
        }
    } else {
        "미확인"
    };

    let atk_text = known_stat_text(atk, atk_known);
    let def_text = known_stat_text(def, def_known);
    let int_text = known_stat_text(int, int_known);
    let luck_text = known_stat_text(lck, luck_known);
    let atk_class = metric_text_class(atk_known, true);
    let def_class = metric_text_class(def_known, true);
    let int_class = metric_text_class(int_known, true);
    let luck_class = metric_text_class(luck_known, true);

    panel.set_inner_html(&format!(
        concat!(
            "<div class=\"actor-inspector-head\">",
            "<span class=\"actor-inspector-title\">{name}</span>",
            "<span class=\"actor-inspector-id\">{id}</span>",
            "</div>",
            "<div class=\"actor-inspector-chips\">",
            "<span class=\"actor-inspector-chip\">Class: {class_name}</span>",
            "<span class=\"actor-inspector-chip\">Keeper: {keeper}</span>",
            "<span class=\"actor-inspector-chip actor-inspector-chip-score {score_class}\">기여 {score}</span>",
            "</div>",
            "<div class=\"actor-inspector-grid\">",
            "<div><span class=\"k\">HP</span><span class=\"v\"><span class=\"actor-inspector-metric {hp_metric_class}\">{hp}</span> <span class=\"actor-inspector-muted\">({hp_known_hint})</span></span></div>",
            "<div><span class=\"k\">MP</span><span class=\"v\"><span class=\"actor-inspector-metric {mp_metric_class}\">{mp}</span> <span class=\"actor-inspector-muted\">({mp_known_hint})</span></span></div>",
            "<div><span class=\"k\">현재 상태</span><span class=\"v\">{runtime}</span></div>",
            "<div><span class=\"k\">상태 사유</span><span class=\"v\">{reason}</span></div>",
            "</div>",
            "<div class=\"actor-inspector-line\">Archetype: {archetype}</div>",
            "<div class=\"actor-inspector-line\">Persona: {persona}</div>",
            "<div class=\"actor-inspector-line\">능력치: <span class=\"actor-inspector-metric {atk_class}\">ATK={atk}</span> <span class=\"actor-inspector-metric {def_class}\">DEF={def}</span> <span class=\"actor-inspector-metric {int_class}\">INT={int}</span> <span class=\"actor-inspector-metric {luck_class}\">LCK={luck}</span></div>",
            "<div class=\"actor-inspector-line\">최근 기여 사유: {contribution_reason}</div>",
            "{contribution_reasons}",
            "<div class=\"actor-inspector-section\">",
            "<div class=\"actor-inspector-section-title\">관계</div>",
            "<div class=\"actor-rel-list\">{relationships}</div>",
            "</div>",
            "<div class=\"actor-inspector-section\">",
            "<div class=\"actor-inspector-section-title\">최근 대사 / 행동 로그 (선택 액터 관련)</div>",
            "{dialogues}",
            "</div>"
        ),
        name = html_escape(if actor_name.is_empty() {
            actor_id.as_str()
        } else {
            actor_name.as_str()
        }),
        id = html_escape(&actor_id),
        class_name = html_escape(if actor_class.is_empty() {
            "-"
        } else {
            actor_class.as_str()
        }),
        keeper = html_escape(if keeper.is_empty() {
            "미할당"
        } else {
            keeper.as_str()
        }),
        runtime = html_escape(if runtime_state.is_empty() {
            "상태 없음"
        } else {
            runtime_state.as_str()
        }),
        reason = html_escape(if runtime_reason.is_empty() {
            "사유 없음"
        } else {
            runtime_reason.as_str()
        }),
        archetype = html_escape(if archetype.is_empty() {
            "-"
        } else {
            archetype.as_str()
        }),
        persona = html_escape(if persona.is_empty() {
            "-"
        } else {
            persona.as_str()
        }),
        score = html_escape(&contribution_score_text),
        score_class = contribution_score_class,
        contribution_reason = contribution_reason_html,
        contribution_reasons = contribution_reasons_html,
        relationships = relation_html,
        dialogues = dialogue_html,
        hp = html_escape(&hp_display),
        hp_metric_class = hp_display_class,
        hp_known_hint = hp_known_badge,
        mp = html_escape(&mp_display),
        mp_metric_class = mp_display_class,
        mp_known_hint = mp_known_badge,
        atk_class = atk_class,
        atk = html_escape(&atk_text),
        def_class = def_class,
        def = html_escape(&def_text),
        int_class = int_class,
        int = html_escape(&int_text),
        luck_class = luck_class,
        luck = html_escape(&luck_text),
    ));
}

pub(crate) fn select_character_card(document: &web_sys::Document, actor_id: &str) {
    let actor_id = actor_id.trim();
    if actor_id.is_empty() {
        return;
    }
    let actor_id_lower = actor_id.to_ascii_lowercase();
    let query_aliases = collect_actor_aliases(&actor_id_lower, &actor_id_lower, "");

    let Some(dashboard) = document.get_element_by_id("dashboard") else {
        return;
    };

    let Ok(cards) = document.query_selector_all("#character-panel .character-card[data-actor-id]") else {
        return;
    };

    let mut selected_card = None::<web_sys::Element>;
    for idx in 0..cards.length() {
        let Some(node) = cards.item(idx) else {
            continue;
        };
        let Some(card) = node.dyn_ref::<web_sys::Element>() else {
            continue;
        };
        let card_actor = card
            .get_attribute("data-actor-id")
            .unwrap_or_default()
            .trim()
            .to_string();
        let card_name = card
            .get_attribute("data-actor-name")
            .unwrap_or_default()
            .trim()
            .to_string();
        let card_keeper = card
            .get_attribute("data-keeper")
            .unwrap_or_default()
            .trim()
            .to_string();
        let card_aliases = collect_actor_aliases(&card_actor, &card_name, &card_keeper);

        let matched = card_actor.eq_ignore_ascii_case(actor_id)
            || query_aliases
                .iter()
                .any(|q| card_aliases.iter().any(|alias| identity_matches(q, alias)));
        if matched {
            let _ = card.class_list().add_1("join-pick-selected");
            let _ = card.set_attribute("aria-selected", "true");
            selected_card = Some(card.clone());
        } else {
            let _ = card.class_list().remove_1("join-pick-selected");
            let _ = card.set_attribute("aria-selected", "false");
        }
    }

    let Some(card) = selected_card else {
        let _ = dashboard.remove_attribute("data-selected-actor");
        if let Some(input) = document
            .get_element_by_id("actor-id-input")
            .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
        {
            input.set_value("");
        }
        render_actor_inspector_empty(document, DEFAULT_ACTOR_INSPECTOR_EMPTY_MESSAGE);
        return;
    };

    let selected_id = card
        .get_attribute("data-actor-id")
        .unwrap_or_default()
        .trim()
        .to_string();
    if !selected_id.is_empty() {
        card.scroll_into_view_with_bool(true);
        let _ = dashboard.set_attribute("data-selected-actor", &selected_id);
        if let Some(input) = document
            .get_element_by_id("actor-id-input")
            .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
        {
            input.set_value(&selected_id);
        }
        let _ = card.class_list().add_1("join-pick-selected");
        let _ = card.set_attribute("aria-selected", "true");
        render_actor_inspector(document, &card);
    } else {
        let _ = dashboard.remove_attribute("data-selected-actor");
        if let Some(input) = document
            .get_element_by_id("actor-id-input")
            .and_then(|el| el.dyn_into::<web_sys::HtmlInputElement>().ok())
        {
            input.set_value("");
        }
        render_actor_inspector_empty(document, DEFAULT_ACTOR_INSPECTOR_EMPTY_MESSAGE);
    }
}

fn resolve_character_card_actor_id(target: web_sys::EventTarget) -> Option<String> {
    let card = if let Ok(el) = target.clone().dyn_into::<web_sys::Element>() {
        el.closest(".character-card").ok().flatten()
    } else {
        target
            .clone()
            .dyn_into::<web_sys::Node>()
            .ok()
            .and_then(|node| node.parent_element())
            .and_then(|el| el.closest(".character-card").ok().flatten())
    };

    card.and_then(|card| card.get_attribute("data-actor-id").map(|value| value.trim().to_string()))
}

fn ensure_character_panel_selection_binding(document: &web_sys::Document) {
    let Some(panel) = document.get_element_by_id("character-panel") else {
        return;
    };
    if panel
        .get_attribute("data-bound-select")
        .as_deref()
        .map(|value| value == "1")
        .unwrap_or(false)
    {
        return;
    }

    let cb = Closure::wrap(Box::new(move |evt: web_sys::Event| {
        let Some(target) = evt.target() else {
            return;
        };
        let Some(actor_id) = resolve_character_card_actor_id(target) else {
            return;
        };
        if actor_id.is_empty() {
            return;
        }
        let Some(document) = web_sys::window().and_then(|window| window.document()) else {
            return;
        };
        select_character_card(&document, &actor_id);
    }) as Box<dyn FnMut(_)>);
    let _ = panel.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref());
    cb.forget();
    let key_cb = Closure::wrap(Box::new(move |evt: web_sys::KeyboardEvent| {
        if evt.key() != "Enter" && evt.key() != " " && evt.key() != "Spacebar" {
            return;
        }
        let Some(target) = evt.target() else {
            return;
        };
        let Some(actor_id) = resolve_character_card_actor_id(target) else {
            return;
        };
        if actor_id.is_empty() {
            return;
        }
        let Some(document) = web_sys::window().and_then(|window| window.document()) else {
            return;
        };
        select_character_card(&document, &actor_id);
        evt.prevent_default();
    }) as Box<dyn FnMut(_)>);
    let _ = panel
        .add_event_listener_with_callback("keydown", key_cb.as_ref().unchecked_ref());
    key_cb.forget();
    let _ = panel.set_attribute("data-bound-select", "1");
}

/// Re-renders the #character-panel DOM whenever actor state changes.
pub fn update_character_panel_dom(
    actors: Query<&Actor>,
    mut cache: ResMut<CharacterPanelCache>,
    progress: Res<TurnProgressState>,
) {
    // Build current snapshot for cheap equality check
    let compat_snapshot: Vec<(String, i32, bool, bool, bool, bool, bool)> = actors
        .iter()
        .map(|a| {
            (
                a.id.clone(),
                a.hp,
                a.is_dead,
                a.hp_known,
                a.max_hp_known,
                a.mp_known,
                a.max_mp_known,
            )
        })
        .collect();

    let full_snapshot: Vec<ActorSnapshot> = actors
        .iter()
        .map(|a| ActorSnapshot {
            id: a.id.clone(),
            hp: a.hp,
            hp_known: a.hp_known,
            max_hp_known: a.max_hp_known,
            mp: a.mp,
            mp_known: a.mp_known,
            max_mp_known: a.max_mp_known,
            is_dead: a.is_dead,
            atk_known: a.atk_known,
            def_known: a.def_known,
            int_known: a.int_known,
            luck_known: a.luck_known,
            buff_count: a.buffs.len(),
            debuff_count: a.debuffs.len(),
            skill_count: a.skills.len(),
            condition_count: a.conditions.len(),
            equip_count: a.equipment.len(),
            relation_count: a.relationships.len(),
            contribution_score: a.contribution_score,
            contribution_last_reason: a.contribution_last_reason.trim().to_string(),
            contribution_reasons_fingerprint: a.contribution_reasons.join("|"),
            relationship_fingerprint: a.relationships.join("|"),
        })
        .collect();

    let mut actor_state_rows = progress
        .actor_states
        .iter()
        .map(|(actor, state)| format!("{}={}", actor.trim(), state.trim()))
        .collect::<Vec<_>>();
    actor_state_rows.sort();
    let mut actor_reason_rows = progress
        .actor_reasons
        .iter()
        .map(|(actor, reason)| format!("{}={}", actor.trim(), reason.trim()))
        .collect::<Vec<_>>();
    actor_reason_rows.sort();
    let narrative_count = web_sys::window()
        .and_then(|w| w.document())
        .and_then(|d| d.get_element_by_id("narrative-log"))
        .map(|el| el.child_element_count())
        .unwrap_or(0);
    let progress_signature = format!(
        "{}|{}|{}|{}|{}",
        progress.turn,
        progress.phase.trim(),
        actor_state_rows.join(","),
        actor_reason_rows.join(","),
        narrative_count
    );

    // Skip if nothing changed
    if compat_snapshot == cache.last_snapshot
        && full_snapshot == cache.last_full
        && progress_signature == cache.last_progress_signature
    {
        return;
    }
    cache.last_snapshot = compat_snapshot;
    cache.last_full = full_snapshot;
    cache.last_progress_signature = progress_signature;

    let Some(document) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(panel) = document.get_element_by_id("character-panel") else {
        return;
    };

    // Read which sections are expanded before we wipe innerHTML
    let expanded = {
        #[cfg(target_arch = "wasm32")]
        {
            read_collapse_state(&document)
        }
        #[cfg(not(target_arch = "wasm32"))]
        {
            read_collapse_state()
        }
    };

    let mut html = String::new();
    let mut card_ids = std::collections::HashSet::new();

    for actor in actors.iter() {
        let card_id = ensure_unique_dom_id(&format!("actor-{}", dom_safe_id(&actor.id)), &mut card_ids);
        let escaped_actor_id = html_escape(&actor.id);
        let data_actor_id = escaped_actor_id.clone();
        let hp_display = metric_text(actor.hp, actor.hp_known, actor.max_hp, actor.max_hp_known);
        let mp_display = metric_text(actor.mp, actor.mp_known, actor.max_mp, actor.max_mp_known);
        let hp_display_class = metric_text_class(actor.hp_known, actor.max_hp_known);
        let mp_display_class = metric_text_class(actor.mp_known, actor.max_mp_known);
        let hp_pct = if actor.hp_known && actor.max_hp_known && actor.max_hp > 0 {
            ((actor.hp.max(0) as f32 / actor.max_hp.max(1) as f32) * 100.0).clamp(0.0, 100.0)
        } else {
            0.0
        };
        let mp_pct = if actor.mp_known && actor.max_mp_known && actor.max_mp > 0 {
            ((actor.mp.max(0) as f32 / actor.max_mp.max(1) as f32) * 100.0).clamp(0.0, 100.0)
        } else {
            0.0
        };
        let dead_class = if actor.is_dead { " dead" } else { "" };
        let bar_class = hp_class(actor.hp, actor.max_hp);
        let mp_bar_class = mp_class(actor.mp, actor.max_mp);
        let icon = class_icon(&actor.class);
        let slug = class_slug(&actor.class);
        let portrait_html = if let Some(url) = portrait_url_for_actor(actor) {
            format!(
                "<div class=\"char-portrait-wrap\"><img class=\"char-portrait\" src=\"{}\" alt=\"{} portrait\" loading=\"lazy\" decoding=\"async\" /></div>",
                html_escape(&url),
                html_escape(&actor.name),
            )
        } else {
            format!(
                "<div class=\"char-portrait-wrap\"><div class=\"char-portrait-fallback\" aria-hidden=\"true\">{}</div></div>",
                html_escape(&actor_initials(&actor.name, &actor.id)),
            )
        };
        let is_thinking = progress
            .actor_states
            .get(&actor.id)
            .map_or(false, |s| s == "thinking");
        let keeper_line = if actor.keeper.trim().is_empty() {
            "<div class=\"char-owner owner-unassigned\">keeper: 미할당</div>".to_string()
        } else {
            let thinking_class = if is_thinking { " keeper-thinking" } else { "" };
            format!(
                "<div class=\"char-owner owner-assigned{}\">keeper: {}{}</div>",
                thinking_class,
                html_escape(&actor.keeper),
                if is_thinking { " (thinking...)" } else { "" },
            )
        };
        let archetype_line = if actor.archetype.trim().is_empty() {
            String::new()
        } else {
            format!(
                "<span class=\"char-archetype\">{}</span>",
                html_escape(actor.archetype.trim())
            )
        };
        let persona_line = if actor.persona.trim().is_empty() {
            String::new()
        } else {
            let persona = html_escape(actor.persona.trim());
            format!(
                "<span class=\"char-persona\" title=\"{}\">{}</span>",
                persona, persona
            )
        };
        let lore_line = if archetype_line.is_empty() && persona_line.is_empty() {
            String::new()
        } else {
            format!(
                "<div class=\"char-lore\">{}{}</div>",
                archetype_line, persona_line
            )
        };
        let runtime_state = progress
            .actor_states
            .get(&actor.id)
            .map(|value| value.trim().to_string())
            .unwrap_or_default();
        let runtime_reason = progress
            .actor_reasons
            .get(&actor.id)
            .map(|value| value.trim().to_string())
            .unwrap_or_default();
        let runtime_line = if runtime_state.is_empty() && runtime_reason.is_empty() {
            String::new()
        } else {
            format!(
                "<div class=\"char-runtime\">state: {} · reason: {}</div>",
                html_escape(if runtime_state.is_empty() {
                    "상태 없음"
                } else {
                    runtime_state.as_str()
                }),
                html_escape(if runtime_reason.is_empty() {
                    "사유 없음"
                } else {
                    runtime_reason.as_str()
                })
            )
        };
        let contribution_line = if actor.contribution_score == 0
            && actor.contribution_last_reason.trim().is_empty()
        {
            String::new()
        } else {
            format!(
                "<div class=\"char-contribution\">기여 {} · {}</div>",
                actor.contribution_score,
                html_escape(if actor.contribution_last_reason.trim().is_empty() {
                    "기여 사유 없음"
                } else {
                    actor.contribution_last_reason.trim()
                })
            )
        };
        let relationships_attr = actor.relationships.join(" | ");
        let contribution_reasons_attr = actor.contribution_reasons.join(" | ");

        // Buffs / debuffs
        let buffs_html = actor
            .buffs
            .iter()
            .map(|b| format!("<span class=\"buff\">+{}</span>", b))
            .collect::<Vec<_>>()
            .join("");
        let debuffs_html = actor
            .debuffs
            .iter()
            .map(|d| format!("<span class=\"debuff\">-{}</span>", d))
            .collect::<Vec<_>>()
            .join("");

        // Conditions section
        let conditions_html = if actor.conditions.is_empty() {
            String::new()
        } else {
            let items: String = actor
                .conditions
                .iter()
                .map(|c| {
                    let turns = c
                        .remaining_turns
                        .map(|t| format!(" <span class=\"condition-turns\">{t}t</span>"))
                        .unwrap_or_default();
                    format!(
                        "<span class=\"condition-badge\">{} {}{}</span>",
                        condition_icon(&c.name),
                        c.name,
                        turns,
                    )
                })
                .collect::<Vec<_>>()
                .join("");
            format!("<div class=\"conditions-row\">{}</div>", items)
        };

        // Collapsible section IDs
        let traits_id = format!("{}-traits", card_id);
        let skills_id = format!("{}-skills", card_id);
        let equip_id = format!("{}-equip", card_id);

        let traits_checked = if expanded.contains(&traits_id) {
            " checked"
        } else {
            ""
        };
        let skills_checked = if expanded.contains(&skills_id) {
            " checked"
        } else {
            ""
        };
        let equip_checked = if expanded.contains(&equip_id) {
            " checked"
        } else {
            ""
        };

        // Traits section
        let traits_section = if actor.traits.is_empty() {
            String::new()
        } else {
            let rows: String = actor
                .traits
                .iter()
                .map(|trait_name| {
                    let escaped_name = html_escape(trait_name);
                    let description = trait_description(trait_name);
                    format!(
                        concat!(
                            "<div class=\"trait-row\">",
                            "<div class=\"trait-main\">",
                            "<span class=\"trait-icon\">{}</span>",
                            "<span class=\"trait-name\">{}</span>",
                            "</div>",
                            "<div class=\"trait-desc\">{}</div>",
                            "</div>",
                        ),
                        trait_icon(trait_name),
                        escaped_name,
                        html_escape(&description),
                    )
                })
                .collect::<Vec<_>>()
                .join("");
            format!(
                concat!(
                    "<input type=\"checkbox\" class=\"section-toggle\" id=\"{}\"{}/>",
                    "<label class=\"section-header\" for=\"{}\" title=\"Trait은 캐릭터의 행동 성향입니다.\">Traits (성향) <span class=\"section-count\">({})</span></label>",
                    "<div class=\"section-body traits-list\">{}</div>",
                ),
                traits_id, traits_checked,
                traits_id,
                actor.traits.len(),
                format!(
                    "{}{}",
                    "<div class=\"section-guide\">행동 선택 방향을 잡는 성향 태그입니다.</div>",
                    rows
                ),
            )
        };

        // Skills section
        let skills_section = if actor.skills.is_empty() {
            String::new()
        } else {
            let rows: String = actor
                .skills
                .iter()
                .map(|s| {
                    let m = s.modifier();
                    let (description, usage_hint, dnd5_check) = skill_copy(s, actor);
                    let escaped_name = html_escape(&s.name);
                    let escaped_desc = html_escape(&description);
                    let escaped_hint = html_escape(&usage_hint);
                    let escaped_dnd = html_escape(&dnd5_check);
                    let mod_class = if m > 0 {
                        "mod-positive"
                    } else if m < 0 {
                        "mod-negative"
                    } else {
                        "mod-neutral"
                    };
                    let dnd_line = if dnd5_check.trim().is_empty() {
                        String::new()
                    } else {
                        format!("<div class=\"skill-dnd\">{}</div>", escaped_dnd)
                    };
                    let hint_line = if usage_hint.trim().is_empty() {
                        String::new()
                    } else {
                        format!("<div class=\"skill-hint\">Hint: {}</div>", escaped_hint)
                    };
                    format!(
                        concat!(
                            "<div class=\"skill-row\">",
                            "<div class=\"skill-main\">",
                            "<span class=\"skill-name\">{}</span>",
                            "<span class=\"skill-level\">Lv{}</span>",
                            "<span class=\"skill-mod {}\">{}</span>",
                            "</div>",
                            "<div class=\"skill-desc\">{}</div>",
                            "{}",
                            "{}",
                            "</div>"
                        ),
                        escaped_name,
                        s.level,
                        mod_class,
                        fmt_modifier(m),
                        escaped_desc,
                        dnd_line,
                        hint_line,
                    )
                })
                .collect::<Vec<_>>()
                .join("");
            let head = "<div class=\"skill-row skill-row-head\"><span class=\"skill-name\">Skill</span><span class=\"skill-level\">Lv</span><span class=\"skill-mod mod-neutral\">Mod (Lv-10)/2</span></div>";
            format!(
                concat!(
                    "<input type=\"checkbox\" class=\"section-toggle\" id=\"{}\"{}/>",
                    "<label class=\"section-header\" for=\"{}\" title=\"Skill 수치는 액션/주사위 판정에 사용됩니다.\">Skills (판정) <span class=\"section-count\">({})</span></label>",
                    "<div class=\"section-body skills-list\">{}</div>",
                ),
                skills_id, skills_checked,
                skills_id,
                actor.skills.len(),
                format!(
                    "{}{}{}",
                    "<div class=\"section-guide\">액션/주사위 판정 보정치입니다. 기본 계산: Mod = (Lv-10)/2, D&D5 권장 체크를 함께 참고하세요.</div>",
                    head,
                    rows
                ),
            )
        };

        // Equipment section
        let equip_section = if actor.equipment.is_empty() {
            String::new()
        } else {
            let rows: String = actor
                .equipment
                .iter()
                .map(|e| {
                    format!(
                        "<div class=\"equip-row\"><span class=\"equip-icon\">{}</span><span class=\"equip-slot\">{}</span><span class=\"equip-name\">{}</span></div>",
                        slot_icon(&e.slot), e.slot, e.name,
                    )
                })
                .collect::<Vec<_>>()
                .join("");
            format!(
                concat!(
                    "<input type=\"checkbox\" class=\"section-toggle\" id=\"{}\"{}/>",
                    "<label class=\"section-header\" for=\"{}\">Equipment <span class=\"section-count\">({})</span></label>",
                    "<div class=\"section-body equip-list\">{}</div>",
                ),
                equip_id, equip_checked,
                equip_id,
                actor.equipment.len(),
                rows,
            )
        };

        // Metrics row - hide synthetic bar when max is unknown.
        let hp_row = if actor.hp_known && actor.max_hp_known && actor.max_hp > 0 {
            format!(
                concat!(
                    "<div class=\"hp-row\">",
                    "<div class=\"hp-bar-container\">",
                    "<div class=\"hp-bar-fill {}\" style=\"width: {}%\"></div>",
                    "</div>",
                    "<div class=\"hp-text actor-inspector-metric {}\">{}</div>",
                    "</div>",
                ),
                bar_class,
                hp_pct,
                hp_display_class,
                html_escape(&hp_display),
            )
        } else {
            format!(
                "<div class=\"hp-row\"><div class=\"hp-text actor-inspector-metric {}\">{}</div></div>",
                hp_display_class,
                html_escape(&hp_display),
            )
        };
        let mp_row = if actor.mp_known && actor.max_mp_known && actor.max_mp > 0 {
            format!(
                concat!(
                    "<div class=\"mp-row\">",
                    "<div class=\"mp-bar-container\">",
                    "<div class=\"mp-bar-fill {}\" style=\"width: {}%\"></div>",
                    "</div>",
                    "<div class=\"mp-text actor-inspector-metric {}\">{}</div>",
                    "</div>",
                ),
                mp_bar_class,
                mp_pct,
                mp_display_class,
                html_escape(&mp_display),
            )
        } else {
            format!(
                "<div class=\"mp-row\"><div class=\"mp-text actor-inspector-metric {}\">{}</div></div>",
                mp_display_class,
                html_escape(&mp_display),
            )
        };

        let hp_attr = if actor.hp_known { "1" } else { "0" };
        let max_hp_attr = if actor.max_hp_known { "1" } else { "0" };
        let mp_attr = if actor.mp_known { "1" } else { "0" };
        let max_mp_attr = if actor.max_mp_known { "1" } else { "0" };
        let display_name = if actor.name.trim().is_empty() {
            actor.id.clone()
        } else {
            actor.name.clone()
        };
        let atk_attr = if actor.atk_known { "1" } else { "0" };
        let def_attr = if actor.def_known { "1" } else { "0" };
        let int_attr = if actor.int_known { "1" } else { "0" };
        let luck_attr = if actor.luck_known { "1" } else { "0" };

        html.push_str(&format!(
            concat!(
                "<div class=\"character-card{}\" role=\"button\" tabindex=\"0\" aria-label=\"{} 선택\" ",
                "id=\"{}\" data-card-id=\"{}\" data-actor-id=\"{}\" data-class=\"{}\" ",
                "data-actor-name=\"{}\" data-actor-class=\"{}\" data-keeper=\"{}\" ",
                "data-archetype=\"{}\" data-persona=\"{}\" ",
                "data-runtime-state=\"{}\" data-runtime-reason=\"{}\" ",
                "data-hp=\"{}\" data-max-hp=\"{}\" data-hp-known=\"{}\" data-max-hp-known=\"{}\" ",
                "data-mp=\"{}\" data-max-mp=\"{}\" data-mp-known=\"{}\" data-max-mp-known=\"{}\" ",
                "data-atk=\"{}\" data-atk-known=\"{}\" data-def=\"{}\" data-def-known=\"{}\" ",
                "data-int=\"{}\" data-int-known=\"{}\" data-luck=\"{}\" data-luck-known=\"{}\" ",
                "data-contribution-score=\"{}\" data-contribution-reason=\"{}\" data-contribution-reasons=\"{}\" ",
                "data-relationships=\"{}\" aria-selected=\"false\">",
                "<div class=\"char-header\">",
                "{}",
                "<div class=\"char-identity\">",
                "<span class=\"char-name\">{}</span>",
                "<span class=\"char-class\"><span class=\"class-icon\">{}</span> {}</span>",
                "{}",
                "</div>",
                "</div>",
                "{}",
                "{}",
                "{}",
                "{}",
                "<div class=\"char-stats\">",
                "<div class=\"stat\"><div class=\"stat-value actor-metric-{}\">{}</div><div class=\"stat-label\">ATK</div></div>",
                "<div class=\"stat\"><div class=\"stat-value actor-metric-{}\">{}</div><div class=\"stat-label\">DEF</div></div>",
                "<div class=\"stat\"><div class=\"stat-value actor-metric-{}\">{}</div><div class=\"stat-label\">INT</div></div>",
                "<div class=\"stat\"><div class=\"stat-value actor-metric-{}\">{}</div><div class=\"stat-label\">LCK</div></div>",
                "</div>",
                "{}",
                "<div class=\"char-effects\">{}{}</div>",
                "{}",
                "{}",
                "{}",
                "{}",
                "</div>",
            ),
                dead_class,
                card_id,
                card_id,
                html_escape(&display_name),
                data_actor_id,
                slug,
                html_escape(&actor.name),
            html_escape(&actor.class),
            html_escape(&actor.keeper),
            html_escape(actor.archetype.trim()),
            html_escape(actor.persona.trim()),
            html_escape(&runtime_state),
            html_escape(&runtime_reason),
            actor.hp,
            actor.max_hp,
            hp_attr,
            max_hp_attr,
            actor.mp,
            actor.max_mp,
            mp_attr,
            max_mp_attr,
            actor.stats.atk,
            atk_attr,
            actor.stats.def,
            def_attr,
            actor.stats.int,
            int_attr,
            actor.stats.luck,
            luck_attr,
            actor.contribution_score,
            html_escape(actor.contribution_last_reason.trim()),
            html_escape(&contribution_reasons_attr),
            html_escape(&relationships_attr),
            portrait_html,
            actor.name,
            icon,
            actor.class,
            lore_line,
            keeper_line,
            runtime_line,
            contribution_line,
            hp_row,
            mp_row,
            metric_text_class(actor.atk_known, true),
            html_escape(&known_stat_text(actor.stats.atk, actor.atk_known)),
            metric_text_class(actor.def_known, true),
            html_escape(&known_stat_text(actor.stats.def, actor.def_known)),
            metric_text_class(actor.int_known, true),
            html_escape(&known_stat_text(actor.stats.int, actor.int_known)),
            metric_text_class(actor.luck_known, true),
            html_escape(&known_stat_text(actor.stats.luck, actor.luck_known)),
            conditions_html,
            buffs_html,
            debuffs_html,
            traits_section,
            skills_section,
            equip_section,
        ));
    }

    panel.set_inner_html(&html);
    ensure_character_panel_selection_binding(&document);

    let selected_actor = document
        .get_element_by_id("dashboard")
        .and_then(|el| el.get_attribute("data-selected-actor"))
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .or_else(|| {
            document
                .query_selector("#character-panel .character-card[data-actor-id]")
                .ok()
                .flatten()
                .and_then(|el| el.get_attribute("data-actor-id"))
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty())
        });
    if let Some(actor_id) = selected_actor {
        select_character_card(&document, &actor_id);
    } else {
        render_actor_inspector_empty(&document, DEFAULT_ACTOR_INSPECTOR_EMPTY_MESSAGE);
    }
}
