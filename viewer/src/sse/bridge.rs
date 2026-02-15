use bevy::prelude::*;

use super::client::SseReceiver;
use crate::game::events::*;
use crate::game::state::ConnectionStatus;

/// Each frame, drain the SSE message buffer and emit typed Bevy events.
pub fn poll_sse_events(
    receiver: Option<Res<SseReceiver>>,
    mut dice_events: MessageWriter<DiceRolled>,
    mut hp_events: MessageWriter<HpChanged>,
    mut narrative_events: MessageWriter<NarrativeReceived>,
    mut area_events: MessageWriter<AreaMoved>,
    mut turn_events: MessageWriter<TurnAdvanced>,
    mut choice_events: MessageWriter<ChoiceAvailable>,
    mut choice_resolved_events: MessageWriter<ChoiceResolved>,
    mut item_events: MessageWriter<ItemAcquired>,
    mut death_events: MessageWriter<CharacterDied>,
    mut combat_events: MessageWriter<CombatStarted>,
    mut connection: ResMut<ConnectionStatus>,
) {
    let Some(receiver) = receiver else { return };

    let mut msgs = match receiver.messages.lock() {
        Ok(guard) => guard,
        Err(_) => return,
    };

    if !msgs.is_empty() {
        // We received data, so we're connected
        *connection = ConnectionStatus::Connected;
    }

    for (event_type, data) in msgs.drain(..) {
        match event_type.as_str() {
            "dice_roll" => {
                match serde_json::from_str::<DiceRollPayload>(&data) {
                    Ok(payload) => { dice_events.write(DiceRolled(payload)); }
                    Err(e) => log::warn!("Failed to parse dice_roll: {}", e),
                }
            }
            "hp_change" => {
                match serde_json::from_str::<HpChangePayload>(&data) {
                    Ok(payload) => { hp_events.write(HpChanged(payload)); }
                    Err(e) => log::warn!("Failed to parse hp_change: {}", e),
                }
            }
            "narrative" => {
                match serde_json::from_str::<NarrativePayload>(&data) {
                    Ok(payload) => { narrative_events.write(NarrativeReceived(payload)); }
                    Err(e) => log::warn!("Failed to parse narrative: {}", e),
                }
            }
            "area_move" => {
                match serde_json::from_str::<AreaMovePayload>(&data) {
                    Ok(payload) => { area_events.write(AreaMoved(payload)); }
                    Err(e) => log::warn!("Failed to parse area_move: {}", e),
                }
            }
            "turn_advance" => {
                match serde_json::from_str::<TurnAdvancePayload>(&data) {
                    Ok(payload) => { turn_events.write(TurnAdvanced(payload)); }
                    Err(e) => log::warn!("Failed to parse turn_advance: {}", e),
                }
            }
            "choice_available" => {
                match serde_json::from_str::<ChoicePayload>(&data) {
                    Ok(payload) => { choice_events.write(ChoiceAvailable(payload)); }
                    Err(e) => log::warn!("Failed to parse choice_available: {}", e),
                }
            }
            "choice_resolved" => {
                match serde_json::from_str::<ChoicePayload>(&data) {
                    Ok(payload) => { choice_resolved_events.write(ChoiceResolved(payload)); }
                    Err(e) => log::warn!("Failed to parse choice_resolved: {}", e),
                }
            }
            "item_acquired" => {
                match serde_json::from_str::<ItemPayload>(&data) {
                    Ok(payload) => { item_events.write(ItemAcquired(payload)); }
                    Err(e) => log::warn!("Failed to parse item_acquired: {}", e),
                }
            }
            "character_death" => {
                match serde_json::from_str::<DeathPayload>(&data) {
                    Ok(payload) => { death_events.write(CharacterDied(payload)); }
                    Err(e) => log::warn!("Failed to parse character_death: {}", e),
                }
            }
            "combat_start" => {
                match serde_json::from_str::<CombatPayload>(&data) {
                    Ok(payload) => { combat_events.write(CombatStarted(payload)); }
                    Err(e) => log::warn!("Failed to parse combat_start: {}", e),
                }
            }
            other => {
                log::debug!("Unhandled SSE event type: {}", other);
            }
        }
    }
}
