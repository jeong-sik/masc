#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrpgLifecycleState {
    Lobby,
    Loading,
    Running,
    Stopped,
    Ended,
    Unavailable,
    Unknown,
}

#[cfg(any(target_arch = "wasm32", test))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrpgUiState {
    Lobby,
    ConfigReady,
    SessionStarting,
    SessionRunning,
    RoundRunning,
    Paused,
    Ended,
    Error,
}

pub fn normalize_status(raw: &str) -> String {
    let normalized = raw.trim().to_ascii_lowercase();
    if normalized.is_empty() {
        "unknown".to_string()
    } else {
        normalized
    }
}

impl TrpgLifecycleState {
    pub fn from_status(raw: &str) -> Self {
        let status = normalize_status(raw);
        match status.as_str() {
            "active" | "running" | "in_progress" | "round" | "combat" | "briefing"
            | "dm_narration" | "party_discussion" | "action_declaration" | "dice_resolution"
            | "outcome_narration" | "state_update" | "transition" => Self::Running,
            "paused" | "stopped" | "suspended" | "halted" => Self::Stopped,
            "ended" | "completed" | "done" | "retired" | "closed" | "archived" => Self::Ended,
            "loading" | "bootstrapping" | "syncing" => Self::Loading,
            "unavailable" | "error" | "failed" => Self::Unavailable,
            "idle" | "lobby" | "created" | "ready" => Self::Lobby,
            "unknown" => Self::Unknown,
            _ => Self::Unknown,
        }
    }

    pub fn from_room_progress(room_status: &str, progress_status: &str) -> Self {
        let source = if progress_status.trim().is_empty() {
            room_status
        } else {
            progress_status
        };
        Self::from_status(source)
    }

    #[cfg(target_arch = "wasm32")]
    pub fn lane(self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::Stopped => "stopped",
            Self::Ended => "ended",
            Self::Unavailable => "unavailable",
            Self::Lobby | Self::Loading | Self::Unknown => "lobby",
        }
    }

    #[cfg(target_arch = "wasm32")]
    pub fn css_class(self) -> &'static str {
        match self {
            Self::Lobby => "state-lobby",
            Self::Loading => "state-loading",
            Self::Running => "state-running",
            Self::Stopped => "state-stopped",
            Self::Ended => "state-ended",
            Self::Unavailable => "state-unavailable",
            Self::Unknown => "state-unknown",
        }
    }

    #[cfg(target_arch = "wasm32")]
    pub fn label(self) -> &'static str {
        match self {
            Self::Lobby => "LOBBY",
            Self::Loading => "LOADING",
            Self::Running => "RUNNING",
            Self::Stopped => "STOPPED",
            Self::Ended => "ENDED",
            Self::Unavailable => "UNAVAILABLE",
            Self::Unknown => "UNKNOWN",
        }
    }

    pub fn label_ko(self) -> &'static str {
        match self {
            Self::Lobby => "로비",
            Self::Loading => "로딩",
            Self::Running => "진행 중",
            Self::Stopped => "멈춤",
            Self::Ended => "종료",
            Self::Unavailable => "연결 오류",
            Self::Unknown => "상태 불명",
        }
    }

    #[cfg(any(target_arch = "wasm32", test))]
    pub fn help_text(self) -> &'static str {
        match self {
            Self::Lobby => "세션 미시작 또는 초기 대기 상태",
            Self::Loading => "상태 동기화/초기화 진행 중",
            Self::Running => "라운드가 순환 중이며 입력/결과가 반영되는 상태",
            Self::Stopped => "의도적으로 멈춘 상태(재개 가능)",
            Self::Ended => "세션 종료 상태(새 게임 필요)",
            Self::Unavailable => "엔진/키퍼/네트워크 오류로 진행 불가",
            Self::Unknown => "분류되지 않은 상태 값",
        }
    }

    #[cfg(any(target_arch = "wasm32", test))]
    pub fn allows_round_control(self) -> bool {
        matches!(self, Self::Running | Self::Stopped)
    }

    pub fn accepts_player_input(self) -> bool {
        matches!(self, Self::Running)
    }
}

