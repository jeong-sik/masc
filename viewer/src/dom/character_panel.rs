use bevy::prelude::*;

use crate::assets;
use crate::dom::escape::html_escape;
use crate::game::components::{Actor, Skill};

/// Snapshot of actor state used for change detection.
/// Re-render only fires when this changes.
#[derive(Clone, PartialEq)]
pub struct ActorSnapshot {
    id: String,
    hp: i32,
    mp: i32,
    is_dead: bool,
    buff_count: usize,
    debuff_count: usize,
    skill_count: usize,
    condition_count: usize,
    equip_count: usize,
}

/// Tracks the last known state so we only re-render on change.
#[derive(Resource, Default)]
pub struct CharacterPanelCache {
    pub last_snapshot: Vec<(String, i32, bool)>,
    pub last_full: Vec<ActorSnapshot>,
}

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

fn known_skill_lore(skill_name: &str) -> Option<(&'static str, &'static str)> {
    match normalize_lore_key(skill_name).as_str() {
        "mark_prey" => Some((
            "적 한 명을 추적 표식으로 지정해 파티의 집중 화력을 유도합니다.",
            "라운드 초반에 위협도가 높은 목표를 먼저 지정하면 효율이 큽니다.",
        )),
        "silent_route" => Some((
            "소음과 시야 노출을 줄여 우회/잠입 루트를 확보합니다.",
            "정면 충돌 전에 위치를 바꾸거나 기습 각도를 만들 때 사용하세요.",
        )),
        "finisher_strike" => Some((
            "체력이 깎인 목표를 마무리하는 처형형 기술입니다.",
            "아군의 선행 피해 후 연계하면 성공 판정이 잘 나옵니다.",
        )),
        "field_mend" => Some((
            "현장에서 빠르게 상처를 봉합해 전열 붕괴를 막습니다.",
            "집중 공격받는 아군에게 먼저 써서 다운을 방지하세요.",
        )),
        "truce_window" => Some((
            "짧은 휴전 창을 만들어 협상/재정비 턴을 확보합니다.",
            "적이 강하거나 정보가 부족할 때 시간을 벌기 좋습니다.",
        )),
        "resolve_hymn" => Some((
            "파티의 동요를 진정시키고 의지를 끌어올리는 결의 기술입니다.",
            "연속 실패 뒤 사기 회복용으로 쓰면 흐름 복구에 유리합니다.",
        )),
        "deception_feint" => Some((
            "거짓 동작으로 적 판단을 흔들어 빈틈을 만듭니다.",
            "정면 돌파보다 교란이 필요한 국면에서 효과적입니다.",
        )),
        "favor_broker" => Some((
            "관계/빚을 거래해 협력이나 정보 제공을 이끌어냅니다.",
            "NPC 또는 파티 설득 상황에서 선택지를 늘릴 때 사용하세요.",
        )),
        "shadow_entry" => Some((
            "그림자 동선을 타고 경계망 안쪽으로 침투합니다.",
            "탐지 리스크가 높은 구간을 넘어야 할 때 가장 안정적입니다.",
        )),
        "supply_scan" => Some((
            "보급/자원 상태를 점검해 부족 항목을 조기에 찾습니다.",
            "장기전 직전이나 이벤트 전환 전에 사용하면 손실을 줄입니다.",
        )),
        "ration_shift" => Some((
            "자원 배분을 재조정해 생존 시간을 늘립니다.",
            "당장 화력보다 지속력이 중요한 턴에 우선 사용하세요.",
        )),
        "logistics_patch" => Some((
            "끊긴 보급 동선을 임시 복구해 팀 운영을 안정화합니다.",
            "연속 이벤트로 소모가 누적될 때 유지력 확보에 핵심입니다.",
        )),
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
        "pragmatic" => "당장 생존과 효율을 우선해 자원 운용 판단이 빠릅니다.".to_string(),
        "frugal" => "소모를 줄여 장기전에서 팀 유지력을 끌어올립니다.".to_string(),
        "impatient" => "결단은 빠르지만 장기 설정보다 즉시 행동을 선호합니다.".to_string(),
        _ => "상황 선택에 성향 보정을 주는 캐릭터 특성입니다.".to_string(),
    }
}

