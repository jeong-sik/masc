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
            r#"<div class="character-card{}">
  <div class="char-header">
    <span class="char-name">{}</span>
    <span class="char-class">{}</span>
  </div>
  <div class="hp-bar-container">
    <div class="hp-bar-fill {}" style="width: {}%"></div>
  </div>
  <div class="hp-text">{} / {}</div>
  <div class="char-stats">
    <div class="stat"><div class="stat-value">{}</div>ATK</div>
    <div class="stat"><div class="stat-value">{}</div>DEF</div>
    <div class="stat"><div class="stat-value">{}</div>INT</div>
    <div class="stat"><div class="stat-value">{}</div>LCK</div>
  </div>
  <div class="char-effects">{}{}</div>
</div>"#,
            dead_class,
            actor.name,
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
