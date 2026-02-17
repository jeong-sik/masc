use bevy::prelude::*;

use crate::game::components::Actor;

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
        let keeper_line = if actor.keeper.trim().is_empty() {
            "<div class=\"char-owner owner-unassigned\">keeper: (unassigned)</div>".to_string()
        } else {
            format!(
                "<div class=\"char-owner owner-assigned\">keeper: {}</div>",
                actor.keeper
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
        let skills_id = format!("toggle-skills-{}", actor.id);
        let equip_id = format!("toggle-equip-{}", actor.id);

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

        // Skills section
        let skills_section = if actor.skills.is_empty() {
            String::new()
        } else {
            let rows: String = actor
                .skills
                .iter()
                .map(|s| {
                    let m = s.modifier();
                    let mod_class = if m > 0 {
                        "mod-positive"
                    } else if m < 0 {
                        "mod-negative"
                    } else {
                        "mod-neutral"
                    };
                    format!(
                        "<div class=\"skill-row\"><span class=\"skill-name\">{}</span><span class=\"skill-level\">{}</span><span class=\"skill-mod {}\">{}</span></div>",
                        s.name, s.level, mod_class, fmt_modifier(m),
                    )
                })
                .collect::<Vec<_>>()
                .join("");
            format!(
                concat!(
                    "<input type=\"checkbox\" class=\"section-toggle\" id=\"{}\"{}/>",
                    "<label class=\"section-header\" for=\"{}\">Skills <span class=\"section-count\">({})</span></label>",
                    "<div class=\"section-body skills-list\">{}</div>",
                ),
                skills_id, skills_checked,
                skills_id,
                actor.skills.len(),
                rows,
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
                "<span class=\"char-name\">{}</span>",
                "<span class=\"char-class\"><span class=\"class-icon\">{}</span> {}</span>",
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
                "</div>",
            ),
            dead_class,
            actor.id,
            slug,
            actor.name,
            icon,
            actor.class,
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
            skills_section,
            equip_section,
        ));
    }

    panel.set_inner_html(&html);
}
