use bevy::prelude::*;

use crate::game::components::Actor;

/// Tracks the last known HP values so we only re-render on change.
#[derive(Resource, Default)]
pub struct CharacterPanelCache {
    pub last_snapshot: Vec<(String, i32, bool)>, // (id, hp, is_dead)
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
    class.to_lowercase().replace(|c: char| !c.is_ascii_alphanumeric(), "-")
}

/// Re-renders the #character-panel DOM whenever actor HP changes.
pub fn update_character_panel_dom(
    actors: Query<&Actor>,
    mut cache: ResMut<CharacterPanelCache>,
) {
    // Build current snapshot
    let snapshot: Vec<(String, i32, bool)> = actors
        .iter()
        .map(|a| (a.id.clone(), a.hp, a.is_dead))
        .collect();

    // Skip if nothing changed
    if snapshot == cache.last_snapshot {
        return;
    }
    cache.last_snapshot = snapshot;

    let Some(document) = web_sys::window().and_then(|w| w.document()) else {
        return;
    };
    let Some(panel) = document.get_element_by_id("character-panel") else {
        return;
    };

    let mut html = String::new();

    for actor in actors.iter() {
        let hp_pct = if actor.max_hp > 0 {
            (actor.hp as f32 / actor.max_hp as f32 * 100.0).max(0.0)
        } else {
            0.0
        };
        let dead_class = if actor.is_dead { " dead" } else { "" };
        let bar_class = hp_class(actor.hp, actor.max_hp);
        let icon = class_icon(&actor.class);
        let slug = class_slug(&actor.class);

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

        html.push_str(&format!(
            r#"<div class="character-card{}" data-actor-id="{}" data-class="{}">
  <div class="char-header">
    <span class="char-name">{}</span>
    <span class="char-class"><span class="class-icon">{}</span> {}</span>
  </div>
  <div class="hp-row">
    <div class="hp-bar-container">
      <div class="hp-bar-fill {}" style="width: {}%"></div>
    </div>
    <div class="hp-text">{} / {}</div>
  </div>
  <div class="char-stats">
    <div class="stat"><div class="stat-value">{}</div><div class="stat-label">ATK</div></div>
    <div class="stat"><div class="stat-value">{}</div><div class="stat-label">DEF</div></div>
    <div class="stat"><div class="stat-value">{}</div><div class="stat-label">INT</div></div>
    <div class="stat"><div class="stat-value">{}</div><div class="stat-label">LCK</div></div>
  </div>
  <div class="char-effects">{}{}</div>
</div>"#,
            dead_class,
            actor.id,
            slug,
            actor.name,
            icon,
            actor.class,
            bar_class,
            hp_pct,
            actor.hp,
            actor.max_hp,
            actor.stats.atk,
            actor.stats.def,
            actor.stats.int,
            actor.stats.luck,
            buffs_html,
            debuffs_html,
        ));
    }

    panel.set_inner_html(&html);
}
