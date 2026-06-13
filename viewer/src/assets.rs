/// Asset path constants for AI-generated artwork.
pub mod paths {
    // Character portraits — Grimland originals (512x512, PNG, oil painting)
    pub const PORTRAIT_GRIMJA: &str = "portraits/grimja.png";
    pub const PORTRAIT_LUNA: &str = "portraits/luna.png";
    pub const PORTRAIT_SONGARAK: &str = "portraits/songarak.png";
    pub const PORTRAIT_MISO: &str = "portraits/miso.png";

    // Character portraits — Identity Erosion scenario (512x512, PNG)
    pub const PORTRAIT_IRON: &str = "portraits/iron.png";
    pub const PORTRAIT_MOTH: &str = "portraits/moth.png";
    pub const PORTRAIT_BELL: &str = "portraits/bell.png";
    pub const PORTRAIT_DUST: &str = "portraits/dust.png";

    // Character portraits — Conformity Pressure scenario (512x512, PNG)
    pub const PORTRAIT_ALDRIC: &str = "portraits/aldric.png";
    pub const PORTRAIT_BRENNA: &str = "portraits/brenna.png";
    pub const PORTRAIT_CEDRIC: &str = "portraits/cedric.png";
    pub const PORTRAIT_DARA: &str = "portraits/dara.png";

    // Area backgrounds — Grimland originals (1920x1080, JPEG)
    pub const MAP_AREA_A: &str = "maps/area_a.jpg";
    pub const MAP_AREA_B: &str = "maps/area_b.jpg";
    pub const MAP_AREA_C: &str = "maps/area_c.jpg";
    pub const MAP_AREA_D: &str = "maps/area_d.jpg";
    pub const MAP_AREA_E: &str = "maps/area_e.jpg";
    pub const MAP_AREA_F: &str = "maps/area_f.jpg";

    // Scenario backgrounds (1920x1080, JPEG)
    pub const MAP_MANOR_DINING: &str = "maps/manor_dining.jpg";
    pub const MAP_MANOR_STORM: &str = "maps/manor_storm.jpg";
    pub const MAP_MANOR_MORNING: &str = "maps/manor_morning.jpg";
    pub const MAP_COUNCIL_CHAMBER: &str = "maps/council_chamber.jpg";

    // Weather overlays (1920x1080, PNG with alpha)
    #[cfg(not(target_arch = "wasm32"))]
    pub const WEATHER_DRIZZLE: &str = "weather/weather_drizzle.png";
    #[cfg(not(target_arch = "wasm32"))]
    pub const WEATHER_HEAVY_RAIN: &str = "weather/weather_heavy_rain.png";
    #[cfg(not(target_arch = "wasm32"))]
    pub const WEATHER_FOG: &str = "weather/weather_fog.png";
    #[cfg(not(target_arch = "wasm32"))]
    pub const WEATHER_SILENCE: &str = "weather/weather_silence.png";

    // Mood overlays (1920x1080, PNG with alpha)
    #[cfg(not(target_arch = "wasm32"))]
    pub const MOOD_QUIET_UNEASE: &str = "moods/mood_quiet_unease.png";
    #[cfg(not(target_arch = "wasm32"))]
    pub const MOOD_TENSION_RISING: &str = "moods/mood_tension_rising.png";
    #[cfg(not(target_arch = "wasm32"))]
    pub const MOOD_AMBIGUOUS_CALM: &str = "moods/mood_ambiguous_calm.png";

    // Props — The Workspace scenario (512x512, PNG, transparent background)
    #[cfg(not(target_arch = "wasm32"))]
    pub const PROP_COMPASS: &str = "props/compass_broken.png";
    #[cfg(not(target_arch = "wasm32"))]
    pub const PROP_SEXTANT: &str = "props/sextant_mirror.png";
    #[cfg(not(target_arch = "wasm32"))]
    pub const PROP_JOURNAL: &str = "props/journal_open.png";
    #[cfg(not(target_arch = "wasm32"))]
    pub const PROP_MAPS: &str = "props/maps_recursive.png";
}

