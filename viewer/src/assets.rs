use bevy::prelude::*;

/// Tracks asset loading state for the viewer.
#[derive(Resource, Default)]
pub struct AssetManifest {
    pub portraits_loaded: bool,
    pub maps_loaded: bool,
    pub fonts_loaded: bool,
}

/// Asset path constants for AI-generated artwork.
pub mod paths {
    // Character portraits (512x512, oil painting style)
    pub const PORTRAIT_GRIMJA: &str = "portraits/grimja.png";
    pub const PORTRAIT_LUNA: &str = "portraits/luna.png";
    pub const PORTRAIT_SONGARAK: &str = "portraits/songarak.png";
    pub const PORTRAIT_MISO: &str = "portraits/miso.png";

    // Area backgrounds (1920x1080, painterly gothic)
    pub const MAP_AREA_A: &str = "maps/area_a.png";
    pub const MAP_AREA_B: &str = "maps/area_b.png";
    pub const MAP_AREA_C: &str = "maps/area_c.png";
    pub const MAP_AREA_D: &str = "maps/area_d.png";
    pub const MAP_AREA_E: &str = "maps/area_e.png";
    pub const MAP_AREA_F: &str = "maps/area_f.png";

    // Fonts
    pub const FONT_GOTHIC: &str = "fonts/Cinzel-Regular.ttf";
    pub const FONT_KOREAN: &str = "fonts/NotoSansKR-Regular.ttf";
}

/// Returns the portrait asset path for a given character ID.
pub fn portrait_for(id: &str) -> Option<&'static str> {
    match id {
        "grimja" => Some(paths::PORTRAIT_GRIMJA),
        "luna" => Some(paths::PORTRAIT_LUNA),
        "songarak" => Some(paths::PORTRAIT_SONGARAK),
        "miso" => Some(paths::PORTRAIT_MISO),
        _ => None,
    }
}

/// Returns the map background asset path for a given area code.
pub fn map_for(area: &str) -> Option<&'static str> {
    match area {
        "A" => Some(paths::MAP_AREA_A),
        "B" => Some(paths::MAP_AREA_B),
        "C" => Some(paths::MAP_AREA_C),
        "D" => Some(paths::MAP_AREA_D),
        "E" => Some(paths::MAP_AREA_E),
        "F" => Some(paths::MAP_AREA_F),
        _ => None,
    }
}