fn fallback_skill_description(_actor: &Actor, skill_name: &str, modifier: i32) -> String {
    if let Some((description, _hint)) = known_skill_lore(skill_name) {
        return description.to_string();
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
    if let Some((_description, hint)) = known_skill_lore(skill_name) {
        return hint.to_string();
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

fn skill_copy(skill: &Skill, actor: &Actor) -> (String, String) {
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
    (description, usage_hint)
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

/// Re-renders the #character-panel DOM whenever actor state changes.
pub fn update_character_panel_dom(actors: Query<&Actor>, mut cache: ResMut<CharacterPanelCache>) {
    // Build current snapshot for cheap equality check
    let compat_snapshot: Vec<(String, i32, bool)> = actors
        .iter()
        .map(|a| (a.id.clone(), a.hp, a.is_dead))
        .collect();

    let full_snapshot: Vec<ActorSnapshot> = actors
        .iter()
        .map(|a| ActorSnapshot {
            id: a.id.clone(),
            hp: a.hp,
            mp: a.mp,
            is_dead: a.is_dead,
            buff_count: a.buffs.len(),
            debuff_count: a.debuffs.len(),
            skill_count: a.skills.len(),
            condition_count: a.conditions.len(),
            equip_count: a.equipment.len(),
        })
        .collect();

    // Skip if nothing changed
    if compat_snapshot == cache.last_snapshot && full_snapshot == cache.last_full {
        return;
    }
    cache.last_snapshot = compat_snapshot;
    cache.last_full = full_snapshot;

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

    for actor in actors.iter() {
        let hp_pct = if actor.max_hp > 0 {
            (actor.hp as f32 / actor.max_hp as f32 * 100.0).max(0.0)
        } else {
            0.0
        };
        let mp_pct = if actor.max_mp > 0 {
            (actor.mp as f32 / actor.max_mp as f32 * 100.0).max(0.0)
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
        let keeper_line = if actor.keeper.trim().is_empty() {
            "<div class=\"char-owner owner-unassigned\">keeper: (unassigned)</div>".to_string()
        } else {
            format!(
                "<div class=\"char-owner owner-assigned\">keeper: {}</div>",
                actor.keeper
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
        let traits_id = format!("toggle-traits-{}", actor.id);
        let skills_id = format!("toggle-skills-{}", actor.id);
        let equip_id = format!("toggle-equip-{}", actor.id);

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
                    let (description, usage_hint) = skill_copy(s, actor);
                    let escaped_name = html_escape(&s.name);
                    let escaped_desc = html_escape(&description);
                    let escaped_hint = html_escape(&usage_hint);
                    let mod_class = if m > 0 {
                        "mod-positive"
                    } else if m < 0 {
                        "mod-negative"
                    } else {
                        "mod-neutral"
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
                            "</div>"
                        ),
                        escaped_name,
                        s.level,
                        mod_class,
                        fmt_modifier(m),
                        escaped_desc,
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
                    "<div class=\"section-guide\">액션/주사위 판정 보정치입니다. 기본 계산: Mod = (Lv-10)/2</div>",
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

        // MP bar (only if max_mp > 0)
        let mp_row = if actor.max_mp > 0 {
            format!(
                concat!(
                    "<div class=\"mp-row\">",
                    "<div class=\"mp-bar-container\">",
                    "<div class=\"mp-bar-fill {}\" style=\"width: {}%\"></div>",
                    "</div>",
                    "<div class=\"mp-text\">{} / {}</div>",
                    "</div>",
                ),
                mp_bar_class, mp_pct, actor.mp, actor.max_mp,
            )
        } else {
            String::new()
        };

        html.push_str(&format!(
            concat!(
                "<div class=\"character-card{}\" data-actor-id=\"{}\" data-class=\"{}\">",
                "<div class=\"char-header\">",
                "{}",
                "<div class=\"char-identity\">",
                "<span class=\"char-name\">{}</span>",
                "<span class=\"char-class\"><span class=\"class-icon\">{}</span> {}</span>",
                "{}",
                "</div>",
                "</div>",
                "{}",
                "<div class=\"hp-row\">",
                "<div class=\"hp-bar-container\">",
                "<div class=\"hp-bar-fill {}\" style=\"width: {}%\"></div>",
                "</div>",
                "<div class=\"hp-text\">{} / {}</div>",
                "</div>",
                "{}",
                "<div class=\"char-stats\">",
                "<div class=\"stat\"><div class=\"stat-value\">{}</div><div class=\"stat-label\">ATK</div></div>",
                "<div class=\"stat\"><div class=\"stat-value\">{}</div><div class=\"stat-label\">DEF</div></div>",
                "<div class=\"stat\"><div class=\"stat-value\">{}</div><div class=\"stat-label\">INT</div></div>",
                "<div class=\"stat\"><div class=\"stat-value\">{}</div><div class=\"stat-label\">LCK</div></div>",
                "</div>",
                "{}",
                "<div class=\"char-effects\">{}{}</div>",
                "{}",
                "{}",
                "{}",
                "</div>",
            ),
            dead_class,
            actor.id,
            slug,
            portrait_html,
            actor.name,
            icon,
            actor.class,
            lore_line,
            keeper_line,
            bar_class,
            hp_pct,
            actor.hp,
            actor.max_hp,
            mp_row,
            actor.stats.atk,
            actor.stats.def,
            actor.stats.int,
            actor.stats.luck,
            conditions_html,
            buffs_html,
            debuffs_html,
            traits_section,
            skills_section,
            equip_section,
        ));
    }

    panel.set_inner_html(&html);
}