/// Returns the portrait asset path for a given character ID.
pub fn portrait_for(id: &str) -> Option<&'static str> {
    let normalized = id.trim().to_ascii_lowercase();

    // Common runtime actor IDs are p01..p08 (and many NPC-* IDs).
    if let Some(slot) = normalized.strip_prefix('p') {
        if let Ok(index) = slot.parse::<u8>() {
            return match index {
                1 => Some(paths::PORTRAIT_IRON),
                2 => Some(paths::PORTRAIT_ALDRIC),
                3 => Some(paths::PORTRAIT_MOTH),
                4 => Some(paths::PORTRAIT_DUST),
                5 => Some(paths::PORTRAIT_BELL),
                6 => Some(paths::PORTRAIT_BRENNA),
                7 => Some(paths::PORTRAIT_CEDRIC),
                8 => Some(paths::PORTRAIT_DARA),
                _ => None,
            };
        }
    }

    let key = normalized.replace(' ', "_");
    if key.starts_with("npc-") || key.starts_with("npc_") || key == "npc" {
        return Some(paths::PORTRAIT_CEDRIC);
    }
    if key.starts_with("mob-") || key.starts_with("monster-") || key == "enemy" {
        return Some(paths::PORTRAIT_DARA);
    }

    match key.as_str() {
        // Grimland originals
        "grimja" => Some(paths::PORTRAIT_GRIMJA),
        "luna" => Some(paths::PORTRAIT_LUNA),
        "songarak" => Some(paths::PORTRAIT_SONGARAK),
        "miso" => Some(paths::PORTRAIT_MISO),
        // Identity Erosion
        "iron" => Some(paths::PORTRAIT_IRON),
        "moth" => Some(paths::PORTRAIT_MOTH),
        "bell" => Some(paths::PORTRAIT_BELL),
        "dust" => Some(paths::PORTRAIT_DUST),
        // Conformity Pressure
        "aldric" => Some(paths::PORTRAIT_ALDRIC),
        "brenna" => Some(paths::PORTRAIT_BRENNA),
        "cedric" => Some(paths::PORTRAIT_CEDRIC),
        "dara" => Some(paths::PORTRAIT_DARA),
        // Party preset aliases (name + preset id)
        "brom" | "ironledger" => Some(paths::PORTRAIT_IRON),
        "kael" | "vowblade" => Some(paths::PORTRAIT_ALDRIC),
        "ena" | "stormseer" => Some(paths::PORTRAIT_MOTH),
        "rook" | "gravehound" => Some(paths::PORTRAIT_DUST),
        "mira" | "silkwhisper" => Some(paths::PORTRAIT_BELL),
        "sera" | "lumenfriar" => Some(paths::PORTRAIT_BRENNA),
        _ => None,
    }
}

/// Returns the map background asset path for a given area code or scene name.
pub fn map_for(area: &str) -> Option<&'static str> {
    match area {
        // Grimland area grid
        "A" => Some(paths::MAP_AREA_A),
        "B" => Some(paths::MAP_AREA_B),
        "C" => Some(paths::MAP_AREA_C),
        "D" => Some(paths::MAP_AREA_D),
        "E" => Some(paths::MAP_AREA_E),
        "F" => Some(paths::MAP_AREA_F),
        // Scenario-specific backgrounds
        "manor_dining" => Some(paths::MAP_MANOR_DINING),
        "manor_storm" => Some(paths::MAP_MANOR_STORM),
        "manor_morning" => Some(paths::MAP_MANOR_MORNING),
        "council_chamber" => Some(paths::MAP_COUNCIL_CHAMBER),
        _ => None,
    }
}

/// Returns the weather overlay asset path for a given weather ID.
#[cfg(not(target_arch = "wasm32"))]
pub fn weather_for(id: &str) -> Option<&'static str> {
    match id {
        "drizzle" => Some(paths::WEATHER_DRIZZLE),
        "heavy_rain" => Some(paths::WEATHER_HEAVY_RAIN),
        "fog" => Some(paths::WEATHER_FOG),
        "silence" => Some(paths::WEATHER_SILENCE),
        _ => None,
    }
}

/// Returns the mood overlay asset path for a given mood ID.
#[cfg(not(target_arch = "wasm32"))]
pub fn mood_for(id: &str) -> Option<&'static str> {
    match id {
        "quiet_unease" => Some(paths::MOOD_QUIET_UNEASE),
        "tension_rising" => Some(paths::MOOD_TENSION_RISING),
        "ambiguous_calm" => Some(paths::MOOD_AMBIGUOUS_CALM),
        _ => None,
    }
}

/// Returns the prop asset path for a given prop ID.
#[cfg(not(target_arch = "wasm32"))]
pub fn prop_for(id: &str) -> Option<&'static str> {
    match id {
        "compass" => Some(paths::PROP_COMPASS),
        "sextant" => Some(paths::PROP_SEXTANT),
        "journal" => Some(paths::PROP_JOURNAL),
        "maps" => Some(paths::PROP_MAPS),
        _ => None,
    }
}
