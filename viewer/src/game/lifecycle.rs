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

pub fn normalize_status(raw: &str) -> String {
    let normalized = raw.trim().to_ascii_lowercase();
    if normalized.is_empty() {
        "unknown".to_string()
    } else {
        normalized
    }
}

impl TrpgLifecycleState {
    #[allow(dead_code)]
    pub fn from_status(raw: &str) -> Self {
        let status = normalize_status(raw);
        match status.as_str() {
            "active"
            | "running"
            | "in_progress"
            | "round"
            | "combat"
            | "briefing"
            | "dm_narration"
            | "party_discussion"
            | "action_declaration"
            | "dice_resolution"
            | "outcome_narration"
            | "state_update"
            | "transition" => Self::Running,
            "paused" | "stopped" | "suspended" | "halted" => Self::Stopped,
            "ended" | "completed" | "done" | "retired" | "closed" | "archived" => Self::Ended,
            "loading" | "bootstrapping" | "syncing" => Self::Loading,
            "unavailable" | "error" | "failed" => Self::Unavailable,
            "idle" | "lobby" | "created" | "ready" => Self::Lobby,
            "unknown" => Self::Unknown,
            _ => Self::Unknown,
        }
    }

    #[allow(dead_code)]
    pub fn from_room_progress(room_status: &str, progress_status: &str) -> Self {
        let source = if progress_status.trim().is_empty() {
            room_status
        } else {
            progress_status
        };
        Self::from_status(source)
    }

    #[allow(dead_code)]
    pub fn lane(self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::Stopped => "stopped",
            Self::Ended => "ended",
            Self::Unavailable => "unavailable",
            Self::Lobby | Self::Loading | Self::Unknown => "lobby",
        }
    }

    #[allow(dead_code)]
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

    #[allow(dead_code)]
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

    #[allow(dead_code)]
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

    #[allow(dead_code)]
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

    #[allow(dead_code)]
    pub fn allows_round_control(self) -> bool {
        matches!(self, Self::Running | Self::Stopped)
    }

    #[allow(dead_code)]
    pub fn accepts_player_input(self) -> bool {
        matches!(self, Self::Running)
    }
}