#[cfg(any(target_arch = "wasm32", test))]
impl TrpgUiState {
    pub fn code(self) -> &'static str {
        match self {
            Self::Lobby => "lobby",
            Self::ConfigReady => "config_ready",
            Self::SessionStarting => "session_starting",
            Self::SessionRunning => "session_running",
            Self::RoundRunning => "round_running",
            Self::Paused => "paused",
            Self::Ended => "ended",
            Self::Error => "error",
        }
    }

    pub fn from_code(raw: &str) -> Self {
        match raw.trim().to_ascii_lowercase().as_str() {
            "config_ready" => Self::ConfigReady,
            "session_starting" => Self::SessionStarting,
            "session_running" => Self::SessionRunning,
            "round_running" => Self::RoundRunning,
            "paused" => Self::Paused,
            "ended" => Self::Ended,
            "error" => Self::Error,
            _ => Self::Lobby,
        }
    }

    pub fn label_ko(self) -> &'static str {
        match self {
            Self::Lobby => "로비",
            Self::ConfigReady => "설정 완료",
            Self::SessionStarting => "세션 시작 중",
            Self::SessionRunning => "세션 진행 중",
            Self::RoundRunning => "라운드 실행 중",
            Self::Paused => "일시정지",
            Self::Ended => "종료",
            Self::Error => "오류",
        }
    }

    pub fn help_text(self) -> &'static str {
        match self {
            Self::Lobby => "새 세션 시작 전 대기 상태",
            Self::ConfigReady => "사전 점검과 keeper 할당이 완료되어 시작 가능한 상태",
            Self::SessionStarting => "세션 생성/부트스트랩이 진행 중인 상태",
            Self::SessionRunning => "세션이 실행 중이며 라운드 실행 가능 상태",
            Self::RoundRunning => "라운드 요청이 실행 중인 상태",
            Self::Paused => "세션이 멈춰 있으며 재개 또는 종료 판단 필요",
            Self::Ended => "세션이 종료된 상태",
            Self::Error => "연결 또는 실행 오류로 진행할 수 없는 상태",
        }
    }

    pub fn ops_class(self) -> &'static str {
        match self {
            Self::ConfigReady | Self::SessionRunning => "status-active",
            Self::SessionStarting | Self::RoundRunning => "status-info",
            Self::Paused => "status-warn",
            Self::Ended | Self::Lobby => "status-idle",
            Self::Error => "status-error",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::TrpgUiState;

    #[test]
    fn trpg_ui_state_code_roundtrip() {
        let cases = [
            TrpgUiState::Lobby,
            TrpgUiState::ConfigReady,
            TrpgUiState::SessionStarting,
            TrpgUiState::SessionRunning,
            TrpgUiState::RoundRunning,
            TrpgUiState::Paused,
            TrpgUiState::Ended,
            TrpgUiState::Error,
        ];

        for state in cases {
            assert_eq!(TrpgUiState::from_code(state.code()), state);
        }
        assert_eq!(TrpgUiState::from_code("unknown-state"), TrpgUiState::Lobby);
    }

    #[test]
    fn trpg_ui_state_labels_and_classes_are_defined() {
        let cases = [
            TrpgUiState::Lobby,
            TrpgUiState::ConfigReady,
            TrpgUiState::SessionStarting,
            TrpgUiState::SessionRunning,
            TrpgUiState::RoundRunning,
            TrpgUiState::Paused,
            TrpgUiState::Ended,
            TrpgUiState::Error,
        ];

        for state in cases {
            assert!(!state.label_ko().trim().is_empty());
            assert!(!state.help_text().trim().is_empty());
            assert!(!state.ops_class().trim().is_empty());
        }
    }
}
