(** Dashboard TRPG (Dark Fantasy Narrative) JavaScript — extracted from web_dashboard.ml *)

let content = {|    // === TRPG — Dark Fantasy Narrative ===
    const TRPG_DEFAULT_ROOM_ID = 'default';
    const TRPG_DEFAULT_POOL_SIZE = 8;
    const TRPG_DEFAULT_PARTY_SIZE = 4;
    const TRPG_DEFAULT_KEEPER_MODELS = 'glm:glm-4.7,gemini:gemini-2.5-flash,ollama:glm-4.7-flash';
    let trpgRoomId = trpgRoomParam || TRPG_DEFAULT_ROOM_ID;
    const TRPG_DEFAULT_PLAYER_KEEPERS = [
      'grimja=grimja',
      'luna=luna',
      'songarak=songarak',
      'miso=miso',
    ];
    const TRPG_PARTY_FALLBACK = [
      { name: '그림자', cls: '전사', hp: 30, maxHp: 30, emoji: '⚔', area: 'C' },
      { name: '루나', cls: '마법사', hp: 13, maxHp: 15, emoji: '🔮', area: 'F' },
      { name: '손가락', cls: '도적', hp: 15, maxHp: 18, emoji: '🗡', area: 'C' },
      { name: '미소', cls: '성직자', hp: 14, maxHp: 20, emoji: '✝', area: 'C' },
    ];
    const TRPG_MAP_FALLBACK = [
      '          [D 북쪽덤불]         ← 고블린 5마리',
      '            ║',
      ' [A 절벽]══[B 중앙]══[C 동쪽]  ← 그림자+손가락+미소',
      '            ║',
      '          [E 남쪽덤불]         ← 고블린 4마리',
      '            ║',
      '          [F 대장나무]         ← ★루나 + 대장 고블린',
    ].join('\n');
    const trpgKnownIds = new Set();
    let trpgTyping = false;
    let trpgLastSeq = 0;
    let trpgEventsCache = [];
    let trpgStateCache = {};
    let trpgRoundRunning = false;
    let trpgBootstrapping = false;
    let trpgActorMutating = false;
    let trpgAutoRoundEnabled = false;
    let trpgAutoRoundTimer = null;
    let trpgNextActionKind = 'bootstrap';
    let trpgCanRunRound = false;
    let trpgRunBlockedReason = '먼저 1) 세션 시작을 실행하세요.';
    let trpgPresetsLoaded = false;
    let trpgKeepersLoaded = false;
    let trpgKeeperSelectorsKey = '';
    let trpgIncludePastSessions = false;
    let trpgHistoryExpanded = false;
    let trpgMcpCallSeq = 1000;
    let trpgMcpSessionId = null;
    let trpgPresetCatalog = { dm_presets: [], world_presets: [] };
    let trpgKeeperCatalog = [];
    let trpgKeeperCatalogDetails = {};
    let trpgActorBrowserCache = {};
    const TRPG_AUTO_ROUND_DELAY_DEFAULT_SEC = 3;

    function trpgEventType(ev) {
      return (ev && (ev.type || ev.event_type || ev.event)) || '';
    }

    function trpgEventPayload(ev) {
      return (ev && ev.payload && typeof ev.payload === 'object' && !Array.isArray(ev.payload))
        ? ev.payload
        : {};
    }

    function trpgLatestPhase(events) {
      for (let i = events.length - 1; i >= 0; i--) {
        const ev = events[i];
        if (trpgEventType(ev) === 'phase.changed') {
          const p = trpgEventPayload(ev).phase;
          if (typeof p === 'string' && p.trim() !== '') return p.trim();
        }
      }
      return '-';
    }

    function trpgLatestRound(state, events) {
      const turn = Number(state && state.turn);
      if (Number.isFinite(turn) && turn > 1) return Math.max(1, Math.floor(turn - 1));
      let maxTurn = 0;
      events.forEach((ev) => {
        const t = Number(trpgEventPayload(ev).turn);
        if (Number.isFinite(t) && t > maxTurn) maxTurn = t;
      });
      return maxTurn > 0 ? maxTurn : 1;
    }

    function trpgRoundSummary(events, round) {
      const summary = {
        round,
        narrations: 0,
        proposed: 0,
        timeouts: 0,
        unavailable: 0,
      };
      events.forEach((ev) => {
        const payload = trpgEventPayload(ev);
        const t = Number(payload.turn);
        if (!Number.isFinite(t) || t !== round) return;
        const type = trpgEventType(ev);
        if (type === 'narration.posted') summary.narrations += 1;
        else if (type === 'turn.action.proposed') summary.proposed += 1;
        else if (type === 'turn.timeout') summary.timeouts += 1;
        else if (type === 'keeper.unavailable') summary.unavailable += 1;
      });
      return summary;
    }

    function trpgLatestSessionStartSeq(events) {
      let startSeq = 0;
      (Array.isArray(events) ? events : []).forEach((ev) => {
        if (trpgEventType(ev) !== 'session.started') return;
        const seq = Number(ev && ev.seq);
        if (Number.isFinite(seq) && seq > startSeq) startSeq = seq;
      });
      return startSeq;
    }

    function trpgCurrentSessionEvents(events) {
      const xs = Array.isArray(events) ? events : [];
      if (trpgIncludePastSessions) return xs;
      const startSeq = trpgLatestSessionStartSeq(xs);
      if (startSeq <= 0) return xs;
      return xs.filter((ev) => {
        const seq = Number(ev && ev.seq);
        return Number.isFinite(seq) ? seq >= startSeq : true;
      });
    }

    function trpgToggleSessionView(checked) {
      trpgIncludePastSessions = !!checked;
      renderTrpgNarrative(trpgEventsCache);
      renderTrpgState(trpgStateCache, trpgEventsCache);
      const mode = trpgIncludePastSessions ? '전체 세션 로그 표시' : '현재 세션 로그만 표시';
      showToast(mode, 'success');
    }

    function trpgActionButtonId(kind) {
      const key = String(kind || '');
      if (key === 'bootstrap') return 'trpg-bootstrap-btn';
      if (key === 'run_round') return 'trpg-run-round-btn';
      return '';
    }

    function setTrpgPhaseSelection(phase) {
      const next = String(phase || '').trim();
      if (!next) return;
      const phaseSelect = document.getElementById('trpg-phase-select');
      if (!phaseSelect) return;
      const hasOption = Array.from(phaseSelect.options || []).some((opt) => String(opt.value || '') === next);
      if (hasOption) phaseSelect.value = next;
    }

    function runTrpgPhaseQuick(phase, label = '') {
      if (trpgRoundRunning || trpgBootstrapping || trpgActorMutating) return;
      const next = String(phase || '').trim();
      if (!next) return;
      setTrpgPhaseSelection(next);
      const pretty = String(label || next).trim();
      showToast(`Phase quick run: ${pretty}`, 'info');
      runTrpgRound({ source: `quick:${next}`, phase: next });
    }

    function trpgNextActionRunLabel(kind) {
      const key = String(kind || '');
      if (key === 'bootstrap') return '권장 액션 실행: 1) 세션 시작';
      if (key === 'run_round') return '권장 액션 실행: 2) 라운드 실행';
      return '권장 액션 없음';
    }

    function updateTrpgNextActionButton() {
      const btn = document.getElementById('trpg-next-action-btn');
      const note = document.getElementById('trpg-next-action-note');
      if (!btn) return;
      const isRunnable = trpgNextActionKind === 'bootstrap' || trpgNextActionKind === 'run_round';
      const disabled = trpgRoundRunning || trpgBootstrapping || trpgActorMutating || !isRunnable;
      const reason = trpgRoundRunning
        ? '현재 라운드 실행 중입니다.'
        : (trpgBootstrapping
            ? '세션 시작 작업이 진행 중입니다.'
            : (trpgActorMutating
                ? '액터 생성/수정/삭제가 진행 중입니다.'
                : String(trpgRunBlockedReason || '현재 권장 액션이 실행 가능한 상태가 아닙니다.')));
      btn.textContent = trpgNextActionRunLabel(trpgNextActionKind);
      btn.disabled = disabled;
      btn.title = disabled ? reason : '현재 추천된 다음 단계를 즉시 실행합니다.';
      if (note) {
        note.textContent = disabled ? reason : '버튼을 누르면 현재 추천 단계가 바로 실행됩니다.';
      }
    }

    function runTrpgNextAction() {
      if (trpgRoundRunning || trpgBootstrapping || trpgActorMutating) {
        showToast('현재 실행 중인 작업이 있어 대기 중입니다.', 'error');
        return;
      }
      if (trpgNextActionKind === 'bootstrap') {
        bootstrapTrpgSession();
        return;
      }
      if (trpgNextActionKind === 'run_round') {
        runTrpgRound();
        return;
      }
      const reason = String(trpgRunBlockedReason || '현재 실행 가능한 권장 액션이 없습니다.');
      showToast(reason, 'error');
    }

    function trpgSetActionRowHighlight(buttonId, enabled = true) {
      ['trpg-bootstrap-btn', 'trpg-run-round-btn', 'trpg-auto-round-btn', 'trpg-new-game-btn', 'trpg-reload-btn'].forEach((id) => {
        const el = document.getElementById(id);
        if (!el) return;
        el.classList.remove('recommend');
      });
      if (!buttonId || !enabled) return;
      const activeEl = document.getElementById(buttonId);
      if (activeEl) activeEl.classList.add('recommend');
    }

    function trpgSetNextAction(kind, label, desc, enabled = true) {
      trpgNextActionKind = String(kind || 'none');
      trpgCanRunRound = trpgNextActionKind === 'run_round' && !!enabled;
      trpgRunBlockedReason = trpgCanRunRound ? '' : String(desc || '실행 전 점검이 필요합니다.');
      const descEl = document.getElementById('trpg-next-action-desc');
      const targetEl = document.getElementById('trpg-next-action-target');
      const targetBtnId = trpgActionButtonId(trpgNextActionKind);
      if (descEl) descEl.textContent = String(desc || '');
      if (targetEl) {
        if (targetBtnId && enabled) {
          targetEl.textContent = `권장 클릭: ${String(label || '메인 버튼')} (상단 버튼)`;
        } else if (targetBtnId && !enabled) {
          targetEl.textContent = `권장 클릭: ${String(label || '메인 버튼')} (현재 실행 불가)`;
        } else {
          targetEl.textContent = '자동 대기: 상태 변화 감지 중';
        }
      }
      trpgSetActionRowHighlight(targetBtnId, !!enabled);
      updateTrpgButtons();
      updateTrpgNextActionButton();
    }

    function trpgUpdateNextAction(state, events) {
      const viewEvents = trpgCurrentSessionEvents(events);
      if (trpgBootstrapping) {
        trpgSetNextAction('wait', '1) 세션 시작', '세션 상태: 시작 중 · 세션 구성 완료까지 잠시만 기다리세요.', false);
        return;
      }
      if (trpgRoundRunning) {
        trpgSetNextAction('wait', '2) 라운드 실행', '세션 상태: 진행 중 · 현재 라운드 실행이 끝나면 자동 갱신됩니다.', false);
        return;
      }
      const sessions = trpgBuildSessionHistory(viewEvents);
      if (sessions.length === 0) {
        trpgSetNextAction('bootstrap', '1) 세션 시작', '세션 상태: 미시작 · world/dm preset 확인 후 세션을 시작하세요.', true);
        return;
      }
      const expectedActors = trpgPartyActorsFromStateOrEvents(state, viewEvents);
      if (expectedActors.length === 0) {
        trpgSetNextAction('wait', '1) 세션 시작', '세션 상태: 시작됨(불완전) · 파티 actor_id를 아직 확인하지 못했습니다. 1) 세션 시작을 다시 실행하세요.', false);
        return;
      }
      const resolved = trpgResolvePlayerKeeperMapping(
        state,
        viewEvents,
        String((document.getElementById('trpg-player-keepers-input') || {}).value || '')
      );
      if (!resolved.ok) {
        trpgSetNextAction('wait', '입력 수정 필요', '세션 상태: 확인 필요 · Player keepers 입력 형식 오류를 먼저 해결하세요.', false);
        return;
      }
      const missingActors = resolved.missingActors || [];
      const unknownActors = resolved.unknownActors || [];
      if (missingActors.length > 0) {
        trpgSetNextAction(
          'wait',
          '할당 수정 필요',
          `세션 상태: 확인 필요 · 파티 actor_id 일부 누락 (${missingActors.join(', ')})`,
          false
        );
        return;
      }
      if (unknownActors.length > 0) {
        trpgSetNextAction(
          'run_round',
          '2) 라운드 실행',
          `세션 상태: 실행 준비 완료 · 파티 외 actor 입력 ${unknownActors.length}개는 무시됩니다.`,
          true
        );
        return;
      }

      if ((resolved.renamed || []).length > 0) {
        const input = document.getElementById('trpg-player-keepers-input');
        if (input) {
          input.value = playerKeeperMapToText(resolved.mapping || {});
          trpgSyncKeeperSelectorsFromInputs();
        }
      }
      trpgSetNextAction('run_round', '2) 라운드 실행', '세션 상태: 준비 완료 · 2) 라운드 실행으로 서사를 진행하세요.', true);
    }

    function trpgFmtDateTime(ts) {
      if (!ts) return '-';
      const d = new Date(ts);
      if (Number.isNaN(d.getTime())) return String(ts);
      return d.toLocaleString('ko-KR', { hour12: false });
    }

    function trpgParseTs(ts) {
      if (!ts) return null;
      const ms = Date.parse(String(ts));
      return Number.isFinite(ms) ? ms : null;
    }

    function trpgFmtDurationMs(ms) {
      if (!Number.isFinite(ms) || ms <= 0) return '-';
      const totalSec = Math.floor(ms / 1000);
      const h = Math.floor(totalSec / 3600);
      const m = Math.floor((totalSec % 3600) / 60);
      const s = totalSec % 60;
      if (h > 0) return `${h}h ${m}m ${s}s`;
      if (m > 0) return `${m}m ${s}s`;
      return `${s}s`;
    }

    function trpgSessionModeLabel(history, summary, phase) {
      if (!Array.isArray(history) || history.length === 0) {
        return { label: 'LOBBY', cls: '' };
      }
      if (trpgBootstrapping) {
        return { label: 'BOOTSTRAP', cls: 'running' };
      }
      if (trpgRoundRunning) {
        return { label: 'RUNNING', cls: 'running' };
      }
      if (String(phase || '') === 'ended') {
        return { label: 'ENDED', cls: 'warn' };
      }
      const round = Number(summary && summary.round);
      if (Number.isFinite(round) && round > 0) {
        return { label: 'ACTIVE', cls: 'ok' };
      }
      if (trpgCanRunRound) {
        return { label: 'READY', cls: 'ok' };
      }
      return { label: 'SETUP', cls: 'error' };
    }

    function trpgUniqueStrings(xs) {
      const seen = new Set();
      const out = [];
      (Array.isArray(xs) ? xs : []).forEach((x) => {
        const v = String(x || '').trim();
        if (!v || seen.has(v)) return;
        seen.add(v);
        out.push(v);
      });
      return out;
    }

    function trpgPartyActorsFromStateOrEvents(state, events) {
      const partyObj =
        state && state.party && typeof state.party === 'object' && !Array.isArray(state.party)
          ? state.party
          : null;
      if (partyObj) {
        const actors = trpgUniqueStrings(Object.keys(partyObj));
        if (actors.length > 0) return actors;
      }
      for (let i = (events || []).length - 1; i >= 0; i -= 1) {
        const ev = events[i];
        if (trpgEventType(ev) !== 'party.selected') continue;
        const payload = trpgEventPayload(ev);
        const party = Array.isArray(payload.party) ? payload.party : [];
        const actors = trpgUniqueStrings(
          party.map((row) => (row && typeof row === 'object' && !Array.isArray(row) ? row.actor_id : ''))
        );
        if (actors.length > 0) return actors;
      }
      return [];
    }

    function trpgPartyActorAliasMap(state, events) {
      const aliases = {};
      const put = (aliasRaw, actorRaw) => {
        const alias = String(aliasRaw || '').trim().toLowerCase();
        const actorId = String(actorRaw || '').trim();
        if (!alias || !actorId) return;
        if (!Object.prototype.hasOwnProperty.call(aliases, alias)) {
          aliases[alias] = actorId;
        }
      };

      const partyObj =
        state && state.party && typeof state.party === 'object' && !Array.isArray(state.party)
          ? state.party
          : null;
      if (partyObj) {
        Object.entries(partyObj).forEach(([actorId, infoRaw]) => {
          const actor = String(actorId || '').trim();
          if (!actor) return;
          const info = (infoRaw && typeof infoRaw === 'object' && !Array.isArray(infoRaw)) ? infoRaw : {};
          put(actor, actor);
          put(info.actor_id, actor);
          put(info.name, actor);
        });
      } else {
        for (let i = (events || []).length - 1; i >= 0; i -= 1) {
          const ev = events[i];
          if (trpgEventType(ev) !== 'party.selected') continue;
          const payload = trpgEventPayload(ev);
          const party = Array.isArray(payload.party) ? payload.party : [];
          party.forEach((member) => {
            const actor = String((member && member.actor_id) || '').trim();
            if (!actor) return;
            put(actor, actor);
            put((member && member.name) || '', actor);
          });
          break;
        }
      }
      return aliases;
    }

    function trpgActorsFromStateOrEvents(state, events) {
      const actors = [];
      const seen = new Set();
      const inputRaw = String((document.getElementById('trpg-player-keepers-input') || {}).value || '');
      const parsed = parseTrpgPlayerKeepers(inputRaw);
      const keeperMap = parsed.ok ? (parsed.mapping || {}) : {};

      const pushActor = (actorIdRaw, infoRaw = {}) => {
        const actorId = String(actorIdRaw || '').trim();
        if (!actorId || seen.has(actorId)) return;
        seen.add(actorId);
        const info = (infoRaw && typeof infoRaw === 'object' && !Array.isArray(infoRaw)) ? infoRaw : {};
        const hpRaw = Number(info.hp);
        const maxHpRaw = Number(info.max_hp ?? info.maxHp);
        const hp = Number.isFinite(hpRaw) ? hpRaw : null;
        const maxHp = Number.isFinite(maxHpRaw) && maxHpRaw > 0 ? maxHpRaw : null;
        const alive = typeof info.alive === 'boolean'
          ? info.alive
          : (Number.isFinite(hp) ? hp > 0 : true);
        const traits = Array.isArray(info.traits) ? info.traits : [];
        const skills = Array.isArray(info.skills) ? info.skills : [];
        const inventory = Array.isArray(info.inventory) ? info.inventory : [];
        actors.push({
          actorId,
          name: String(info.name || actorId).trim() || actorId,
          role: String(info.role || info.class || info.job || '').trim(),
          archetype: String(info.archetype || '').trim(),
          persona: String(info.persona || '').trim(),
          keeper: String(info.keeper || info.keeper_name || info.keeperName || info.claimed_by || keeperMap[actorId] || '').trim(),
          hp,
          maxHp,
          alive,
          traits,
          skills,
          inventory,
        });
      };

      const partyObj =
        state && state.party && typeof state.party === 'object' && !Array.isArray(state.party)
          ? state.party
          : null;
      if (partyObj) {
        Object.entries(partyObj).forEach(([actorId, info]) => pushActor(actorId, info));
      } else {
        for (let i = (events || []).length - 1; i >= 0; i -= 1) {
          const ev = events[i];
          if (trpgEventType(ev) !== 'party.selected') continue;
          const payload = trpgEventPayload(ev);
          const party = Array.isArray(payload.party) ? payload.party : [];
          party.forEach((member) => {
            const actorId = String((member && member.actor_id) || '').trim();
            pushActor(actorId, member);
          });
          break;
        }
      }

      actors.sort((a, b) => a.actorId.localeCompare(b.actorId, 'en'));
      return actors;
    }

    function trpgResolvePlayerKeeperMapping(state, events, rawText) {
      const parsed = parseTrpgPlayerKeepers(rawText);
      if (!parsed.ok) {
        return {
          ok: false,
          error: parsed.error || 'invalid player keeper mapping',
          mapping: {},
          expectedActors: [],
          unknownActors: [],
          missingActors: [],
          renamed: [],
        };
      }

      const expectedActors = trpgPartyActorsFromStateOrEvents(state, events);
      if (expectedActors.length === 0) {
        return {
          ok: true,
          mapping: parsed.mapping,
          expectedActors: [],
          unknownActors: [],
          missingActors: [],
          renamed: [],
        };
      }

      const expectedSet = new Set(expectedActors);
      const aliasMap = trpgPartyActorAliasMap(state, events);
      const mapping = {};
      const unknownActors = [];
      const renamed = [];
      const seenCanonicalActors = new Set();
      const duplicatedActors = new Set();

      Object.entries(parsed.mapping || {}).forEach(([rawActor, keeperNameRaw]) => {
        const originalActor = String(rawActor || '').trim();
        const keeperName = String(keeperNameRaw || '').trim();
        if (!originalActor || !keeperName) return;

        let actorId = originalActor;
        if (!expectedSet.has(actorId)) {
          const aliasKey = originalActor.toLowerCase();
          if (Object.prototype.hasOwnProperty.call(aliasMap, aliasKey)) {
            actorId = aliasMap[aliasKey];
          }
        }

        if (!expectedSet.has(actorId)) {
          unknownActors.push(originalActor);
          return;
        }
        if (seenCanonicalActors.has(actorId) || Object.prototype.hasOwnProperty.call(mapping, actorId)) {
          duplicatedActors.add(actorId);
          return;
        }

        seenCanonicalActors.add(actorId);
        mapping[actorId] = keeperName;
        if (originalActor !== actorId) {
          renamed.push([originalActor, actorId]);
        }
      });

      const missingActors = expectedActors.filter(
        (actorId) => !Object.prototype.hasOwnProperty.call(mapping, actorId)
      );
      return {
        ok: true,
        mapping,
        expectedActors,
        unknownActors: trpgUniqueStrings(unknownActors),
        missingActors,
        renamed,
        duplicatedActors: Array.from(duplicatedActors.values()),
      };
    }

    function trpgBuildActorKeeperPairs(actorIds, dmKeeper, requestedMap, templateMap) {
      const actors = trpgUniqueStrings((Array.isArray(actorIds) ? actorIds : []).map((actorId) => String(actorId || '').trim()))
        .filter((actorId) => actorId !== '');
      const dm = String(dmKeeper || '').trim();
      const requested = (requestedMap && typeof requestedMap === 'object' && !Array.isArray(requestedMap))
        ? requestedMap
        : {};
      const template = (templateMap && typeof templateMap === 'object' && !Array.isArray(templateMap))
        ? templateMap
        : {};

      if (actors.length === 0) {
        return {
          ok: false,
          mapping: {},
          error: '세션 파티 actor_id가 비어 있어 할당할 수 없습니다.',
        };
      }

      const mapping = {};
      const usedKeepers = new Set();
      if (dm !== '') usedKeepers.add(dm);
      const unknownActors = [];

      Object.entries(requested).forEach(([actorIdRaw, keeperRaw]) => {
        const actorId = String(actorIdRaw || '').trim();
        const keeper = String(keeperRaw || '').trim();
        if (!actorId || !keeper) return;
        if (!actors.includes(actorId)) {
          unknownActors.push(actorId);
        }
      });

      for (const actorId of actors) {
        const requestedKeeper = String(requested[actorId] || '').trim();
        const templateKeeper = String(template[actorId] || '').trim();
        const keeper = requestedKeeper || templateKeeper;
        if (!keeper) {
          return {
            ok: false,
            mapping: {},
            error: `할당이 누락된 actor가 있습니다: ${actorId}`,
          };
        }
        if (keeper === dm) {
          return {
            ok: false,
            mapping: {},
            error: `DM keeper "${dm}"가 player keeper로 중복되었습니다. keeper는 DM과 겹칠 수 없습니다.`,
          };
        }
        if (usedKeepers.has(keeper)) {
          return {
            ok: false,
            mapping: {},
            error: `player keeper 중복: ${keeper}`,
          };
        }
        mapping[actorId] = keeper;
        usedKeepers.add(keeper);
      }

      if (unknownActors.length > 0) {
        return {
          ok: false,
          mapping: {},
          error: `현재 파티에 없는 actor가 지정되었습니다: ${trpgUniqueStrings(unknownActors).join(', ')}`,
        };
      }

      return { ok: true, mapping };
    }

    function trpgBuildSessionHistory(events) {
      const sorted = (Array.isArray(events) ? events.slice() : [])
        .sort((a, b) => (Number(a.seq) || 0) - (Number(b.seq) || 0));
      const sessions = [];
      let current = null;
      sorted.forEach((ev) => {
        const type = trpgEventType(ev);
        const payload = trpgEventPayload(ev);
        if (type === 'session.started') {
          if (current) sessions.push(current);
          const seq = Number(ev.seq) || 0;
          const sessionId =
            String(payload.session_id || '').trim() || `session@${seq}`;
          current = {
            sessionId,
            roomId: String(payload.room_id || '').trim(),
            startSeq: seq,
            endSeq: seq,
            startedAt: ev.ts || ev.timestamp || null,
            lastTs: ev.ts || ev.timestamp || null,
            endedAt: null,
            ended: false,
            eventCount: 0,
            maxTurn: 0,
            phase: '-',
          };
        }
        if (!current) return;
        current.eventCount += 1;
        current.endSeq = Number(ev.seq) || current.endSeq;
        current.lastTs = ev.ts || ev.timestamp || current.lastTs;
        const t = Number(payload.turn);
        if (Number.isFinite(t) && t > current.maxTurn) current.maxTurn = t;
        if (type === 'phase.changed') {
          const p = String(payload.phase || '').trim();
          if (p) current.phase = p;
        }
        if (type === 'session.ended') {
          current.ended = true;
          current.endedAt = ev.ts || ev.timestamp || current.lastTs;
        }
      });
      if (current) sessions.push(current);
      if (sessions.length === 0 && sorted.length > 0) {
        const first = sorted[0];
        const last = sorted[sorted.length - 1];
        let maxTurn = 0;
        sorted.forEach((ev) => {
          const t = Number(trpgEventPayload(ev).turn);
          if (Number.isFinite(t) && t > maxTurn) maxTurn = t;
        });
        sessions.push({
          sessionId: '(legacy)',
          roomId: '',
          startSeq: Number(first.seq) || 0,
          endSeq: Number(last.seq) || 0,
          startedAt: first.ts || first.timestamp || null,
          lastTs: last.ts || last.timestamp || null,
          endedAt: null,
          ended: false,
          eventCount: sorted.length,
          maxTurn,
          phase: trpgLatestPhase(sorted),
        });
      }
      return sessions
        .map((session) => {
          const startedMs = trpgParseTs(session.startedAt);
          const endMs = trpgParseTs(session.endedAt || session.lastTs);
          let durationMs = null;
          if (startedMs !== null && endMs !== null && endMs >= startedMs) {
            durationMs = endMs - startedMs;
          }
          return Object.assign({}, session, { durationMs });
        })
        .sort((a, b) => b.startSeq - a.startSeq)
        .slice(0, 8);
    }

    function trpgFmtEventTime(ev) {
      const ts = ev && (ev.ts || ev.timestamp);
      if (!ts) return '-';
      const d = new Date(ts);
      if (Number.isNaN(d.getTime())) return String(ts);
      return d.toLocaleTimeString('ko-KR');
    }

    function setTrpgRoomQueryState() {
      const url = new URL(window.location.href);
      if (trpgRoomId && trpgRoomId !== TRPG_DEFAULT_ROOM_ID) {
        url.searchParams.set('trpg_room', trpgRoomId);
      } else {
        url.searchParams.delete('trpg_room');
      }
      history.replaceState(history.state || {}, '', url.pathname + url.search + url.hash);
    }

    function resetTrpgEventWindow() {
      trpgLastSeq = 0;
      trpgEventsCache = [];
      trpgStateCache = {};
      trpgKnownIds.clear();
    }

    function ensureTrpgControlDefaults() {
      const bindTrpgInput = (id, eventName = 'input') => {
        const el = document.getElementById(id);
        if (!el || el.dataset.trpgBound === '1') return;
        el.addEventListener(eventName, () => {
          trpgSyncKeeperSelectorsFromInputs();
          trpgUpdateNextAction(trpgStateCache, trpgEventsCache);
        });
        el.dataset.trpgBound = '1';
      };
      const roomInput = document.getElementById('trpg-room-input');
      if (roomInput && String(roomInput.value || '').trim() === '') roomInput.value = trpgRoomId;
      const poolInput = document.getElementById('trpg-pool-size-input');
      if (poolInput && String(poolInput.value || '').trim() === '') poolInput.value = String(TRPG_DEFAULT_POOL_SIZE);
      const partyInput = document.getElementById('trpg-party-size-input');
      if (partyInput && String(partyInput.value || '').trim() === '') partyInput.value = String(TRPG_DEFAULT_PARTY_SIZE);
      const modelsInput = document.getElementById('trpg-keeper-models-input');
      if (modelsInput && String(modelsInput.value || '').trim() === '') {
        modelsInput.value = TRPG_DEFAULT_KEEPER_MODELS;
      }
      const autoDelayInput = document.getElementById('trpg-auto-round-delay-sec-input');
      if (autoDelayInput && String(autoDelayInput.value || '').trim() === '') {
        autoDelayInput.value = String(TRPG_AUTO_ROUND_DELAY_DEFAULT_SEC);
      }
      if (autoDelayInput && autoDelayInput.dataset.trpgBound !== '1') {
        autoDelayInput.addEventListener('change', () => {
          if (trpgAutoRoundEnabled) {
            scheduleTrpgAutoRoundNext('delay-change');
          }
        });
        autoDelayInput.dataset.trpgBound = '1';
      }
      const langSelect = document.getElementById('trpg-lang-select');
      if (langSelect && String(langSelect.value || '').trim() === '') {
        langSelect.value = browserLang.startsWith('ko') ? 'ko' : 'auto';
      } else if (langSelect && String(langSelect.value || '').trim() === 'auto' && browserLang.startsWith('ko')) {
        langSelect.value = 'ko';
      }
      const showPastEl = document.getElementById('trpg-show-past-sessions');
      if (showPastEl) showPastEl.checked = trpgIncludePastSessions;
      const dmInput = document.getElementById('trpg-dm-keeper-input');
      if (dmInput && String(dmInput.value || '').trim() === '') {
        const preferredDm =
          (Array.isArray(trpgKeeperCatalog) ? trpgKeeperCatalog : []).find((name) => trpgIsDmLikeKeeper(name))
          || 'dm-keeper';
        dmInput.value = preferredDm;
      }
      const playerInput = document.getElementById('trpg-player-keepers-input');
      if (playerInput && String(playerInput.value || '').trim() === '') {
        if (Array.isArray(trpgKeeperCatalog) && trpgKeeperCatalog.length > 0) {
          const suggested = trpgSuggestedPlayerKeepers(trpgKeeperCatalog, TRPG_DEFAULT_PARTY_SIZE);
          playerInput.value = suggested.length > 0 ? suggested.join('\n') : TRPG_DEFAULT_PLAYER_KEEPERS.join('\n');
        } else {
          playerInput.value = TRPG_DEFAULT_PLAYER_KEEPERS.join('\n');
        }
      }
      bindTrpgInput('trpg-player-keepers-input', 'input');
      bindTrpgInput('trpg-dm-keeper-input', 'input');
      bindTrpgInput('trpg-party-size-input', 'input');
      trpgPopulateKeeperSelectors(false);
      syncTrpgAutoRoundUi();
    }

    function applyTrpgRoomFromInput() {
      const roomInput = document.getElementById('trpg-room-input');
      const nextRoom = String((roomInput && roomInput.value) || '').trim() || TRPG_DEFAULT_ROOM_ID;
      if (nextRoom !== trpgRoomId) {
        trpgRoomId = nextRoom;
        trpgHistoryExpanded = false;
        resetTrpgEventWindow();
        setTrpgRoomQueryState();
      }
      if (roomInput) roomInput.value = trpgRoomId;
      return trpgRoomId;
    }

    async function applyTrpgRoomInputAndRefresh() {
      const nextRoomId = applyTrpgRoomFromInput();
      showToast(`TRPG room: ${nextRoomId}`, 'success');
      await fetchTrpg();
    }

    function trpgPresetLabel(preset) {
      if (!preset || typeof preset !== 'object') return '-';
      const id = String(preset.id || '').trim();
      const title = String(preset.title || '').trim();
      if (title && id) return `${title} (${id})`;
      return title || id || '-';
    }

    function setTrpgPresetOptions(selectId, presets) {
      const select = document.getElementById(selectId);
      if (!select) return;
      const prev = String(select.value || '');
      const xs = Array.isArray(presets) ? presets : [];
      if (xs.length === 0) {
        select.innerHTML = '<option value="">(none)</option>';
        return;
      }
      select.innerHTML = xs.map((preset) => {
        const id = escapeHtml(String((preset && preset.id) || ''));
        const label = escapeHtml(trpgPresetLabel(preset));
        return `<option value="${id}">${label}</option>`;
      }).join('');
      if (prev && xs.some((preset) => String((preset && preset.id) || '') === prev)) {
        select.value = prev;
      }
    }

    function selectedTrpgPresetId(selectId) {
      const select = document.getElementById(selectId);
      if (!select) return '';
      return String(select.value || '').trim();
    }

    function parseKeeperModels(raw) {
      return String(raw || '')
        .split(',')
        .map((part) => part.trim())
        .filter((part) => part !== '');
    }

    function parseCommaTextList(raw) {
      return String(raw || '')
        .split(',')
        .map((part) => part.trim())
        .filter((part) => part !== '');
    }

    function trpgLanguageFromSelect() {
      const el = document.getElementById('trpg-lang-select');
      const raw = String((el && el.value) || 'auto').trim().toLowerCase();
      if (raw === 'ko' || raw === 'en') return raw;
      return browserLang.startsWith('ko') ? 'ko' : 'en';
    }

    function trpgKeeperEntryName(entry) {
      if (typeof entry === 'string') return String(entry || '').trim();
      if (entry && typeof entry === 'object' && !Array.isArray(entry)) {
        const candidates = [entry.name, entry.agent_name, entry.keeper, entry.id];
        for (const c of candidates) {
          const name = String(c || '').trim();
          if (name !== '') return name;
        }
      }
      return '';
    }

    function trpgNormalizeKeeperCatalog(raw) {
      if (!Array.isArray(raw)) return { names: [], details: {} };
      const seen = new Set();
      const names = [];
      const details = {};
      raw.forEach((entry) => {
        const name = trpgKeeperEntryName(entry);
        if (!name || seen.has(name)) return;
        seen.add(name);
        names.push(name);
        if (entry && typeof entry === 'object' && !Array.isArray(entry)) {
          details[name] = entry;
        }
      });
      return { names, details };
    }

    function trpgKeeperDetail(name) {
      if (!name) return null;
      const detail = trpgKeeperCatalogDetails && trpgKeeperCatalogDetails[name];
      return (detail && typeof detail === 'object') ? detail : null;
    }

    function trpgKeeperHealth(detail) {
      if (!detail || typeof detail !== 'object') {
        return { label: 'UNK', cls: 'health-stale', reason: '상태 정보 없음' };
      }
      const keepaliveRunning = detail.keepalive_running !== false;
      if (!keepaliveRunning) {
        return { label: 'OFF', cls: 'health-offline', reason: 'keepalive 비활성' };
      }
      const lastTurnAgo = Number(detail.last_turn_ago_s);
      if (Number.isFinite(lastTurnAgo)) {
        if (lastTurnAgo <= 120) return { label: 'LIVE', cls: 'health-live', reason: `최근 턴 ${Math.floor(lastTurnAgo)}s 전` };
        if (lastTurnAgo <= 900) return { label: 'WARM', cls: 'health-warm', reason: `최근 턴 ${Math.floor(lastTurnAgo)}s 전` };
        return { label: 'STALE', cls: 'health-stale', reason: `최근 턴 ${Math.floor(lastTurnAgo)}s 전` };
      }
      return { label: 'WARM', cls: 'health-warm', reason: '최근 턴 정보 없음' };
    }

    function trpgIsDmLikeKeeper(name) {
      const n = String(name || '').trim().toLowerCase();
      if (!n) return false;
      return (
        n === 'dm'
        || n.startsWith('dm-')
        || n.includes('-dm')
        || n.includes('dm_keeper')
        || n.includes('dm-keeper')
        || n.includes('trpg-dm')
        || n.startsWith('gm')
      );
    }

    function trpgSuggestedPlayerKeepers(keepers, limit = TRPG_DEFAULT_PARTY_SIZE) {
      const xs = Array.isArray(keepers) ? keepers : [];
      const capped = Math.max(1, Math.min(8, Number(limit) || TRPG_DEFAULT_PARTY_SIZE));
      return xs.filter((name) => !trpgIsDmLikeKeeper(name)).slice(0, capped);
    }

    function trpgGenerateRoomId() {
      const stamp = new Date().toISOString().replace(/[^0-9]/g, '').slice(2, 14);
      const random = Math.floor(Math.random() * 900) + 100;
      return `adventure-${stamp}-${random}`;
    }

    function trpgExtractKeeperNamesFromPlayerText(rawText) {
      const parsed = parseTrpgPlayerKeepers(String(rawText || ''));
      if (parsed.ok) {
        return trpgUniqueStrings(Object.values(parsed.mapping || {}));
      }
      return trpgUniqueStrings(
        String(rawText || '')
          .split(/\r?\n/)
          .map((line) => line.trim())
          .filter((line) => line !== '')
          .map((line) => {
            const eqIdx = line.indexOf('=');
            if (eqIdx < 0) return line;
            return line.slice(eqIdx + 1).trim();
          })
          .filter((name) => name !== '')
      );
    }

    function trpgActorControlMapping(state) {
      const controlObj =
        state && state.actor_control && typeof state.actor_control === 'object' && !Array.isArray(state.actor_control)
          ? state.actor_control
          : null;
      if (!controlObj) return {};
      const mapping = {};
      Object.entries(controlObj).forEach(([actorRaw, keeperRaw]) => {
        const actorId = String(actorRaw || '').trim();
        const keeperName = String(keeperRaw || '').trim();
        if (!actorId || !keeperName) return;
        mapping[actorId] = keeperName;
      });
      return mapping;
    }

    function trpgActorControlByKeeper(state) {
      const byKeeper = {};
      Object.entries(trpgActorControlMapping(state)).forEach(([actorId, keeperName]) => {
        const actor = String(actorId || '').trim();
        const keeper = String(keeperName || '').trim();
        if (!actor || !keeper) return;
        if (!byKeeper[keeper]) byKeeper[keeper] = [];
        byKeeper[keeper].push(actor);
      });
      return byKeeper;
    }

    function trpgKeeperUsageSnapshot(state, events) {
      const dmKeeper = String((document.getElementById('trpg-dm-keeper-input') || {}).value || '').trim();
      const inputRaw = String((document.getElementById('trpg-player-keepers-input') || {}).value || '');
      const resolved = trpgResolvePlayerKeeperMapping(state, events, inputRaw);
      const playerKeepers = trpgUniqueStrings(
        resolved.ok
          ? Object.values(resolved.mapping || {})
          : trpgExtractKeeperNamesFromPlayerText(inputRaw)
      );
      const playerKeeperSet = new Set(playerKeepers.map((name) => String(name || '').trim()).filter((name) => name !== ''));
      return {
        dmKeeper,
        playerKeeperSet,
        leaseByKeeper: trpgActorControlByKeeper(state),
      };
    }

    function renderTrpgSelectionSummary(state, events) {
      const el = document.getElementById('trpg-selection-summary');
      if (!el) return;
      const dmKeeper = String((document.getElementById('trpg-dm-keeper-input') || {}).value || '').trim();
      const playerRaw = String((document.getElementById('trpg-player-keepers-input') || {}).value || '');
      const parsed = parseTrpgPlayerKeepers(playerRaw);
      const resolved = trpgResolvePlayerKeeperMapping(state, events, playerRaw);
      const mapping = resolved.ok ? resolved.mapping : (parsed.ok ? parsed.mapping : {});
      const players = trpgUniqueStrings(Object.values(mapping || {}));
      const expectedActors = resolved.expectedActors || trpgPartyActorsFromStateOrEvents(state, events);
      const missingActors = resolved.ok ? (resolved.missingActors || []) : [];
      const unknownActors = resolved.ok ? (resolved.unknownActors || []) : [];
      const issues = [];

      if (!dmKeeper) issues.push('DM keeper가 비어 있습니다.');
      if (!parsed.ok) issues.push(String(parsed.error || 'Player keeper 입력 형식을 확인하세요.'));
      if (dmKeeper && players.includes(dmKeeper)) {
        issues.push(`DM keeper(${dmKeeper})가 Player keeper 목록과 중복됩니다.`);
      }
      if (expectedActors.length > 0 && resolved.ok) {
        if (missingActors.length > 0) issues.push(`파티 actor 누락: ${missingActors.join(', ')}`);
        if (unknownActors.length > 0) issues.push(`파티 외 actor 입력 무시: ${unknownActors.join(', ')}`);
      }

      const ready =
        issues.length === 0
        && dmKeeper !== ''
        && players.length > 0
        && (expectedActors.length === 0 || (resolved.ok && missingActors.length === 0));

      const badgeClass = ready ? 'ok' : 'warn';
      const badgeText = ready ? 'READY' : 'CHECK REQUIRED';
      const playerChips = players.length > 0
        ? players.map((name) => `<span class="trpg-selection-chip player">${escapeHtml(name)}</span>`).join('')
        : '<span class="trpg-selection-chip">player 없음</span>';
      const actorChip = expectedActors.length > 0
        ? `<span class="trpg-selection-chip actor">actors ${escapeHtml(String(expectedActors.length))}</span>`
        : '<span class="trpg-selection-chip actor">actors 미확정</span>';
      const issueList = issues.length > 0
        ? `<ul class="trpg-selection-issues">${issues.map((msg) => `<li>${escapeHtml(msg)}</li>`).join('')}</ul>`
        : '';

      el.innerHTML = `
        <div class="trpg-selection-head">
          <div class="trpg-selection-badge ${badgeClass}">${badgeText}</div>
          <div class="trpg-selection-meta">DM 1 / Player ${players.length} / Actor ${expectedActors.length || '-'}</div>
        </div>
        <div class="trpg-selection-row">
          <span class="trpg-selection-chip dm">${dmKeeper ? `DM ${escapeHtml(dmKeeper)}` : 'DM 미지정'}</span>
          ${actorChip}
        </div>
        <div class="trpg-selection-row">${playerChips}</div>
        ${issueList}
      `;
    }

    function trpgPartyActorNameMap(state, events) {
      const out = {};
      const partyObj =
        state && state.party && typeof state.party === 'object' && !Array.isArray(state.party)
          ? state.party
          : null;
      if (partyObj) {
        Object.entries(partyObj).forEach(([actorRaw, infoRaw]) => {
          const actorId = String(actorRaw || '').trim();
          if (!actorId) return;
          const info = (infoRaw && typeof infoRaw === 'object' && !Array.isArray(infoRaw)) ? infoRaw : {};
          const name = String(info.name || '').trim();
          out[actorId] = name || actorId;
        });
        return out;
      }
      for (let i = (events || []).length - 1; i >= 0; i -= 1) {
        const ev = events[i];
        if (trpgEventType(ev) !== 'party.selected') continue;
        const payload = trpgEventPayload(ev);
        const party = Array.isArray(payload.party) ? payload.party : [];
        party.forEach((member) => {
          const actorId = String((member && member.actor_id) || '').trim();
          if (!actorId) return;
          const name = String((member && member.name) || '').trim();
          out[actorId] = name || actorId;
        });
        break;
      }
      return out;
    }

    function trpgRenderAssignmentEditor(state, events) {
      const el = document.getElementById('trpg-assignment-editor');
      if (!el) return;
      const expectedActors = trpgPartyActorsFromStateOrEvents(state, events);
      if (expectedActors.length === 0) {
        el.innerHTML = '<div class="trpg-empty-inline">세션 시작 후 파티 actor 기준으로 할당 편집기가 열립니다.</div>';
        return;
      }
      const resolved = trpgResolvePlayerKeeperMapping(
        state,
        events,
        String((document.getElementById('trpg-player-keepers-input') || {}).value || '')
      );
      const mapping = resolved.ok ? resolved.mapping : {};
      const controlMap = trpgActorControlMapping(state);
      const nameMap = trpgPartyActorNameMap(state, events);
      const dmKeeper = String((document.getElementById('trpg-dm-keeper-input') || {}).value || '').trim();
      const keepers = trpgUniqueStrings(
        []
          .concat(Array.isArray(trpgKeeperCatalog) ? trpgKeeperCatalog : [])
          .concat(Object.values(mapping || {}))
          .concat(Object.values(controlMap || {}))
      );

      const rows = expectedActors.map((actorId) => {
        const actorName = String(nameMap[actorId] || actorId).trim();
        const assignedKeeper = String(mapping[actorId] || '').trim();
        const leasedKeeper = String(controlMap[actorId] || '').trim();
        const current = assignedKeeper || leasedKeeper;
        const optionList = [];
        optionList.push(`<option value="">(미할당)</option>`);
        keepers.forEach((keeper) => {
          const value = String(keeper || '').trim();
          if (!value) return;
          const selected = value === current ? ' selected' : '';
          const dmMark = value === dmKeeper ? ' (DM)' : '';
          optionList.push(`<option value="${escapeHtml(value)}"${selected}>${escapeHtml(value)}${dmMark}</option>`);
        });
        if (current && !keepers.includes(current)) {
          optionList.push(`<option value="${escapeHtml(current)}" selected>${escapeHtml(current)}</option>`);
        }
        const actorToken = encodeURIComponent(actorId);
        const leaseHint =
          leasedKeeper && leasedKeeper !== assignedKeeper
            ? `<span class="muted">lease:${escapeHtml(leasedKeeper)}</span>`
            : '';
        return `
          <div class="trpg-assignment-row">
            <div class="actor">${escapeHtml(actorName)} <span class="muted">(${escapeHtml(actorId)})</span> ${leaseHint}</div>
            <select onchange="trpgSetActorKeeperFromEditor('${actorToken}', this.value)">${optionList.join('')}</select>
          </div>
        `;
      });
      el.innerHTML = rows.join('');
    }

    function trpgSetActorKeeperFromEditor(actorToken, keeperValue) {
      if (trpgRoundRunning || trpgBootstrapping || trpgActorMutating) return;
      let actorId = '';
      try { actorId = decodeURIComponent(String(actorToken || '')); } catch (_) { actorId = String(actorToken || ''); }
      actorId = actorId.trim();
      if (!actorId) return;

      const input = document.getElementById('trpg-player-keepers-input');
      if (!input) return;
      const resolved = trpgResolvePlayerKeeperMapping(
        trpgStateCache,
        trpgCurrentSessionEvents(trpgEventsCache),
        String(input.value || '')
      );
      if (!resolved.ok) {
        setTrpgRoundRunStatus(`오류: ${escapeHtml(String(resolved.error || 'invalid player mapping'))}`, 'error');
        return;
      }

      const nextMap = Object.assign({}, resolved.mapping || {});
      const keeper = String(keeperValue || '').trim();
      const dmKeeper = String((document.getElementById('trpg-dm-keeper-input') || {}).value || '').trim();
      if (keeper && dmKeeper && keeper === dmKeeper) {
        setTrpgRoundRunStatus(`오류: DM keeper(<b>${escapeHtml(dmKeeper)}</b>)는 player actor에 할당할 수 없습니다.`, 'error');
        trpgRenderAssignmentEditor(trpgStateCache, trpgCurrentSessionEvents(trpgEventsCache));
        return;
      }
      if (keeper) {
        for (const [otherActor, otherKeeper] of Object.entries(nextMap)) {
          if (otherActor !== actorId && String(otherKeeper || '').trim() === keeper) {
            setTrpgRoundRunStatus(
              `오류: keeper <b>${escapeHtml(keeper)}</b>는 이미 actor <b>${escapeHtml(otherActor)}</b>에 할당되어 있습니다.`,
              'error'
            );
            trpgRenderAssignmentEditor(trpgStateCache, trpgCurrentSessionEvents(trpgEventsCache));
            return;
          }
        }
        nextMap[actorId] = keeper;
      } else {
        delete nextMap[actorId];
      }
      input.value = playerKeeperMapToText(nextMap);
      trpgSyncKeeperSelectorsFromInputs();
      trpgUpdateNextAction(trpgStateCache, trpgEventsCache);
    }

    function trpgNormalizeAssignmentInput() {
      if (trpgRoundRunning || trpgBootstrapping || trpgActorMutating) return;
      const input = document.getElementById('trpg-player-keepers-input');
      if (!input) return;
      const resolved = trpgResolvePlayerKeeperMapping(
        trpgStateCache,
        trpgCurrentSessionEvents(trpgEventsCache),
        String(input.value || '')
      );
      if (!resolved.ok) {
        setTrpgRoundRunStatus(`입력 정리 실패: ${escapeHtml(String(resolved.error || 'invalid mapping'))}`, 'error');
        return;
      }
      input.value = playerKeeperMapToText(resolved.mapping || {});
      trpgSyncKeeperSelectorsFromInputs();
      const missing = (resolved.missingActors || []).length;
      const unknown = (resolved.unknownActors || []).length;
      if (missing > 0 || unknown > 0) {
        setTrpgRoundRunStatus(
          `입력 정리 완료: missing ${missing}, unknown ${unknown}. 파티 할당 편집기에서 남은 항목을 채우세요.`,
          'running'
        );
      } else {
        setTrpgRoundRunStatus('입력 정리 완료: 현재 파티 actor와 할당 입력이 일치합니다.', 'ok');
      }
    }

    function trpgAutofillAssignmentByParty() {
      if (trpgRoundRunning || trpgBootstrapping || trpgActorMutating) return;
      const input = document.getElementById('trpg-player-keepers-input');
      if (!input) return;
      const viewEvents = trpgCurrentSessionEvents(trpgEventsCache);
      const expectedActors = trpgPartyActorsFromStateOrEvents(trpgStateCache, viewEvents);
      if (expectedActors.length === 0) {
        setTrpgRoundRunStatus('오류: 파티 actor를 아직 찾지 못했습니다. 먼저 세션 시작을 실행하세요.', 'error');
        return;
      }

      const resolved = trpgResolvePlayerKeeperMapping(trpgStateCache, viewEvents, String(input.value || ''));
      const currentMap = resolved.ok ? resolved.mapping : {};
      const controlMap = trpgActorControlMapping(trpgStateCache);
      const dmKeeper = String((document.getElementById('trpg-dm-keeper-input') || {}).value || '').trim();
      const playerSelect = document.getElementById('trpg-player-keepers-select');
      const selectedKeepers = trpgUniqueStrings(
        Array.from((playerSelect && playerSelect.selectedOptions) || [])
          .map((option) => String(option.value || '').trim())
          .filter((name) => name !== '')
      );
      const candidateKeepers = trpgUniqueStrings(
        []
          .concat(selectedKeepers)
          .concat(trpgExtractKeeperNamesFromPlayerText(String(input.value || '')))
          .concat(Object.values(controlMap || {}))
          .concat(trpgSuggestedPlayerKeepers(trpgKeeperCatalog, expectedActors.length))
      ).filter((name) => name !== '' && name !== dmKeeper);

      const nextMap = {};
      const usedKeepers = new Set();
      expectedActors.forEach((actorId) => {
        const currentKeeper = String(currentMap[actorId] || '').trim();
        if (currentKeeper && currentKeeper !== dmKeeper && !usedKeepers.has(currentKeeper)) {
          nextMap[actorId] = currentKeeper;
          usedKeepers.add(currentKeeper);
        }
      });
      expectedActors.forEach((actorId) => {
        if (nextMap[actorId]) return;
        const leased = String(controlMap[actorId] || '').trim();
        if (leased && leased !== dmKeeper && !usedKeepers.has(leased)) {
          nextMap[actorId] = leased;
          usedKeepers.add(leased);
        }
      });
      let allocationFailed = false;
      for (const actorId of expectedActors) {
        if (nextMap[actorId] || allocationFailed) continue;
        const picked = candidateKeepers.find((keeper) => !usedKeepers.has(keeper));
        if (picked) {
          nextMap[actorId] = picked;
          usedKeepers.add(picked);
          continue;
        }
        allocationFailed = true;
        setTrpgRoundRunStatus(
          `오류: actor ${escapeHtml(actorId)}에 매핑할 사용 가능한 keeper가 부족합니다. 선택 가능한 keeper를 먼저 추가하세요.`,
          'error'
        );
      }
      if (allocationFailed) {
        return;
      }

      input.value = playerKeeperMapToText(nextMap);
      trpgSyncKeeperSelectorsFromInputs();
      trpgUpdateNextAction(trpgStateCache, viewEvents);
      setTrpgRoundRunStatus(
        `파티 자동 할당 완료: actor ${expectedActors.length}명 / keeper ${Object.keys(nextMap).length}개 매핑`,
        'ok'
      );
    }

    function trpgSyncKeeperSelectorsFromInputs() {
      const dmSelect = document.getElementById('trpg-dm-keeper-select');
      const playerSelect = document.getElementById('trpg-player-keepers-select');
      const keepers = new Set(Array.isArray(trpgKeeperCatalog) ? trpgKeeperCatalog : []);
      const dmKeeper = String((document.getElementById('trpg-dm-keeper-input') || {}).value || '').trim();
      const playerKeepers = trpgExtractKeeperNamesFromPlayerText(
        String((document.getElementById('trpg-player-keepers-input') || {}).value || '')
      ).filter((name) => name !== dmKeeper);

      if (dmSelect) {
        if (dmKeeper && keepers.has(dmKeeper)) dmSelect.value = dmKeeper;
        else dmSelect.value = '';
      }
      if (playerSelect) {
        const selected = new Set(playerKeepers.filter((name) => keepers.has(name)));
        Array.from(playerSelect.options || []).forEach((option) => {
          const value = String(option.value || '').trim();
          option.selected = value !== '' && selected.has(value);
        });
      }
      trpgRenderAssignmentEditor(trpgStateCache, trpgCurrentSessionEvents(trpgEventsCache));
      renderTrpgKeeperQuickList();
      renderTrpgSelectionSummary(trpgStateCache, trpgCurrentSessionEvents(trpgEventsCache));
    }

    function trpgPopulateKeeperSelectors(force = false) {
      const dmSelect = document.getElementById('trpg-dm-keeper-select');
      const playerSelect = document.getElementById('trpg-player-keepers-select');
      if (!dmSelect && !playerSelect) return;

      const keepers = Array.isArray(trpgKeeperCatalog) ? trpgKeeperCatalog : [];
      const key = keepers.join('\n');
      if (!force && key === trpgKeeperSelectorsKey) {
        trpgSyncKeeperSelectorsFromInputs();
        return;
      }
      trpgKeeperSelectorsKey = key;

      if (dmSelect) {
        if (keepers.length === 0) {
          dmSelect.innerHTML = '<option value="">(keeper 없음)</option>';
        } else {
          dmSelect.innerHTML = [
            '<option value="">(입력값 유지)</option>',
            ...keepers.map((name) => {
              const safe = escapeHtml(name);
              const mark = trpgIsDmLikeKeeper(name) ? ' (DM 추천)' : '';
              return `<option value="${safe}">${safe}${mark}</option>`;
            }),
          ].join('');
        }
      }

      if (playerSelect) {
        if (keepers.length === 0) {
          playerSelect.innerHTML = '<option value="">(keeper 없음)</option>';
        } else {
          playerSelect.innerHTML = keepers.map((name) => {
            const safe = escapeHtml(name);
            return `<option value="${safe}">${safe}</option>`;
          }).join('');
        }
      }

      trpgSyncKeeperSelectorsFromInputs();
    }

    function trpgApplyKeeperSelectionToInputs() {
      const dmSelect = document.getElementById('trpg-dm-keeper-select');
      const playerSelect = document.getElementById('trpg-player-keepers-select');
      const dmInput = document.getElementById('trpg-dm-keeper-input');
      const playerInput = document.getElementById('trpg-player-keepers-input');

      const dmKeeper = String((dmSelect && dmSelect.value) || '').trim();
      if (dmInput && dmKeeper !== '') dmInput.value = dmKeeper;

      if (playerSelect && dmKeeper !== '') {
        Array.from(playerSelect.options || []).forEach((option) => {
          if (String(option.value || '').trim() === dmKeeper) option.selected = false;
        });
      }
      const selectedPlayers = trpgUniqueStrings(
        Array.from((playerSelect && playerSelect.selectedOptions) || [])
          .map((option) => String(option.value || '').trim())
          .filter((name) => name !== '' && name !== dmKeeper)
      );
      if (playerInput && selectedPlayers.length > 0) {
        const sessionEvents = trpgCurrentSessionEvents(trpgEventsCache);
        const expectedActors = trpgPartyActorsFromStateOrEvents(trpgStateCache, sessionEvents);
        if (expectedActors.length > 0) {
          const existingParsed = parseTrpgPlayerKeepers(String(playerInput.value || ''));
          const existingMap = existingParsed.ok ? existingParsed.mapping : {};
          const nextMap = {};
          expectedActors.forEach((actorId, idx) => {
            const keeper =
              String(selectedPlayers[idx] || '').trim()
              || String(existingMap[actorId] || '').trim();
            if (keeper) nextMap[actorId] = keeper;
          });
          playerInput.value = playerKeeperMapToText(nextMap);
        } else {
          playerInput.value = selectedPlayers.map((name) => `${name}=${name}`).join('\n');
        }
      }

      trpgSyncKeeperSelectorsFromInputs();
      trpgUpdateNextAction(trpgStateCache, trpgEventsCache);
    }

    function renderTrpgKeeperQuickList() {
      const el = document.getElementById('trpg-keeper-quick');
      if (!el) return;
      const keepers = Array.isArray(trpgKeeperCatalog) ? trpgKeeperCatalog : [];
      if (keepers.length === 0) {
        el.innerHTML = '<div class="trpg-empty-inline">사용 가능한 Keeper를 찾지 못했습니다. 직접 이름을 입력해도 됩니다.</div>';
        return;
      }
      const usage = trpgKeeperUsageSnapshot(trpgStateCache, trpgCurrentSessionEvents(trpgEventsCache));
      const readOnly = trpgRoundRunning || trpgBootstrapping || trpgActorMutating;
      el.innerHTML = keepers.map((name) => {
        const safe = escapeHtml(name);
        const token = encodeURIComponent(name);
        const detail = trpgKeeperDetail(name);
        const health = trpgKeeperHealth(detail);
        const activeModel = String((detail && detail.active_model) || '').trim();
        const isDm = name === usage.dmKeeper;
        const isPlayer = usage.playerKeeperSet.has(name);
        const leasedActors = Array.isArray(usage.leaseByKeeper[name]) ? usage.leaseByKeeper[name] : [];
        const isOffline = health.cls === 'health-offline';
        const tags = []
          .concat(isDm ? [`<span class="trpg-keeper-tag dm">DM</span>`] : [])
          .concat(isPlayer ? [`<span class="trpg-keeper-tag player">PLAYER</span>`] : [])
          .concat(leasedActors.length > 0 ? [`<span class="trpg-keeper-tag lease">LEASE ${escapeHtml(leasedActors.join(','))}</span>`] : [])
          .concat([`<span class="trpg-keeper-tag ${health.cls}" title="${escapeHtml(health.reason)}">${escapeHtml(health.label)}</span>`])
          .concat(activeModel ? [`<span class="trpg-keeper-tag model" title="${escapeHtml(activeModel)}">${escapeHtml(activeModel)}</span>`] : [])
          .join('');
        const leaseConflict = leasedActors.length > 1;
        const canUnsetDm = isDm && !readOnly;
        const canSetDm = !isDm && !readOnly && !isPlayer && !isOffline;
        const disableDm = !(canUnsetDm || canSetDm);
        const canRemovePlayer = isPlayer && !readOnly;
        const canAddPlayer = !isPlayer && !readOnly && !isDm && !leaseConflict && !isOffline;
        const disablePlayer = !(canRemovePlayer || canAddPlayer);
        const playerBtnLabel = isPlayer ? '−Player' : '+Player';
        const dmTitle = disableDm
          ? (readOnly
              ? '라운드/세션 처리 중에는 변경할 수 없습니다.'
              : (isOffline
                  ? 'OFF 상태 keeper는 DM으로 지정할 수 없습니다.'
                  : '이미 Player로 사용 중인 keeper는 DM으로 지정할 수 없습니다.'))
          : (isDm ? '클릭하면 DM 지정을 해제합니다.' : '클릭하면 DM으로 지정합니다.');
        const playerTitle = disablePlayer
          ? (readOnly
              ? '라운드/세션 처리 중에는 변경할 수 없습니다.'
              : (isDm
                  ? 'DM keeper는 Player로 추가할 수 없습니다.'
                  : (isOffline
                      ? 'OFF 상태 keeper는 Player로 추가할 수 없습니다.'
                      : '이 keeper는 여러 actor lease를 갖고 있어 자동 추가할 수 없습니다. 할당 편집기에서 actor를 직접 선택하세요.')))
          : (isPlayer ? '클릭하면 Player 목록에서 제거합니다.' : '클릭하면 Player 목록에 추가합니다.');
        return `<div class="trpg-keeper-chip">
          <span class="trpg-keeper-name" title="${safe}">${safe}</span>
          <span class="trpg-keeper-badges">${tags}</span>
          <button type="button" class="trpg-mini-btn" ${disableDm ? 'disabled' : ''} title="${escapeHtml(dmTitle)}" onclick="setTrpgDmKeeperFromQuick('${token}')">DM</button>
          <button type="button" class="trpg-mini-btn" ${disablePlayer ? 'disabled' : ''} title="${escapeHtml(playerTitle)}" onclick="addTrpgPlayerKeeperFromQuick('${token}')">${playerBtnLabel}</button>
        </div>`;
      }).join('');
    }

    function setTrpgDmKeeperFromQuick(token) {
      if (trpgRoundRunning || trpgBootstrapping || trpgActorMutating) return;
      let name = '';
      try { name = decodeURIComponent(String(token || '')); } catch (_) { name = String(token || ''); }
      name = name.trim();
      if (!name) return;
      const usage = trpgKeeperUsageSnapshot(trpgStateCache, trpgCurrentSessionEvents(trpgEventsCache));
      const detail = trpgKeeperDetail(name);
      const health = trpgKeeperHealth(detail);
      if (usage.dmKeeper === name) {
        const dmInput = document.getElementById('trpg-dm-keeper-input');
        if (dmInput) dmInput.value = '';
        trpgSyncKeeperSelectorsFromInputs();
        showToast(`DM Keeper 해제: ${name}`, 'success');
        trpgUpdateNextAction(trpgStateCache, trpgEventsCache);
        return;
      }
      if (health.cls === 'health-offline') {
        setTrpgRoundRunStatus(`오류: keeper <b>${escapeHtml(name)}</b>는 OFF 상태라 DM으로 지정할 수 없습니다.`, 'error');
        renderTrpgKeeperQuickList();
        return;
      }
      if (usage.playerKeeperSet.has(name) && usage.dmKeeper !== name) {
        setTrpgRoundRunStatus(`오류: keeper <b>${escapeHtml(name)}</b>는 이미 Player로 사용 중입니다.`, 'error');
        renderTrpgKeeperQuickList();
        return;
      }
      const dmInput = document.getElementById('trpg-dm-keeper-input');
      if (dmInput) dmInput.value = name;
      trpgSyncKeeperSelectorsFromInputs();
      showToast(`DM Keeper 선택: ${name}`, 'success');
      trpgUpdateNextAction(trpgStateCache, trpgEventsCache);
    }

    function addTrpgPlayerKeeperFromQuick(token) {
      if (trpgRoundRunning || trpgBootstrapping || trpgActorMutating) return;
      let name = '';
      try { name = decodeURIComponent(String(token || '')); } catch (_) { name = String(token || ''); }
      name = name.trim();
      if (!name) return;
      const input = document.getElementById('trpg-player-keepers-input');
      if (!input) return;
      const usage = trpgKeeperUsageSnapshot(trpgStateCache, trpgCurrentSessionEvents(trpgEventsCache));
      const detail = trpgKeeperDetail(name);
      const health = trpgKeeperHealth(detail);
      if (usage.dmKeeper === name) {
        setTrpgRoundRunStatus(`오류: DM keeper <b>${escapeHtml(name)}</b>는 Player로 추가할 수 없습니다.`, 'error');
        renderTrpgKeeperQuickList();
        return;
      }
      if (usage.playerKeeperSet.has(name)) {
        const parsed = parseTrpgPlayerKeepers(String(input.value || ''));
        if (parsed.ok) {
          const nextMap = {};
          Object.entries(parsed.mapping || {}).forEach(([actorId, keeperName]) => {
            if (String(keeperName || '').trim() !== name) {
              nextMap[actorId] = keeperName;
            }
          });
          input.value = playerKeeperMapToText(nextMap);
        } else {
          const lines = String(input.value || '')
            .split(/\r?\n/)
            .map((line) => line.trim())
            .filter((line) => line !== '')
            .filter((line) => {
              if (line === name || line === `${name}=${name}`) return false;
              const eqIdx = line.indexOf('=');
              if (eqIdx < 0) return line !== name;
              const keeper = line.slice(eqIdx + 1).trim();
              return keeper !== name;
            });
          input.value = lines.join('\n');
        }
        trpgSyncKeeperSelectorsFromInputs();
        showToast(`Player Keeper 제거: ${name}`, 'success');
        trpgUpdateNextAction(trpgStateCache, trpgEventsCache);
        return;
      }
      if (health.cls === 'health-offline') {
        setTrpgRoundRunStatus(`오류: keeper <b>${escapeHtml(name)}</b>는 OFF 상태라 Player로 추가할 수 없습니다.`, 'error');
        renderTrpgKeeperQuickList();
        return;
      }
      const lines = String(input.value || '')
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter((line) => line !== '');
      const leasedActors = Array.isArray(usage.leaseByKeeper[name]) ? usage.leaseByKeeper[name] : [];
      if (leasedActors.length > 1) {
        setTrpgRoundRunStatus(
          `오류: keeper <b>${escapeHtml(name)}</b>는 lease actor가 여러 개(${escapeHtml(leasedActors.join(', '))})라 자동 추가할 수 없습니다. 파티 할당 편집기에서 actor를 직접 선택하세요.`,
          'error'
        );
        renderTrpgKeeperQuickList();
        return;
      }
      const leaseActor = leasedActors.length === 1 ? String(leasedActors[0] || '').trim() : '';
      const lineToAdd = leaseActor ? `${leaseActor}=${name}` : name;
      const exists = lines.some((line) => {
        if (line === name || line === `${name}=${name}` || line === lineToAdd) return true;
        const eqIdx = line.indexOf('=');
        if (eqIdx < 0) return false;
        const actorId = line.slice(0, eqIdx).trim();
        const keeperName = line.slice(eqIdx + 1).trim();
        return actorId === name || keeperName === name;
      });
      if (!exists) lines.push(lineToAdd);
      input.value = lines.join('\n');
      trpgSyncKeeperSelectorsFromInputs();
      showToast(`Player Keeper 추가: ${name}`, 'success');
      trpgUpdateNextAction(trpgStateCache, trpgEventsCache);
    }

    function clearTrpgPlayerKeepers() {
      const input = document.getElementById('trpg-player-keepers-input');
      if (!input) return;
      input.value = '';
      trpgSyncKeeperSelectorsFromInputs();
      showToast('Player Keeper 입력을 비웠습니다.', 'success');
      trpgUpdateNextAction(trpgStateCache, trpgEventsCache);
    }

    function applyTrpgKeeperAutofill(force = false) {
      const keepers = Array.isArray(trpgKeeperCatalog) ? trpgKeeperCatalog : [];
      if (keepers.length === 0) return;
      const dmInput = document.getElementById('trpg-dm-keeper-input');
      const playerInput = document.getElementById('trpg-player-keepers-input');
      const partySizeRaw = Number((document.getElementById('trpg-party-size-input') || {}).value);
      const partySize = Number.isFinite(partySizeRaw)
        ? Math.max(1, Math.min(8, Math.floor(partySizeRaw)))
        : TRPG_DEFAULT_PARTY_SIZE;
      if (dmInput && (force || String(dmInput.value || '').trim() === '')) {
        const preferredDm = keepers.find((name) => trpgIsDmLikeKeeper(name)) || keepers[0];
        if (preferredDm) dmInput.value = preferredDm;
      }
      if (playerInput && (force || String(playerInput.value || '').trim() === '')) {
        const preferred = trpgSuggestedPlayerKeepers(keepers, partySize);
        if (preferred.length > 0) {
          playerInput.value = preferred.join('\n');
        }
      }
      trpgSyncKeeperSelectorsFromInputs();
      trpgUpdateNextAction(trpgStateCache, trpgEventsCache);
    }

    async function ensureTrpgKeeperCatalog(force = false) {
      if (trpgKeepersLoaded && !force) return trpgKeeperCatalog;
      let data = null;
      try {
        data = await mcpToolCall('masc_keeper_list', { limit: 200, detailed: true });
      } catch (_) {
        data = await mcpToolCall('masc_keeper_list', { limit: 200 });
      }
      const normalized = trpgNormalizeKeeperCatalog(data && data.keepers);
      trpgKeeperCatalog = Array.isArray(normalized.names) ? normalized.names : [];
      trpgKeeperCatalogDetails =
        normalized && normalized.details && typeof normalized.details === 'object'
          ? normalized.details
          : {};
      trpgKeepersLoaded = true;
      renderTrpgKeeperQuickList();
      applyTrpgKeeperAutofill(false);
      trpgPopulateKeeperSelectors(true);
      return trpgKeeperCatalog;
    }

    async function startTrpgNewGameFlow() {
      if (trpgRoundRunning || trpgBootstrapping || trpgActorMutating) return;
      ensureTrpgControlDefaults();
      const roomInput = document.getElementById('trpg-room-input');
      const newRoomId = trpgGenerateRoomId();
      if (roomInput) roomInput.value = newRoomId;
      applyTrpgRoomFromInput();
      setTrpgRoundRunStatus(
        `새 게임 room <b>${escapeHtml(newRoomId)}</b> 생성. DM/AI Player를 고른 뒤 <b>1) 세션 시작</b>을 누르세요.`,
        'running'
      );
      try {
        await Promise.all([
          ensureTrpgPresetCatalog(false),
          ensureTrpgKeeperCatalog(false),
        ]);
        trpgPopulateKeeperSelectors(false);
        const keepers = Array.isArray(trpgKeeperCatalog) ? trpgKeeperCatalog : [];
        const dmSelect = document.getElementById('trpg-dm-keeper-select');
        const playerSelect = document.getElementById('trpg-player-keepers-select');
        const preferredDm =
          (dmSelect && String(dmSelect.value || '').trim())
          || keepers.find((name) => trpgIsDmLikeKeeper(name))
          || keepers[0]
          || '';
        if (dmSelect && preferredDm) dmSelect.value = preferredDm;

        const partySizeRaw = Number((document.getElementById('trpg-party-size-input') || {}).value);
        const partySize = Number.isFinite(partySizeRaw)
          ? Math.max(1, Math.min(8, Math.floor(partySizeRaw)))
          : TRPG_DEFAULT_PARTY_SIZE;
        const suggestedPlayers = trpgSuggestedPlayerKeepers(keepers, partySize).filter((name) => name !== preferredDm);
        if (playerSelect) {
          const selected = new Set(suggestedPlayers);
          Array.from(playerSelect.options || []).forEach((option) => {
            const value = String(option.value || '').trim();
            option.selected = selected.has(value);
          });
        }
        trpgApplyKeeperSelectionToInputs();
        await fetchTrpg();
        setTrpgRoundRunStatus(
          `새 게임 준비 완료: room <b>${escapeHtml(newRoomId)}</b> · DM/AI Player 확인 후 <b>1) 세션 시작</b>`,
          'ok'
        );
        showToast(`새 게임 room 준비: ${newRoomId}`, 'success');
      } catch (e) {
        const msg = String((e && e.message) || e || 'unknown error');
        setTrpgRoundRunStatus(`새 게임 준비 실패: ${escapeHtml(msg)}`, 'error');
        showToast('새 게임 준비 실패', 'error');
      }
    }

    async function reloadTrpgCatalogs() {
      if (trpgRoundRunning || trpgBootstrapping || trpgActorMutating) return;
      setTrpgRoundRunStatus('프리셋/키퍼 목록 새로고침 중...', 'running');
      try {
        const [presets, keepers] = await Promise.all([
          ensureTrpgPresetCatalog(true),
          ensureTrpgKeeperCatalog(true),
        ]);
        const worldCount = Array.isArray(presets.world_presets) ? presets.world_presets.length : 0;
        const dmCount = Array.isArray(presets.dm_presets) ? presets.dm_presets.length : 0;
        const keeperCount = Array.isArray(keepers) ? keepers.length : 0;
        setTrpgRoundRunStatus(
          `프리셋 로드 완료: world ${worldCount}, dm ${dmCount}, keeper ${keeperCount}`,
          'ok'
        );
        showToast('TRPG 카탈로그 새로고침 완료', 'success');
      } catch (e) {
        const msg = String((e && e.message) || e || 'unknown error');
        setTrpgRoundRunStatus(`카탈로그 새로고침 실패: ${escapeHtml(msg)}`, 'error');
        showToast('TRPG 카탈로그 새로고침 실패', 'error');
      }
    }

    function playerKeeperMapToText(mapping) {
      if (!mapping || typeof mapping !== 'object' || Array.isArray(mapping)) return '';
      return Object.entries(mapping)
        .map(([actor, keeper]) => {
          const actorId = String(actor || '').trim();
          const keeperName = String(keeper || '').trim();
          if (!actorId || !keeperName) return '';
          return `${actorId}=${keeperName}`;
        })
        .filter((line) => line !== '')
        .join('\n');
    }

    function trpgUnwrapToolPayload(value) {
      const payload = value && typeof value === 'object' && !Array.isArray(value)
        ? value
        : null;
      if (!payload) return value;

      if (Object.prototype.hasOwnProperty.call(payload, 'payload')) {
        const inner = payload.payload;
        if (inner !== undefined && inner !== null) return inner;
      }

      if (
        Object.prototype.hasOwnProperty.call(payload, 'result')
        && payload.result
        && typeof payload.result === 'object'
        && !Array.isArray(payload.result)
      ) {
        if (Object.prototype.hasOwnProperty.call(payload.result, 'payload')) {
          const inner = payload.result.payload;
          if (inner !== undefined && inner !== null) return inner;
        }
        if (Object.prototype.hasOwnProperty.call(payload.result, 'structuredContent')) {
          const structured = payload.result.structuredContent;
          if (structured !== undefined && structured !== null) {
            if (Object.prototype.hasOwnProperty.call(structured, 'payload')) {
              const inner = structured.payload;
              if (inner !== undefined && inner !== null) return inner;
            }
            return structured;
          }
        }
      }

      if (payload.status === 'ok' && Object.prototype.hasOwnProperty.call(payload, 'structured_content')) {
        const structured = payload.structured_content;
        if (structured !== undefined && structured !== null) {
          if (Object.prototype.hasOwnProperty.call(structured, 'payload')) {
            const inner = structured.payload;
            if (inner !== undefined && inner !== null) return inner;
          }
          return structured;
        }
      }

      return value;
    }

    function parseTrpgToolText(name, text) {
      const raw = String(text || '').trim();
      if (raw === '') return {};
      const parsed = trpgTryParseJson(raw);
      if (parsed === null) {
        throw new Error(`${name} 응답이 JSON이 아닙니다: ${trpgShortText(raw, 180)}`);
      }
      const payload = trpgUnwrapToolPayload(parsed);
      if (payload !== null && payload !== undefined && payload !== parsed) {
        return payload;
      }
      return parsed;
    }

    function trpgExtractJsonCandidates(text) {
      const src = String(text || '');
      const out = [];
      const stack = [];
      let start = -1;
      let inString = false;
      let escaped = false;
      for (let i = 0; i < src.length; i += 1) {
        const ch = src[i];
        if (inString) {
          if (escaped) {
            escaped = false;
          } else if (ch === '\\') {
            escaped = true;
          } else if (ch === '"') {
            inString = false;
          }
          continue;
        }
        if (ch === '"') {
          inString = true;
          continue;
        }
        if (ch === '{' || ch === '[') {
          if (stack.length === 0) start = i;
          stack.push(ch);
          continue;
        }
        if (ch === '}' || ch === ']') {
          if (stack.length === 0) continue;
          const open = stack[stack.length - 1];
          const match = (open === '{' && ch === '}') || (open === '[' && ch === ']');
          if (!match) {
            stack.length = 0;
            start = -1;
            continue;
          }
          stack.pop();
          if (stack.length === 0 && start >= 0) {
            const candidate = src.slice(start, i + 1).trim();
            if (candidate !== '') out.push(candidate);
            start = -1;
          }
        }
      }
      return out;
    }

    function trpgTryParseJson(rawText) {
      const raw = String(rawText || '').trim();
      if (raw === '') return null;
      try {
        return JSON.parse(raw);
      } catch (_) {
        // fallthrough
      }
      const fenceMatch = raw.match(/```(?:json)?\s*([\s\S]*?)```/i);
      if (fenceMatch && fenceMatch[1]) {
        const fenced = String(fenceMatch[1] || '').trim();
        if (fenced !== '') {
          try {
            return JSON.parse(fenced);
          } catch (_) {
            // fallthrough
          }
        }
      }
      const candidates = trpgExtractJsonCandidates(raw).sort((a, b) => b.length - a.length);
      for (const candidate of candidates) {
        try {
          return JSON.parse(candidate);
        } catch (_) {
          // keep trying
        }
      }
      return null;
    }

    function trpgUnwrapRpcObject(value, maxDepth = 4) {
      let current = value;
      for (let i = 0; i < maxDepth; i += 1) {
        if (current && typeof current === 'object') return current;
        if (typeof current !== 'string') break;
        const parsed = trpgTryParseJson(current);
        if (parsed === null || parsed === current) break;
        current = parsed;
      }
      return (current && typeof current === 'object') ? current : null;
    }

    function parseMcpRpcFromSse(toolName, rawBody) {
      const raw = String(rawBody || '');
      const chunks = raw.split(/\r?\n\r?\n/);
      for (let i = chunks.length - 1; i >= 0; i -= 1) {
        const chunk = String(chunks[i] || '').trim();
        if (chunk === '') continue;
        const parsedChunk = trpgUnwrapRpcObject(trpgTryParseJson(chunk));
        if (parsedChunk) {
          return parsedChunk;
        }
        const dataLines = chunk
          .split(/\r?\n/)
          .filter((line) => line.startsWith('data:'))
          .map((line) => line.slice(5).trimStart());
        if (dataLines.length === 0) continue;
        const dataText = dataLines.join('\n').trim();
        if (dataText === '' || dataText === '[DONE]') continue;
        const parsedData = trpgUnwrapRpcObject(trpgTryParseJson(dataText));
        if (parsedData) {
          return parsedData;
        }
      }
      const trimmed = raw.trim();
      const parsedRaw = trpgUnwrapRpcObject(trpgTryParseJson(trimmed));
      if (parsedRaw) {
        return parsedRaw;
      }
      const dataCandidates = raw
        .split(/\r?\n/)
        .filter((line) => line.startsWith('data:'))
        .map((line) => line.slice(5).trimStart())
        .filter((line) => line !== '' && line !== '[DONE]');
      for (let i = dataCandidates.length - 1; i >= 0; i -= 1) {
        const parsedDataLine = trpgUnwrapRpcObject(trpgTryParseJson(dataCandidates[i]));
        if (parsedDataLine) {
          return parsedDataLine;
        }
      }
      throw new Error(`${toolName} SSE 응답 파싱 실패: ${trpgShortText(raw, 220)}`);
    }

    function normalizeRpcEnvelope(requestId, parsed) {
      if (parsed && typeof parsed === 'object') {
        if (Object.prototype.hasOwnProperty.call(parsed, 'jsonrpc')
            || Object.prototype.hasOwnProperty.call(parsed, 'result')
            || Object.prototype.hasOwnProperty.call(parsed, 'error')) {
          return parsed;
        }
      }
      const fallbackText = typeof parsed === 'string' ? parsed : JSON.stringify(parsed || {});
      return {
        jsonrpc: '2.0',
        id: requestId,
        result: {
          content: [{ type: 'text', text: String(fallbackText || '') }],
          isError: false,
        },
      };
    }

    async function mcpToolCall(toolName, args = {}) {
      const requestId = ++trpgMcpCallSeq;
      const headers = Object.assign({
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
      }, authHeaders());
      if (trpgMcpSessionId) headers['Mcp-Session-Id'] = trpgMcpSessionId;
      const payload = {
        jsonrpc: '2.0',
        id: requestId,
        method: 'tools/call',
        params: {
          name: toolName,
          arguments: args,
        },
      };
      const res = await fetch('/mcp', {
        method: 'POST',
        headers,
        body: JSON.stringify(payload),
      });
      const nextSessionId = res.headers.get('mcp-session-id') || res.headers.get('Mcp-Session-Id');
      if (nextSessionId && String(nextSessionId).trim() !== '') {
        trpgMcpSessionId = String(nextSessionId).trim();
      }
      const contentType = String(res.headers.get('content-type') || '').toLowerCase();
      const rawBody = await res.text();
      let rpc = {};
      if (rawBody.trim() !== '') {
        if (contentType.includes('text/event-stream')) {
          rpc = parseMcpRpcFromSse(toolName, rawBody);
        } else {
          let parsedDirect = trpgUnwrapRpcObject(trpgTryParseJson(rawBody));
          if (parsedDirect === null) {
            const candidates = trpgExtractJsonCandidates(rawBody);
            for (let i = 0; i < candidates.length; i += 1) {
              const candidate = candidates[i];
              const parsed = trpgUnwrapRpcObject(trpgTryParseJson(candidate));
              if (parsed !== null) {
                parsedDirect = parsed;
                break;
              }
            }
          }

          if (parsedDirect !== null) {
            rpc = normalizeRpcEnvelope(requestId, parsedDirect);
          } else {
            try {
              rpc = parseMcpRpcFromSse(toolName, rawBody);
            } catch (innerErr) {
              const innerMsg = String((innerErr && innerErr.message) || innerErr || 'parse error');
              throw new Error(
                `${toolName} 응답 파싱 실패 (HTTP ${res.status}): ${innerMsg} / raw=${trpgShortText(rawBody, 220)}`
              );
            }
          }
        }
      }
      if (!res.ok) {
        const msg = (rpc && rpc.error && rpc.error.message) ? rpc.error.message : `HTTP ${res.status}`;
        throw new Error(String(msg));
      }
      if (rpc && rpc.error) {
        throw new Error(String(rpc.error.message || `${toolName} RPC 오류`));
      }
      if (rpc && typeof rpc === 'object' && !Array.isArray(rpc)
          && !Object.prototype.hasOwnProperty.call(rpc, 'result')
          && !Object.prototype.hasOwnProperty.call(rpc, 'error')
          && (Object.prototype.hasOwnProperty.call(rpc, 'payload')
            || Object.prototype.hasOwnProperty.call(rpc, 'status'))) {
        return (rpc.payload !== undefined && rpc.payload !== null) ? rpc.payload : rpc;
      }
      const result = (rpc && rpc.result && typeof rpc.result === 'object') ? rpc.result : {};
      if (result && typeof result === 'object' && !Array.isArray(result)
          && result.structuredContent && typeof result.structuredContent === 'object') {
        const structured = result.structuredContent;
        return (structured.payload !== undefined && structured.payload !== null)
          ? structured.payload
          : structured;
      }
      if (result && typeof result === 'object' && !Array.isArray(result)
          && result.payload !== undefined && result.payload !== null) {
        return result.payload;
      }
      const content = Array.isArray(result.content) ? result.content : [];
      const textChunk = content.find((row) => row && row.type === 'text' && typeof row.text === 'string');
      const text = textChunk ? textChunk.text : '';
      if (result.isError) {
        throw new Error(text || `${toolName} 실행 실패`);
      }
      return parseTrpgToolText(toolName, text);
    }

    function trpgNormalizePresetCatalogPayload(raw) {
      if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
        return { dm_presets: [], world_presets: [] };
      }
      const payload = trpgUnwrapToolPayload(raw);
      const source =
        payload && typeof payload === 'object' && !Array.isArray(payload)
          ? payload
          : raw;
      const dmPresets = Array.isArray(source.dm_presets) ? source.dm_presets : [];
      const worldPresets = Array.isArray(source.world_presets) ? source.world_presets : [];
      return {
        dm_presets: dmPresets,
        world_presets: worldPresets,
      };
    }

    async function ensureTrpgPresetCatalog(force = false) {
      if (trpgPresetsLoaded && !force) return trpgPresetCatalog;
      let catalog = null;
      try {
        catalog = await mcpToolCall('trpg.preset.list', {
          include_characters: false,
          include_skills: false,
        });
      } catch (primaryErr) {
        try {
          catalog = await mcpToolCall('masc_trpg_preset_list', {
            include_characters: false,
            include_skills: false,
          });
        } catch (legacyErr) {
          const primaryMsg = String((primaryErr && primaryErr.message) || primaryErr || 'unknown error');
          const legacyMsg = String((legacyErr && legacyErr.message) || legacyErr || 'unknown error');
          throw new Error(`preset 조회 실패: canonical(${primaryMsg}) / legacy(${legacyMsg})`);
        }
      }
      trpgPresetCatalog = trpgNormalizePresetCatalogPayload(catalog);
      if (trpgPresetCatalog.dm_presets.length === 0 && trpgPresetCatalog.world_presets.length === 0) {
        throw new Error('preset 응답에 목록이 없습니다.');
      }
      trpgPresetsLoaded = true;
      setTrpgPresetOptions('trpg-world-preset-select', trpgPresetCatalog.world_presets);
      setTrpgPresetOptions('trpg-dm-preset-select', trpgPresetCatalog.dm_presets);
      return trpgPresetCatalog;
    }

    function updateTrpgButtons() {
      const runBtn = document.getElementById('trpg-run-round-btn');
      if (runBtn) {
        runBtn.disabled = trpgRoundRunning || trpgBootstrapping || trpgActorMutating || !trpgCanRunRound;
        runBtn.textContent = trpgRoundRunning ? '실행 중...' : '2) 라운드 실행';
        runBtn.title =
          (!trpgRoundRunning && !trpgBootstrapping && !trpgActorMutating && !trpgCanRunRound && trpgRunBlockedReason)
            ? trpgRunBlockedReason
            : '';
      }
      const bootstrapBtn = document.getElementById('trpg-bootstrap-btn');
      if (bootstrapBtn) {
        bootstrapBtn.disabled = trpgRoundRunning || trpgBootstrapping || trpgActorMutating;
        bootstrapBtn.textContent = trpgBootstrapping ? '시작 준비 중...' : '1) 세션 시작';
      }
      const newGameBtn = document.getElementById('trpg-new-game-btn');
      if (newGameBtn) {
        newGameBtn.disabled = trpgRoundRunning || trpgBootstrapping || trpgActorMutating;
      }
      const reloadBtn = document.getElementById('trpg-reload-btn');
      if (reloadBtn) {
        reloadBtn.disabled = trpgRoundRunning || trpgBootstrapping || trpgActorMutating;
      }
      const autoBtn = document.getElementById('trpg-auto-round-btn');
      if (autoBtn) {
        autoBtn.disabled = trpgBootstrapping || trpgActorMutating;
        autoBtn.textContent = trpgAutoRoundEnabled ? '3) 자동 진행 OFF' : '3) 자동 진행 ON';
        autoBtn.title = trpgAutoRoundEnabled ? '자동 라운드 실행 중입니다. 클릭하면 중지합니다.' : '라운드 자동 진행을 시작합니다.';
      }
      const actorSpawnBtn = document.getElementById('trpg-actor-spawn-btn');
      if (actorSpawnBtn) {
        actorSpawnBtn.disabled = trpgRoundRunning || trpgBootstrapping || trpgActorMutating;
        actorSpawnBtn.textContent = trpgActorMutating ? '처리 중...' : '액터 생성';
      }
      const actorUpdateBtn = document.getElementById('trpg-actor-update-btn');
      if (actorUpdateBtn) {
        actorUpdateBtn.disabled = trpgRoundRunning || trpgBootstrapping || trpgActorMutating;
        actorUpdateBtn.textContent = trpgActorMutating ? '처리 중...' : '액터 수정';
      }
      const actorDeleteBtn = document.getElementById('trpg-actor-delete-btn');
      if (actorDeleteBtn) {
        actorDeleteBtn.disabled = trpgRoundRunning || trpgBootstrapping || trpgActorMutating;
        actorDeleteBtn.textContent = trpgActorMutating ? '처리 중...' : '액터 삭제';
      }
      ['trpg-phase-briefing-btn', 'trpg-phase-round-btn', 'trpg-phase-resolution-btn', 'trpg-phase-ended-btn'].forEach((id) => {
        const btn = document.getElementById(id);
        if (!btn) return;
        btn.disabled = trpgRoundRunning || trpgBootstrapping || trpgActorMutating || !trpgCanRunRound;
      });
      updateTrpgNextActionButton();
      syncTrpgAutoRoundUi();
    }

    function trpgAutoRoundDelaySec() {
      const el = document.getElementById('trpg-auto-round-delay-sec-input');
      const n = Number((el && el.value) || TRPG_AUTO_ROUND_DELAY_DEFAULT_SEC);
      if (!Number.isFinite(n) || n < 1) return TRPG_AUTO_ROUND_DELAY_DEFAULT_SEC;
      return Math.min(600, Math.floor(n));
    }

    function clearTrpgAutoRoundTimer() {
      if (trpgAutoRoundTimer) {
        clearTimeout(trpgAutoRoundTimer);
        trpgAutoRoundTimer = null;
      }
    }

    function syncTrpgAutoRoundUi() {
      const btn = document.getElementById('trpg-auto-round-btn');
      if (btn) {
        btn.classList.toggle('recommend', trpgAutoRoundEnabled && !trpgRoundRunning);
      }
      const delayEl = document.getElementById('trpg-auto-round-delay-sec-input');
      if (delayEl) {
        delayEl.disabled = trpgBootstrapping || trpgActorMutating;
      }
    }

    function setTrpgAutoRoundEnabled(enabled, reason = '') {
      const next = !!enabled;
      if (next === trpgAutoRoundEnabled) return;
      trpgAutoRoundEnabled = next;
      if (!next) {
        clearTrpgAutoRoundTimer();
      }
      updateTrpgButtons();
      if (next) {
        const delay = trpgAutoRoundDelaySec();
        setTrpgRoundRunStatus(
          `자동 진행 시작: ${delay}s 간격으로 라운드를 실행합니다. (room <b>${escapeHtml(trpgRoomId)}</b>)`,
          'running'
        );
        showToast('자동 진행 ON', 'success');
        scheduleTrpgAutoRoundNext('enabled');
      } else {
        if (reason) {
          setTrpgRoundRunStatus(escapeHtml(reason), 'warn');
        }
        showToast('자동 진행 OFF', 'info');
      }
    }

    function toggleTrpgAutoRound() {
      if (trpgAutoRoundEnabled) {
        setTrpgAutoRoundEnabled(false, '자동 진행을 중지했습니다.');
        return;
      }
      if (!trpgCanRunRound) {
        setTrpgRoundRunStatus(`자동 진행 시작 불가: ${escapeHtml(String(trpgRunBlockedReason || '세션 시작 후 다시 시도하세요.'))}`, 'error');
        return;
      }
      setTrpgAutoRoundEnabled(true);
    }

    function scheduleTrpgAutoRoundNext(source = '') {
      if (!trpgAutoRoundEnabled) return;
      clearTrpgAutoRoundTimer();
      const delaySec = trpgAutoRoundDelaySec();
      trpgAutoRoundTimer = setTimeout(async () => {
        trpgAutoRoundTimer = null;
        if (!trpgAutoRoundEnabled) return;
        if (trpgRoundRunning || trpgBootstrapping || trpgActorMutating) {
          scheduleTrpgAutoRoundNext('busy-retry');
          return;
        }
        if (!trpgCanRunRound) {
          setTrpgAutoRoundEnabled(false, `자동 진행 중지: ${String(trpgRunBlockedReason || '라운드를 실행할 수 없는 상태입니다.')}`);
          return;
        }
        await runTrpgRound({ source: `auto:${source}` });
      }, delaySec * 1000);
    }

    function setTrpgRoundRunBusy(isBusy) {
      trpgRoundRunning = isBusy;
      updateTrpgButtons();
      trpgUpdateNextAction(trpgStateCache, trpgEventsCache);
    }

    function setTrpgBootstrapBusy(isBusy) {
      trpgBootstrapping = isBusy;
      updateTrpgButtons();
      trpgUpdateNextAction(trpgStateCache, trpgEventsCache);
    }

    function setTrpgActorMutationBusy(isBusy) {
      trpgActorMutating = !!isBusy;
      updateTrpgButtons();
    }

    function trpgActorTextInput(id) {
      return String((document.getElementById(id) || {}).value || '').trim();
    }

    function trpgActorNumberInput(id) {
      const raw = String((document.getElementById(id) || {}).value || '').trim();
      if (raw === '') return null;
      const n = Number(raw);
      if (!Number.isFinite(n)) return NaN;
      return Math.floor(n);
    }

    function readTrpgActorForm() {
      return {
        roomId: applyTrpgRoomFromInput(),
        actorId: trpgActorTextInput('trpg-actor-id-input'),
        role: trpgActorTextInput('trpg-actor-role-select'),
        name: trpgActorTextInput('trpg-actor-name-input'),
        archetype: trpgActorTextInput('trpg-actor-archetype-input'),
        persona: trpgActorTextInput('trpg-actor-persona-input'),
        keeperName: trpgActorTextInput('trpg-actor-keeper-input'),
        hp: trpgActorNumberInput('trpg-actor-hp-input'),
        maxHp: trpgActorNumberInput('trpg-actor-maxhp-input'),
        traits: parseCommaTextList((document.getElementById('trpg-actor-traits-input') || {}).value || ''),
        skills: parseCommaTextList((document.getElementById('trpg-actor-skills-input') || {}).value || ''),
        inventory: parseCommaTextList((document.getElementById('trpg-actor-inventory-input') || {}).value || ''),
        deleteReason: trpgActorTextInput('trpg-actor-delete-reason-input'),
      };
    }

    function upsertTrpgPlayerKeeperLine(actorId, keeperName) {
      const input = document.getElementById('trpg-player-keepers-input');
      if (!input) return;
      const actor = String(actorId || '').trim();
      const keeper = String(keeperName || '').trim();
      if (!actor || !keeper) return;
      const rows = String(input.value || '')
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter((line) => line !== '');
      const nextRows = [];
      for (const row of rows) {
        const eqIdx = row.indexOf('=');
        const left = eqIdx < 0 ? row : row.slice(0, eqIdx).trim();
        if (left === actor) continue;
        nextRows.push(row);
      }
      nextRows.push(`${actor}=${keeper}`);
      input.value = nextRows.join('\n');
      trpgSyncKeeperSelectorsFromInputs();
    }

    function removeTrpgPlayerKeeperLine(actorId) {
      const input = document.getElementById('trpg-player-keepers-input');
      if (!input) return;
      const actor = String(actorId || '').trim();
      if (!actor) return;
      const rows = String(input.value || '')
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter((line) => line !== '');
      const nextRows = rows.filter((row) => {
        const eqIdx = row.indexOf('=');
        const left = eqIdx < 0 ? row : row.slice(0, eqIdx).trim();
        return left !== actor;
      });
      input.value = nextRows.join('\n');
      trpgSyncKeeperSelectorsFromInputs();
    }

    async function spawnTrpgActor() {
      if (trpgRoundRunning || trpgBootstrapping || trpgActorMutating) return;
      ensureTrpgControlDefaults();
      const form = readTrpgActorForm();
      if (!form.actorId) {
        setTrpgStatusBoth('오류: Actor ID를 입력하세요.', 'error');
        return;
      }
      const maxHp = form.maxHp == null ? 10 : form.maxHp;
      const hpRaw = form.hp == null ? maxHp : form.hp;
      if (!Number.isFinite(maxHp) || maxHp <= 0) {
        setTrpgStatusBoth('오류: Max HP는 1 이상이어야 합니다.', 'error');
        return;
      }
      if (!Number.isFinite(hpRaw) || hpRaw < 0) {
        setTrpgStatusBoth('오류: HP는 0 이상이어야 합니다.', 'error');
        return;
      }
      const hp = Math.max(0, Math.min(maxHp, hpRaw));
      const role = form.role || 'player';
      const spawnArgs = {
        room_id: form.roomId,
        actor_id: form.actorId,
        role,
        hp,
        max_hp: maxHp,
        alive: hp > 0,
      };
      if (form.name) spawnArgs.name = form.name;
      if (form.archetype) spawnArgs.archetype = form.archetype;
      if (form.persona) spawnArgs.persona = form.persona;
      if (form.traits.length > 0) spawnArgs.traits = form.traits;
      if (form.skills.length > 0) spawnArgs.skills = form.skills;
      if (form.inventory.length > 0) spawnArgs.inventory = form.inventory;

      setTrpgActorMutationBusy(true);
      setTrpgStatusBoth(
        `액터 생성 중: <b>${escapeHtml(form.actorId)}</b> (${escapeHtml(role)}) / room <b>${escapeHtml(form.roomId)}</b>`,
        'running'
      );
      try {
        await mcpToolCall('trpg.actor.spawn', spawnArgs);
        if (form.keeperName) {
          await trpgActorClaimCall({
            room_id: form.roomId,
            actor_id: form.actorId,
            keeper_name: form.keeperName,
          });
          if (role === 'player') {
            upsertTrpgPlayerKeeperLine(form.actorId, form.keeperName);
          }
        }
        setTrpgStatusBoth(
          `액터 생성 완료: <b>${escapeHtml(form.actorId)}</b>${form.keeperName ? ` → keeper <b>${escapeHtml(form.keeperName)}</b>` : ''}`,
          'ok'
        );
        showToast(`Actor 생성 완료: ${form.actorId}`, 'success');
        await fetchTrpg();
      } catch (e) {
        const msg = String((e && e.message) || e || 'unknown error');
        setTrpgStatusBoth(`액터 생성 실패: ${escapeHtml(msg)}`, 'error');
        showToast('Actor 생성 실패', 'error');
      } finally {
        setTrpgActorMutationBusy(false);
      }
    }

    async function updateTrpgActor() {
      if (trpgRoundRunning || trpgBootstrapping || trpgActorMutating) return;
      ensureTrpgControlDefaults();
      const form = readTrpgActorForm();
      if (!form.actorId) {
        setTrpgStatusBoth('오류: 수정할 Actor ID를 입력하세요.', 'error');
        return;
      }
      const updateArgs = { room_id: form.roomId, actor_id: form.actorId };
      let hasPatch = false;
      if (form.role) { updateArgs.role = form.role; hasPatch = true; }
      if (form.name) { updateArgs.name = form.name; hasPatch = true; }
      if (form.archetype) { updateArgs.archetype = form.archetype; hasPatch = true; }
      if (form.persona) { updateArgs.persona = form.persona; hasPatch = true; }
      if (form.hp != null) {
        if (!Number.isFinite(form.hp) || form.hp < 0) {
          setTrpgStatusBoth('오류: HP는 0 이상이어야 합니다.', 'error');
          return;
        }
        updateArgs.hp = form.hp;
        updateArgs.alive = form.hp > 0;
        hasPatch = true;
      }
      if (form.maxHp != null) {
        if (!Number.isFinite(form.maxHp) || form.maxHp <= 0) {
          setTrpgStatusBoth('오류: Max HP는 1 이상이어야 합니다.', 'error');
          return;
        }
        updateArgs.max_hp = form.maxHp;
        hasPatch = true;
      }
      if (form.traits.length > 0) { updateArgs.traits = form.traits; hasPatch = true; }
      if (form.skills.length > 0) { updateArgs.skills = form.skills; hasPatch = true; }
      if (form.inventory.length > 0) { updateArgs.inventory = form.inventory; hasPatch = true; }
      const hasKeeperClaim = form.keeperName !== '';
      if (!hasPatch && !hasKeeperClaim) {
        setTrpgStatusBoth('오류: 수정할 필드를 최소 1개 이상 입력하거나 keeper를 지정하세요.', 'error');
        return;
      }

      setTrpgActorMutationBusy(true);
      setTrpgStatusBoth(
        `액터 수정 중: <b>${escapeHtml(form.actorId)}</b> / room <b>${escapeHtml(form.roomId)}</b>`,
        'running'
      );
      try {
        if (hasPatch) {
          await mcpToolCall('trpg.actor.update', updateArgs);
        }
        if (hasKeeperClaim) {
          await trpgActorClaimCall({
            room_id: form.roomId,
            actor_id: form.actorId,
            keeper_name: form.keeperName,
          });
          if (form.role === 'player') {
            upsertTrpgPlayerKeeperLine(form.actorId, form.keeperName);
          }
        }
        const updateSummary = hasPatch && hasKeeperClaim
          ? `액터 수정 완료: <b>${escapeHtml(form.actorId)}</b> (속성 + keeper 반영)`
          : hasPatch
            ? `액터 수정 완료: <b>${escapeHtml(form.actorId)}</b>`
            : `액터 keeper 할당 완료: <b>${escapeHtml(form.actorId)}</b> → <b>${escapeHtml(form.keeperName)}</b>`;
        setTrpgStatusBoth(updateSummary, 'ok');
        showToast(`Actor 수정 완료: ${form.actorId}`, 'success');
        await fetchTrpg();
      } catch (e) {
        const msg = String((e && e.message) || e || 'unknown error');
        setTrpgStatusBoth(`액터 수정 실패: ${escapeHtml(msg)}`, 'error');
        showToast('Actor 수정 실패', 'error');
      } finally {
        setTrpgActorMutationBusy(false);
      }
    }

    async function deleteTrpgActor() {
      if (trpgRoundRunning || trpgBootstrapping || trpgActorMutating) return;
      ensureTrpgControlDefaults();
      const form = readTrpgActorForm();
      if (!form.actorId) {
        setTrpgStatusBoth('오류: 삭제할 Actor ID를 입력하세요.', 'error');
        return;
      }
      const confirmed = window.confirm(`actor ${form.actorId} 를 삭제하시겠습니까?`);
      if (!confirmed) return;
      const deleteArgs = { room_id: form.roomId, actor_id: form.actorId };
      if (form.deleteReason) deleteArgs.reason = form.deleteReason;

      setTrpgActorMutationBusy(true);
      setTrpgStatusBoth(
        `액터 삭제 중: <b>${escapeHtml(form.actorId)}</b> / room <b>${escapeHtml(form.roomId)}</b>`,
        'running'
      );
      try {
        await mcpToolCall('trpg.actor.delete', deleteArgs);
        removeTrpgPlayerKeeperLine(form.actorId);
        setTrpgStatusBoth(`액터 삭제 완료: <b>${escapeHtml(form.actorId)}</b>`, 'ok');
        showToast(`Actor 삭제 완료: ${form.actorId}`, 'success');
        await fetchTrpg();
      } catch (e) {
        const msg = String((e && e.message) || e || 'unknown error');
        setTrpgStatusBoth(`액터 삭제 실패: ${escapeHtml(msg)}`, 'error');
        showToast('Actor 삭제 실패', 'error');
      } finally {
        setTrpgActorMutationBusy(false);
      }
    }

    function trpgKeeperLanguageInstruction(lang) {
      if (lang === 'ko') {
        return '모든 응답은 한국어로 작성하세요. 구조화된 action이 있으면 reply에 함께 담아주세요.';
      }
      return 'Respond in English. If you have structured actions, include them in your reply.';
    }

    function trpgDmGoalText(lang, roomId, worldPresetTitle) {
      if (lang === 'ko') {
        return `TRPG room ${roomId}의 세계관 주민인 DM Keeper로 ${worldPresetTitle} 시나리오를 진행하세요. 메타 설명을 피하고 인월드 관점으로 장면 연속성과 규칙 일관성을 유지하세요.`;
      }
      return `Act as an in-world DM Keeper for TRPG room ${roomId} in ${worldPresetTitle}. Avoid out-of-world meta narration, keep scene continuity, and enforce rules consistently.`;
    }

    function trpgPlayerGoalText(lang, roomId, actorId) {
      if (lang === 'ko') {
        return `TRPG room ${roomId}에서 ${actorId} 역할을 플레이하세요. 각 라운드마다 간결하고 일관된 인캐릭터 행동을 제출하세요.`;
      }
      return `Play actor ${actorId} in TRPG room ${roomId}. Submit concise in-character actions each round.`;
    }

    async function bootstrapTrpgSession() {
      if (trpgRoundRunning || trpgBootstrapping || trpgActorMutating) return;
      ensureTrpgControlDefaults();
      trpgApplyKeeperSelectionToInputs();
      const roomId = applyTrpgRoomFromInput();
      const lang = trpgLanguageFromSelect();
      let runRoundAfterBootstrap = false;
      setTrpgBootstrapBusy(true);
      setTrpgRoundRunStatus(`세션 시작 중: room <b>${escapeHtml(roomId)}</b>`, 'running');
      try {
        const catalog = await ensureTrpgPresetCatalog(false);
        const worldPresetId =
          selectedTrpgPresetId('trpg-world-preset-select')
          || String((((catalog || {}).world_presets || [])[0] || {}).id || '');
        const dmPresetId =
          selectedTrpgPresetId('trpg-dm-preset-select')
          || String((((catalog || {}).dm_presets || [])[0] || {}).id || '');
        if (!worldPresetId || !dmPresetId) {
          throw new Error('preset 목록이 비어 있습니다.');
        }

        const poolSizeRaw = Number((document.getElementById('trpg-pool-size-input') || {}).value);
        const partySizeRaw = Number((document.getElementById('trpg-party-size-input') || {}).value);
        const poolSize = Number.isFinite(poolSizeRaw)
          ? Math.max(2, Math.min(16, Math.floor(poolSizeRaw)))
          : TRPG_DEFAULT_POOL_SIZE;
        const partySize = Number.isFinite(partySizeRaw)
          ? Math.max(1, Math.min(8, Math.floor(partySizeRaw)))
          : TRPG_DEFAULT_PARTY_SIZE;
        if (partySize > poolSize) {
          throw new Error('party size는 pool size보다 클 수 없습니다.');
        }
        const requestedDmKeeper =
          String((document.getElementById('trpg-dm-keeper-input') || {}).value || '').trim();
        const requestedPlayerRaw =
          String((document.getElementById('trpg-player-keepers-input') || {}).value || '');
        const requestedPlayerTrimmed = requestedPlayerRaw.trim();
        const parsedRequestedPlayers = requestedPlayerTrimmed
          ? parseTrpgPlayerKeepers(requestedPlayerRaw)
          : { ok: true, mapping: {} };
        if (!parsedRequestedPlayers.ok) {
          throw new Error(parsedRequestedPlayers.error || '잘못된 player keeper 입력입니다.');
        }

        const sessionId = `dashboard-${roomId}-${Date.now()}`;
        const seed = Math.floor(Date.now() % 100000);
        const poolResult = await mcpToolCall('trpg.pool.generate', {
          session_id: sessionId,
          world_preset_id: worldPresetId,
          dm_preset_id: dmPresetId,
          pool_size: poolSize,
          party_size: partySize,
          seed,
        });
        const pool = Array.isArray(poolResult.pool) ? poolResult.pool : [];
        if (pool.length === 0) throw new Error('pool 생성 결과가 비어 있습니다.');
        let selectedIds = Array.isArray(poolResult.suggested_party_ids)
          ? poolResult.suggested_party_ids.map((id) => String(id || '').trim()).filter((id) => id !== '')
          : [];
        if (selectedIds.length === 0) {
          selectedIds = pool
            .slice(0, partySize)
            .map((member) => String((member && member.actor_id) || '').trim())
            .filter((id) => id !== '');
        }
        if (selectedIds.length === 0) {
          throw new Error('party 후보를 선택하지 못했습니다.');
        }
        const partyResult = await mcpToolCall('trpg.party.select', {
          session_id: sessionId,
          room_id: roomId,
          pool,
          selected_player_ids: selectedIds,
        });
        const party = Array.isArray(partyResult.party) ? partyResult.party : [];
        const startResult = await mcpToolCall('trpg.session.start', {
          session_id: sessionId,
          room_id: roomId,
          dm_preset_id: dmPresetId,
          world_preset_id: worldPresetId,
          party,
          phase: 'briefing',
          force: true,
        });

        const template =
          (startResult.round_run_template && typeof startResult.round_run_template === 'object' && !Array.isArray(startResult.round_run_template))
            ? startResult.round_run_template
            : {};
        const dmKeeper =
          requestedDmKeeper
          || String(template.dm_keeper || startResult.dm_keeper || 'dm-keeper').trim()
          || 'dm-keeper';
        const playerMapRaw =
          (template.player_keepers && typeof template.player_keepers === 'object' && !Array.isArray(template.player_keepers))
            ? template.player_keepers
            : {};
        const partyActorIds = (Array.isArray(party) ? party : [])
          .map((member) => String((member && member.actor_id) || '').trim())
          .filter((id) => id !== '');
        const templateActorIds = Object.keys(playerMapRaw)
          .map((actorId) => String(actorId || '').trim())
          .filter((id) => id !== '');
        const actorIds = trpgUniqueStrings(partyActorIds.length > 0 ? partyActorIds : templateActorIds);
        if (actorIds.length === 0) {
          throw new Error('세션 파티 actor_id를 확인하지 못했습니다.');
        }

        const assigned = trpgBuildActorKeeperPairs(
          actorIds,
          dmKeeper,
          parsedRequestedPlayers.mapping || {},
          playerMapRaw,
        );
        if (!assigned.ok) {
          throw new Error(assigned.error || 'player keeper 할당 실패');
        }
        const playerMap = assigned.mapping || {};
        const playerLines = playerKeeperMapToText(playerMap);
        const phase = String(template.phase || 'round').trim() || 'round';

        const dmInput = document.getElementById('trpg-dm-keeper-input');
        if (dmInput) dmInput.value = dmKeeper;
        const playerInput = document.getElementById('trpg-player-keepers-input');
        if (playerInput) playerInput.value = playerLines;
        const phaseSelect = document.getElementById('trpg-phase-select');
        if (phaseSelect) phaseSelect.value = phase;
        trpgSyncKeeperSelectorsFromInputs();

        try {
          await ensureTrpgKeeperCatalog(true);
        } catch (_) {
          renderTrpgKeeperQuickList();
        }

        resetTrpgEventWindow();
        const seedEvents = Array.isArray(startResult.events) ? startResult.events : [];
        const maxSeq = seedEvents.reduce((acc, ev) => Math.max(acc, Number((ev && ev.seq) || 0)), 0);
        if (maxSeq > 0) trpgLastSeq = maxSeq;
        const worldPresetLabel =
          (((catalog || {}).world_presets || []).find((preset) => String((preset && preset.id) || '') === worldPresetId) || {}).title
          || worldPresetId;
        await fetchTrpg();

        const modelsRaw = String((document.getElementById('trpg-keeper-models-input') || {}).value || '');
        const models = parseKeeperModels(modelsRaw);
        const keeperProvisionWarnings = [];
        if (models.length > 0) {
          const worldPresetTitle =
            (((catalog || {}).world_presets || []).find((preset) => String((preset && preset.id) || '') === worldPresetId) || {}).title
            || worldPresetId;
          const dmInstruction = trpgKeeperLanguageInstruction(lang);
          try {
            await mcpToolCall('masc_keeper_up', {
              name: dmKeeper,
              goal: trpgDmGoalText(lang, roomId, worldPresetTitle),
              models,
              instructions: dmInstruction,
              proactive_enabled: false,
              presence_keepalive: true,
            });
          } catch (e) {
            const msg = String((e && e.message) || e || 'unknown error');
            keeperProvisionWarnings.push(`DM ${dmKeeper}: ${msg}`);
          }
          const keeperPairs = Object.entries(playerMap)
            .map(([actorId, keeperName]) => [String(actorId || '').trim(), String(keeperName || '').trim()])
            .filter(([actorId, keeperName]) => actorId !== '' && keeperName !== '');
          for (const [actorId, keeperName] of keeperPairs) {
            try {
              await mcpToolCall('masc_keeper_up', {
                name: keeperName,
                goal: trpgPlayerGoalText(lang, roomId, actorId),
                models,
                instructions: trpgKeeperLanguageInstruction(lang),
                proactive_enabled: false,
                presence_keepalive: true,
              });
            } catch (e) {
              const msg = String((e && e.message) || e || 'unknown error');
              keeperProvisionWarnings.push(`${actorId}/${keeperName}: ${msg}`);
            }
          }
        }
        try {
          await ensureTrpgKeeperCatalog(true);
        } catch (_) {
          renderTrpgKeeperQuickList();
        }

        const baseStatusHtml =
          `세션 시작 완료: <b>${escapeHtml(worldPresetLabel)}</b> / room <b>${escapeHtml(roomId)}</b><br>` +
          `DM <b>${escapeHtml(dmKeeper)}</b> + 플레이어 <b>${escapeHtml(String(Object.keys(playerMap).length || party.length))}</b>명 준비됨`;
        if (keeperProvisionWarnings.length > 0) {
          const warningText = keeperProvisionWarnings
            .slice(0, 3)
            .map((msg) => escapeHtml(trpgShortText(msg, 160)))
            .join('<br>');
          const moreCount = Math.max(0, keeperProvisionWarnings.length - 3);
          const moreText = moreCount > 0 ? `<br>… 외 ${moreCount}건` : '';
          setTrpgRoundRunStatus(
            `${baseStatusHtml}<br><span style="color:#fbbf24;">Keeper 준비 경고</span><br>${warningText}${moreText}`,
            'warn'
          );
          showToast('세션은 시작됨 (Keeper 일부 준비 실패)', 'warning');
        } else {
          setTrpgRoundRunStatus(baseStatusHtml, 'ok');
          showToast(`TRPG session ready (${roomId})`, 'success');
        }
        const autoRoundEl = document.getElementById('trpg-bootstrap-run-round1');
        runRoundAfterBootstrap = !!(autoRoundEl && autoRoundEl.checked);
      } catch (e) {
        const msg = String((e && e.message) || e || 'unknown error');
        setTrpgRoundRunStatus(`세션 시작 실패: ${escapeHtml(msg)}`, 'error');
        showToast('TRPG session bootstrap 실패', 'error');
      } finally {
        setTrpgBootstrapBusy(false);
        if (runRoundAfterBootstrap) {
          setTimeout(() => { runTrpgRound(); }, 100);
        }
      }
    }

    function parseTrpgPlayerKeepers(rawText) {
      const lines = String(rawText || '')
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter((line) => line !== '');
      const mapping = {};
      const keeperOwners = {};
      for (const line of lines) {
        const eqIdx = line.indexOf('=');
        let actorId = '';
        let keeperName = '';
        if (eqIdx < 0) {
          actorId = line;
          keeperName = line;
        } else {
          if (eqIdx <= 0 || eqIdx === line.length - 1) {
            return { ok: false, error: `잘못된 player keeper 형식: ${line}` };
          }
          actorId = line.slice(0, eqIdx).trim();
          keeperName = line.slice(eqIdx + 1).trim();
        }
        if (!actorId || !keeperName) {
          return { ok: false, error: `actor/keeper 값이 비어 있습니다: ${line}` };
        }
        if (Object.prototype.hasOwnProperty.call(mapping, actorId)) {
          return { ok: false, error: `중복 actor_id 입니다: ${actorId}` };
        }
        if (Object.prototype.hasOwnProperty.call(keeperOwners, keeperName)) {
          return {
            ok: false,
            error: `중복 keeper 입니다: ${keeperName} (actor ${keeperOwners[keeperName]} / ${actorId})`,
          };
        }
        keeperOwners[keeperName] = actorId;
        mapping[actorId] = keeperName;
      }
      if (Object.keys(mapping).length === 0) {
        return { ok: false, error: '최소 1명의 player keeper가 필요합니다.' };
      }
      return { ok: true, mapping };
    }

    function trpgShortText(raw, maxLen = 120) {
      const text = trpgNormalizeDisplayText(raw).replace(/\s+/g, ' ').trim();
      if (text.length <= maxLen) return text;
      return text.slice(0, Math.max(0, maxLen - 1)) + '…';
    }

    function setTrpgRoundRunStatus(html, cls = '') {
      const statusEl = document.getElementById('trpg-round-run-status');
      if (!statusEl) return;
      statusEl.className = `trpg-run-status ${cls}`.trim();
      statusEl.innerHTML = html;
    }

    function setTrpgActorRunStatus(html, cls = '') {
      const statusEl = document.getElementById('trpg-actor-run-status');
      if (!statusEl) return;
      statusEl.className = `trpg-run-status ${cls}`.trim();
      statusEl.innerHTML = html;
    }

    function setTrpgStatusBoth(html, cls = '') {
      setTrpgRoundRunStatus(html, cls);
      setTrpgActorRunStatus(html, cls);
    }

    async function runTrpgRound(options = {}) {
      const runSource = String((options && options.source) || 'manual');
      const isAutoRun = runSource.startsWith('auto:') || runSource === 'auto';
      if (trpgRoundRunning || trpgBootstrapping || trpgActorMutating) return;
      if (!trpgCanRunRound) {
        setTrpgRoundRunStatus(`실행 전 점검: ${escapeHtml(String(trpgRunBlockedReason || '세션/할당 상태를 먼저 확인하세요.'))}`, 'error');
        if (isAutoRun && trpgAutoRoundEnabled) {
          setTrpgAutoRoundEnabled(false, `자동 진행 중지: ${String(trpgRunBlockedReason || '실행 조건을 확인하세요.')}`);
        }
        return;
      }
      ensureTrpgControlDefaults();
      const roomId = applyTrpgRoomFromInput();
      const dmKeeper = String((document.getElementById('trpg-dm-keeper-input') || {}).value || '').trim();
      const phaseOverride = String((options && options.phase) || '').trim();
      const phase = phaseOverride || String((document.getElementById('trpg-phase-select') || {}).value || 'round').trim() || 'round';
      if (phaseOverride) setTrpgPhaseSelection(phaseOverride);
      const lang = trpgLanguageFromSelect();
      const timeoutRaw = Number((document.getElementById('trpg-timeout-sec-input') || {}).value);
      const timeoutSec = Number.isFinite(timeoutRaw) && timeoutRaw > 0 ? timeoutRaw : 90;
      const playerRaw = String((document.getElementById('trpg-player-keepers-input') || {}).value || '');
      if (!dmKeeper) {
        setTrpgRoundRunStatus('오류: DM keeper를 입력하세요.', 'error');
        return;
      }
      const parsedPlayers = parseTrpgPlayerKeepers(playerRaw);
      if (!parsedPlayers.ok) {
        setTrpgRoundRunStatus('오류: ' + escapeHtml(parsedPlayers.error || 'invalid player_keepers'), 'error');
        return;
      }
      const sessionEvents = trpgCurrentSessionEvents(trpgEventsCache);
      const resolvedPlayers = trpgResolvePlayerKeeperMapping(trpgStateCache, sessionEvents, playerRaw);
      if (!resolvedPlayers.ok) {
        setTrpgRoundRunStatus('오류: ' + escapeHtml(resolvedPlayers.error || 'invalid player_keepers'), 'error');
        return;
      }
      const playerMapping = resolvedPlayers.mapping || parsedPlayers.mapping || {};
      const playerKeeperNames = Object.values(playerMapping || {})
        .map((name) => String(name || '').trim())
        .filter((name) => name !== '');
      if (playerKeeperNames.includes(dmKeeper)) {
        setTrpgRoundRunStatus(
          `오류: DM keeper <b>${escapeHtml(dmKeeper)}</b>가 player keeper와 중복됩니다. keeper는 모두 유일해야 합니다.`,
          'error'
        );
        return;
      }
      const expectedActors = resolvedPlayers.expectedActors || [];
      if (expectedActors.length > 0) {
        const unknownActors = resolvedPlayers.unknownActors || [];
        const missingActors = resolvedPlayers.missingActors || [];
        if (resolvedPlayers.renamed && resolvedPlayers.renamed.length > 0) {
          const playerInput = document.getElementById('trpg-player-keepers-input');
          if (playerInput) {
            playerInput.value = playerKeeperMapToText(playerMapping);
            trpgSyncKeeperSelectorsFromInputs();
          }
        }
        if (missingActors.length > 0) {
          const unknownText = unknownActors.length > 0 ? `입력만 존재: ${unknownActors.join(', ')}` : '-';
          const missingText = missingActors.length > 0 ? `누락: ${missingActors.join(', ')}` : '-';
          setTrpgRoundRunStatus(
            `오류: player keepers actor_id가 현재 파티와 일치하지 않습니다.<br>` +
            `현재 파티 actor: <b>${escapeHtml(expectedActors.join(', '))}</b><br>` +
            `${escapeHtml(unknownText)} / ${escapeHtml(missingText)}`,
            'error'
          );
          return;
        }
        if (unknownActors.length > 0) {
          const unknownText = trpgShortText(unknownActors.join(', '), 120);
          const playerInput = document.getElementById('trpg-player-keepers-input');
          if (playerInput) {
            playerInput.value = playerKeeperMapToText(playerMapping);
            trpgSyncKeeperSelectorsFromInputs();
          }
          setTrpgRoundRunStatus(
            `라운드 실행: 파티 외 actor 입력은 무시됩니다. (${escapeHtml(unknownText)})`,
            'running'
          );
        }
      }

      if ((resolvedPlayers.renamed || []).length > 0) {
        const playerInput = document.getElementById('trpg-player-keepers-input');
        if (playerInput) {
          playerInput.value = playerKeeperMapToText(playerMapping);
          trpgSyncKeeperSelectorsFromInputs();
        }
      }

      const participantCount = 1 + Object.keys(playerMapping || {}).length;
      const estimatedMaxSec = Math.max(1, Math.ceil(timeoutSec * participantCount));
      let roundDone = false;
      let pollInFlight = false;
      const startedAtMs = Date.now();

      setTrpgRoundRunBusy(true);
      setTrpgRoundRunStatus(
        `실행 중: room <b>${escapeHtml(roomId)}</b>, phase <b>${escapeHtml(phase)}</b>, 언어 <b>${escapeHtml(lang)}</b><br>` +
        `참여자 <b>${participantCount}명</b>, 최대 약 <b>${estimatedMaxSec}s</b> (순차 실행 기준)`,
        'running'
      );
      try { await fetchTrpg(); } catch (_) {}
      const livePollId = setInterval(async () => {
        if (roundDone || pollInFlight) return;
        pollInFlight = true;
        try {
          const elapsedSec = Math.max(0, Math.floor((Date.now() - startedAtMs) / 1000));
          setTrpgRoundRunStatus(
            `실행 중: room <b>${escapeHtml(roomId)}</b>, phase <b>${escapeHtml(phase)}</b>, 언어 <b>${escapeHtml(lang)}</b><br>` +
            `경과 <b>${elapsedSec}s</b> / 예상 최대 <b>${estimatedMaxSec}s</b>`,
            'running'
          );
          await fetchTrpg();
        } catch (_) {
          // ignore polling errors while round run request is in-flight
        } finally {
          pollInFlight = false;
        }
      }, 2500);

      try {
        const headers = Object.assign({ 'Content-Type': 'application/json' }, authHeaders());
        const body = {
          room_id: roomId,
          dm_keeper: dmKeeper,
          player_keepers: playerMapping,
          phase,
          timeout_sec: timeoutSec,
          lang,
        };
        const res = await fetch('/api/v1/trpg/rounds/run', {
          method: 'POST',
          headers,
          body: JSON.stringify(body),
        });
        let data = {};
        try { data = await res.json(); } catch (_) {}
        if (!res.ok || data.ok === false) {
          const msg = data.error || data.message || `HTTP ${res.status}`;
          throw new Error(String(msg));
        }
        const summary = (data && typeof data.summary === 'object' && data.summary) ? data.summary : {};
        const statuses = Array.isArray(data.statuses) ? data.statuses : [];
        const statusRows = statuses.slice(0, 5).map((st) => {
          const actor = escapeHtml(String(st.actor_id || '-'));
          const keeper = escapeHtml(String(st.keeper || '-'));
          const status = escapeHtml(String(st.status || '-'));
          const detail = st.reply || st.error || '';
          return `<div>• ${actor} (${keeper}) <b>${status}</b>${detail ? ` — ${escapeHtml(trpgShortText(detail))}` : ''}</div>`;
        }).join('');
        roundDone = true;
        setTrpgRoundRunStatus(
          `<div>완료: turn ${escapeHtml(String(data.turn_before || '-'))} → <b>${escapeHtml(String(data.turn_after || '-'))}</b></div>
           <div>요약: success ${escapeHtml(String(summary.successes || 0))}, timeout ${escapeHtml(String(summary.timeouts || 0))}, unavailable ${escapeHtml(String(summary.unavailable || 0))}</div>
           ${statusRows || '<div>상태 로그 없음</div>'}`,
          'ok'
        );
        if (!isAutoRun) {
          showToast(`TRPG round 완료 (room=${roomId})`, 'success');
        }
        await fetchTrpg();
        if (trpgAutoRoundEnabled) {
          scheduleTrpgAutoRoundNext('round-complete');
        }
      } catch (e) {
        roundDone = true;
        setTrpgRoundRunStatus(`실패: ${escapeHtml(String((e && e.message) || e || 'unknown error'))}`, 'error');
        showToast('TRPG round 실행 실패', 'error');
        if (trpgAutoRoundEnabled) {
          setTrpgAutoRoundEnabled(false, '자동 진행 중지: 라운드 실행 실패');
        }
      } finally {
        clearInterval(livePollId);
        setTrpgRoundRunBusy(false);
      }
    }

    async function fetchTrpg() {
      ensureTrpgControlDefaults();
      updateTrpgButtons();
      if (!trpgPresetsLoaded) {
        try {
          await ensureTrpgPresetCatalog(false);
        } catch (_) {
          // Keep UI usable even if preset loading fails.
        }
      }
      if (!trpgKeepersLoaded) {
        try {
          await ensureTrpgKeeperCatalog(false);
        } catch (_) {
          renderTrpgKeeperQuickList();
        }
      }
      const activeRoomId = trpgRoomId;
      const roomLabel = document.getElementById('trpg-room-label');
      if (roomLabel) roomLabel.textContent = `room: ${activeRoomId}`;

      try {
        const eventsReq = fetch(
          `/api/v1/trpg/events?room_id=${encodeURIComponent(activeRoomId)}&after_seq=${trpgLastSeq}`,
          { headers: authHeaders() }
        )
          .then(r => r.json())
          .catch(() => ({ events: [] }));
        const stateReq = fetch(
          `/api/v1/trpg/state?room_id=${encodeURIComponent(activeRoomId)}`,
          { headers: authHeaders() }
        )
          .then(r => r.json())
          .catch(() => ({ state: {} }));

        const [eventsData, stateData] = await Promise.all([eventsReq, stateReq]);
        const incomingEvents = Array.isArray(eventsData.events) ? eventsData.events : [];
        if (incomingEvents.length > 0) {
          trpgEventsCache = trpgEventsCache.concat(incomingEvents);
          trpgEventsCache.sort((a, b) => (Number(a.seq) || 0) - (Number(b.seq) || 0));
          if (trpgEventsCache.length > 400) trpgEventsCache = trpgEventsCache.slice(-400);
          trpgLastSeq = Math.max(
            trpgLastSeq,
            ...incomingEvents.map(e => Number(e.seq) || 0)
          );
        }

        trpgStateCache =
          stateData && stateData.state && typeof stateData.state === 'object' && !Array.isArray(stateData.state)
            ? stateData.state
            : {};
        renderTrpgNarrative(trpgEventsCache);
        renderTrpgState(trpgStateCache, trpgEventsCache);
      } catch (_) {}
      trpgUpdateNextAction(trpgStateCache, trpgEventsCache);
      if (trpgAutoRoundEnabled && !trpgRoundRunning && !trpgBootstrapping && !trpgActorMutating && !trpgCanRunRound) {
        setTrpgAutoRoundEnabled(false, `자동 진행 중지: ${String(trpgRunBlockedReason || '세션 상태를 확인하세요.')}`);
      }
    }

    function trpgNormalizeDisplayText(raw) {
      return String(raw || '')
        .replace(/\uFEFF/g, '')
        .replace(/\uFFFD/g, '')
        .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, '');
    }

    function trpgSanitizeNarrative(raw) {
      let text = trpgNormalizeDisplayText(raw).replace(/\r\n/g, '\n');
      text = text.replace(/^SKILL:.*$/gmi, '');
      text = text.replace(/^SKILL_REASON:.*$/gmi, '');
      text = text.replace(/```[\s\S]*?```/g, '');
      text = text.replace(/\[STATE\][\s\S]*?\[\/STATE\]/gmi, '');
      text = text.replace(/\n{3,}/g, '\n\n').trim();
      if (text !== '') return text;
      return trpgNormalizeDisplayText(raw).replace(/\n{3,}/g, '\n\n').trim();
    }

    function renderTrpgNarrative(events) {
      const el = document.getElementById('trpg-narrative');
      if (!el) return;
      const sourceEvents = trpgCurrentSessionEvents(events);
      const narrations = sourceEvents
        .filter((ev) => trpgEventType(ev) === 'narration.posted')
        .sort((a, b) => (Number(a.seq) || 0) - (Number(b.seq) || 0))
        .slice(-80);
      if (!narrations.length) {
        const historyCount = trpgBuildSessionHistory(Array.isArray(events) ? events : []).length;
        const hiddenText = (!trpgIncludePastSessions && historyCount > 1)
          ? `<div class="trpg-control-help" style="margin-top:8px;">이전 ${historyCount - 1}개 세션 로그는 숨겨져 있습니다. "이전 세션 로그 포함 보기"를 켜면 확인할 수 있습니다.</div>`
          : '';
        el.innerHTML = `<div class="trpg-empty">아직 서사가 없습니다. 1) 세션 시작 후 2) 라운드를 실행하세요.</div>${hiddenText}`;
        return;
      }
      let html = '';
      let newIdx = -1;
      narrations.forEach((ev, idx) => {
        const payload = trpgEventPayload(ev);
        const id = `narr-${Number(ev.seq) || idx}`;
        const isNew = !trpgKnownIds.has(id);
        if (isNew) { trpgKnownIds.add(id); newIdx = idx; }
        const turn = Number(payload.turn);
        const turnLabel = Number.isFinite(turn) ? `turn ${turn}` : 'turn -';
        const keeper = payload.keeper || ev.actor_id || 'dm';
        const meta = `${keeper} · ${turnLabel} · ${trpgFmtEventTime(ev)}`;
        const rawText = trpgSanitizeNarrative(payload.reply || '');
        html += '<div class="trpg-post" data-idx="' + idx + '">';
        html += '<div class="trpg-post-meta">' + escapeHtml(meta) + '</div>';
        html += '<div class="trpg-post-body">' + (isNew && !trpgTyping ? '' : formatTrpgContent(rawText)) + '</div>';
        html += '</div>';
      });
      el.innerHTML = html;
      if (newIdx >= 0 && !trpgTyping) {
        const postEl = el.querySelector('[data-idx="' + newIdx + '"]');
        if (postEl) {
          const bodyEl = postEl.querySelector('.trpg-post-body');
          const raw = trpgSanitizeNarrative(trpgEventPayload(narrations[newIdx]).reply || '');
          trpgTypewriter(bodyEl, raw);
        }
      }
      el.scrollTop = el.scrollHeight;
    }

    function formatTrpgContent(text) {
      let s = escapeHtml(text);
      s = s.replace(/🎲\s*d20=(\d+)/g, '<span class="dice-roll">🎲 d20=$1</span>');
      s = s.replace(/(대참사|기적|대성공|부분\s*성공|실패|성공)/g, function(m) {
        if (m === '대참사') return '<span class="result-catastrophe">' + m + '</span>';
        if (m === '기적' || m === '대성공') return '<span class="result-great">' + m + '</span>';
        if (m === '성공' || m.match(/부분/)) return '<span class="result-success">' + m + '</span>';
        return '<span class="result-fail">' + m + '</span>';
      });
      s = s.replace(/(그림자|루나|손가락|미소)/g, '<span class="char-name">$1</span>');
      s = s.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
      s = s.replace(/^&gt;\s*(.+)$/gm, '<blockquote>$1</blockquote>');
      s = s.replace(/\n/g, '<br>');
      return s;
    }

    function trpgTypewriter(bodyEl, text) {
      if (!bodyEl) return;
      trpgTyping = true;
      bodyEl.innerHTML = '<span class="typewriter-cursor"></span>';
      let i = 0;
      function tick() {
        if (i >= text.length) {
          trpgTyping = false;
          bodyEl.innerHTML = formatTrpgContent(text);
          return;
        }
        const ch = text[i];
        bodyEl.insertBefore(document.createTextNode(ch), bodyEl.querySelector('.typewriter-cursor'));
        i++;
        let delay = 25;
        if (ch === '\\n') delay = 120;
        else if ('.!?。'.includes(ch)) delay = 80;
        else if (',，、'.includes(ch)) delay = 50;
        setTimeout(tick, delay);
      }
      tick();
    }

    function renderTrpgFlowState(state, events, summary, phase) {
      const el = document.getElementById('trpg-flow-state');
      if (!el) return;
      const history = trpgBuildSessionHistory(events);
      const mode = trpgSessionModeLabel(history, summary, phase);
      const hasSession = history.length > 0;
      const setupDone = trpgCanRunRound;
      const sessionDone = hasSession;
      const roundDone = Number(summary && summary.round) > 0;
      const ended = String(phase || '') === 'ended';
      const desc = trpgCanRunRound
        ? '준비 완료. 다음 라운드를 실행하면 서사가 이어집니다.'
        : String(trpgRunBlockedReason || '세션 시작과 파티 할당 확인이 필요합니다.');
      const steps = [
        { label: '1) 세션 시작', done: sessionDone },
        { label: '2) 파티 할당 검증', done: setupDone },
        { label: '3) 라운드 진행', done: roundDone },
        { label: '4) 세션 종료', done: ended },
      ];
      const roomId = String((document.getElementById('trpg-room-input') || {}).value || TRPG_DEFAULT_ROOM_ID).trim() || TRPG_DEFAULT_ROOM_ID;
      el.innerHTML = `
        <div class="trpg-flow-head">
          <div class="trpg-flow-title">진행 상태 · room ${escapeHtml(roomId)}</div>
          <div class="trpg-flow-badge ${escapeHtml(mode.cls)}">${escapeHtml(mode.label)}</div>
        </div>
        <div class="trpg-flow-desc">${escapeHtml(desc)}</div>
        <div class="trpg-flow-steps">
          ${steps.map((step) => `<div class="trpg-flow-step ${step.done ? 'done' : ''}">${escapeHtml(step.label)}</div>`).join('')}
        </div>
      `;
    }

    function renderTrpgState(state, events) {
      const viewEvents = trpgCurrentSessionEvents(events);
      const phase = trpgLatestPhase(viewEvents);
      const round = trpgLatestRound(state, viewEvents);
      const summary = trpgRoundSummary(viewEvents, round);
      renderTrpgFlowState(state, viewEvents, summary, phase);
      renderTrpgSessionMeta(state, viewEvents, summary, phase);
      renderTrpgPartyAssignment(state, viewEvents);
      renderTrpgActorBrowser(state, viewEvents);
      trpgRenderAssignmentEditor(state, viewEvents);
      renderTrpgSelectionSummary(state, viewEvents);
      trpgUpdateNextAction(state, viewEvents);
      renderTrpgStatus(state, summary, phase);
      renderTrpgRoundLog(viewEvents, round);
      renderTrpgGameHistory(events);
      renderTrpgParty(state);
      renderTrpgMap(state, summary);
    }

    function renderTrpgSessionMeta(_state, events, summary, phase) {
      const el = document.getElementById('trpg-session-meta');
      if (!el) return;
      const history = trpgBuildSessionHistory(events);
      if (!history.length) {
        const mode = trpgSessionModeLabel(history, summary, phase);
        el.innerHTML = `
          <div class="trpg-round-item ${escapeHtml(mode.cls)}">
            <div class="meta">mode</div>
            <div><b>${escapeHtml(mode.label)}</b> · 아직 session.started 이벤트가 없습니다.</div>
          </div>
        `;
        return;
      }
      const latest = history[0];
      const mode = trpgSessionModeLabel(history, summary, phase);
      const roomText = latest.roomId ? ` · room ${escapeHtml(latest.roomId)}` : '';
      const durationText = trpgFmtDurationMs(latest.durationMs);
      const endedText = latest.endedAt
        ? `종료 ${escapeHtml(trpgFmtDateTime(latest.endedAt))}`
        : `최근 ${escapeHtml(trpgFmtDateTime(latest.lastTs))}`;
      el.innerHTML = `
        <div class="trpg-round-item ${escapeHtml(mode.cls)}">
          <div class="meta">mode</div>
          <div><b>${escapeHtml(mode.label)}</b>${roomText}</div>
        </div>
        <div class="trpg-round-item">
          <div class="meta">session</div>
          <div>${escapeHtml(latest.sessionId)} · 시작 ${escapeHtml(trpgFmtDateTime(latest.startedAt))}</div>
        </div>
        <div class="trpg-round-item">
          <div class="meta">runtime</div>
          <div>round ${summary.round} · phase ${escapeHtml(String(phase || '-'))} · events ${latest.eventCount}</div>
        </div>
        <div class="trpg-round-item">
          <div class="meta">time</div>
          <div>${endedText} · 진행 ${escapeHtml(durationText)}</div>
        </div>
      `;
    }

    function renderTrpgPartyAssignment(state, events) {
      const el = document.getElementById('trpg-party-assignment');
      if (!el) return;
      const inputRaw = String((document.getElementById('trpg-player-keepers-input') || {}).value || '');
      const resolved = trpgResolvePlayerKeeperMapping(state, events, inputRaw);
      const expectedActors = resolved.expectedActors || trpgPartyActorsFromStateOrEvents(state, events);
      const parsed = parseTrpgPlayerKeepers(inputRaw);
      const mapping = resolved.ok ? resolved.mapping : {};
      const assignedActors = Object.keys(mapping);
      const actorSet = new Set(expectedActors);
      const keeperUse = {};
      Object.entries(mapping).forEach(([actor, keeper]) => {
        const key = String(keeper || '').trim();
        if (!key) return;
        if (!keeperUse[key]) keeperUse[key] = [];
        keeperUse[key].push(actor);
      });
      const duplicateKeepers = Object.entries(keeperUse).filter(([, actors]) => actors.length > 1);

      const unknownActors = resolved.ok
        ? (resolved.unknownActors || [])
        : assignedActors.filter((actor) => !actorSet.has(actor));
      const missingActors = resolved.ok
        ? (resolved.missingActors || [])
        : expectedActors.filter((actor) => !Object.prototype.hasOwnProperty.call(mapping, actor));
      const renamedRows = resolved.ok ? (resolved.renamed || []) : [];

      const rows = [];
      if (!parsed.ok) {
        rows.push(`
          <div class="trpg-round-item mismatch">
            <div class="meta">입력 오류</div>
            <div>${escapeHtml(String(parsed.error || 'invalid player keeper mapping'))}</div>
          </div>
        `);
      }
      if (!expectedActors.length) {
        rows.push(`
          <div class="trpg-round-item mismatch">
            <div class="meta">party</div>
            <div>파티 actor_id를 아직 확인하지 못했습니다. 먼저 <b>1) 세션 시작</b>을 실행하세요.</div>
          </div>
        `);
      } else {
        rows.push(`
          <div class="trpg-round-item">
            <div class="meta">expected party actors</div>
            <div>${escapeHtml(expectedActors.join(', '))}</div>
          </div>
        `);
      }
      expectedActors.forEach((actor) => {
        const keeper = String(mapping[actor] || '').trim();
        if (!keeper) {
          rows.push(`
            <div class="trpg-round-item mismatch">
              <div class="meta">${escapeHtml(actor)}</div>
              <div>keeper 미할당 (player keepers 입력 필요)</div>
            </div>
          `);
          return;
        }
        rows.push(`
          <div class="trpg-round-item ok">
            <div class="meta">${escapeHtml(actor)}</div>
            <div>${escapeHtml(keeper)}</div>
          </div>
        `);
      });

      unknownActors.forEach((actor) => {
        rows.push(`
          <div class="trpg-round-item mismatch">
            <div class="meta">${escapeHtml(actor)}</div>
            <div>파티에 없는 actor_id 입니다. (현재 입력만 존재)</div>
          </div>
        `);
      });
      renamedRows.forEach(([fromActor, toActor]) => {
        rows.push(`
          <div class="trpg-round-item">
            <div class="meta">정규화</div>
            <div>${escapeHtml(String(fromActor || ''))} → ${escapeHtml(String(toActor || ''))}</div>
          </div>
        `);
      });
      duplicateKeepers.forEach(([keeper, actors]) => {
        rows.push(`
          <div class="trpg-round-item mismatch">
            <div class="meta">중복 keeper</div>
            <div>${escapeHtml(keeper)} ← ${escapeHtml(actors.join(', '))}</div>
          </div>
        `);
      });
      if (!rows.length) {
        rows.push('<div class="trpg-empty" style="padding:18px 8px;">할당 정보가 없습니다.</div>');
      }
      el.innerHTML = rows.join('');
    }

    function renderTrpgActorBrowser(state, events) {
      const el = document.getElementById('trpg-actor-browser');
      if (!el) return;
      const actors = trpgActorsFromStateOrEvents(state, events);
      if (!actors.length) {
        trpgActorBrowserCache = {};
        el.innerHTML = '<div class="trpg-empty" style="padding:18px 8px;">세션 시작 후 액터 목록이 표시됩니다.</div>';
        return;
      }

      const nextCache = {};
      const cards = actors.map((actor) => {
        nextCache[actor.actorId] = actor;
        const token = encodeURIComponent(actor.actorId);
        const hpText = (Number.isFinite(actor.hp) && Number.isFinite(actor.maxHp))
          ? `HP ${actor.hp}/${actor.maxHp}`
          : (Number.isFinite(actor.hp) ? `HP ${actor.hp}` : 'HP -');
        const roleText = actor.role || '-';
        const keeperText = actor.keeper || '-';
        const stateCls = actor.alive ? 'ok' : 'mismatch';
        const stateText = actor.alive ? 'alive' : 'dead';
        const busy = trpgRoundRunning || trpgBootstrapping || trpgActorMutating;
        const claimDisabled = busy;
        const releaseDisabled = busy || !actor.keeper;
        const claimTitle = busy ? '실행 중에는 변경할 수 없습니다.' : '이 actor를 지정한 keeper로 claim합니다.';
        const releaseTitle = busy
          ? '실행 중에는 변경할 수 없습니다.'
          : (!actor.keeper ? '현재 keeper 할당 정보가 없어 release할 수 없습니다.' : '현재 keeper 점유를 해제합니다.');
        return `
          <div class="trpg-round-item ${stateCls}">
            <div class="meta">${escapeHtml(actor.actorId)} · ${escapeHtml(roleText)} · ${escapeHtml(stateText)} · ${escapeHtml(hpText)}</div>
            <div><b>${escapeHtml(actor.name)}</b> · keeper <b>${escapeHtml(keeperText)}</b></div>
            <div style="margin-top:6px;">
              <button type="button" class="trpg-mini-btn" onclick="loadTrpgActorToForm('${token}')">불러오기</button>
              <button type="button" class="trpg-mini-btn" ${claimDisabled ? 'disabled' : ''} title="${escapeHtml(claimTitle)}" onclick="quickClaimTrpgActor('${token}')">Claim</button>
              <button type="button" class="trpg-mini-btn" ${releaseDisabled ? 'disabled' : ''} title="${escapeHtml(releaseTitle)}" onclick="quickReleaseTrpgActor('${token}')">Release</button>
            </div>
          </div>
        `;
      });
      trpgActorBrowserCache = nextCache;
      el.innerHTML = cards.join('');
    }

    function loadTrpgActorToForm(token) {
      const actorId = decodeURIComponent(String(token || ''));
      const actor = trpgActorBrowserCache && trpgActorBrowserCache[actorId];
      if (!actor) {
        showToast('액터 정보를 찾지 못했습니다. 새로고침 후 다시 시도하세요.', 'error');
        return;
      }
      const setText = (id, value) => {
        const input = document.getElementById(id);
        if (!input) return;
        input.value = String(value == null ? '' : value);
      };
      const setList = (id, xs) => setText(id, Array.isArray(xs) ? xs.join(',') : '');
      setText('trpg-actor-id-input', actor.actorId);
      const roleSelect = document.getElementById('trpg-actor-role-select');
      if (roleSelect) {
        const role = String(actor.role || '').trim();
        const has = Array.from(roleSelect.options || []).some((opt) => String(opt.value || '') === role);
        roleSelect.value = has ? role : '';
      }
      setText('trpg-actor-name-input', actor.name || '');
      setText('trpg-actor-archetype-input', actor.archetype || '');
      setText('trpg-actor-persona-input', actor.persona || '');
      setText('trpg-actor-keeper-input', actor.keeper || '');
      setText('trpg-actor-hp-input', Number.isFinite(actor.hp) ? actor.hp : '');
      setText('trpg-actor-maxhp-input', Number.isFinite(actor.maxHp) ? actor.maxHp : '');
      setList('trpg-actor-traits-input', actor.traits);
      setList('trpg-actor-skills-input', actor.skills);
      setList('trpg-actor-inventory-input', actor.inventory);
      showToast(`액터 불러오기: ${actor.actorId}`, 'success');
    }

    function trpgActorDefaultKeeper(actorId) {
      return `pk-${String(actorId || '').trim()}`;
    }

    function trpgActorKeeperFromFormOrPrompt(actor) {
      const actorId = String((actor && actor.actorId) || '').trim();
      const formKeeper = trpgActorTextInput('trpg-actor-keeper-input');
      if (formKeeper) return formKeeper;
      const existing = String((actor && actor.keeper) || '').trim();
      if (existing) return existing;
      const suggested = trpgActorDefaultKeeper(actorId);
      const entered = window.prompt(`keeper 이름을 입력하세요 (actor ${actorId})`, suggested);
      return String(entered || '').trim();
    }

    async function trpgActorClaimCall(args) {
      try {
        return await mcpToolCall('trpg.actor.claim', args);
      } catch (primaryErr) {
        try {
          return await mcpToolCall('masc_trpg_actor_claim', args);
        } catch (legacyErr) {
          const primaryMsg = String((primaryErr && primaryErr.message) || primaryErr || 'unknown error');
          const legacyMsg = String((legacyErr && legacyErr.message) || legacyErr || 'unknown error');
          throw new Error(`actor claim 실패: canonical(${primaryMsg}) / legacy(${legacyMsg})`);
        }
      }
    }

    async function trpgActorReleaseCall(args) {
      try {
        return await mcpToolCall('trpg.actor.release', args);
      } catch (primaryErr) {
        try {
          return await mcpToolCall('masc_trpg_actor_release', args);
        } catch (legacyErr) {
          const primaryMsg = String((primaryErr && primaryErr.message) || primaryErr || 'unknown error');
          const legacyMsg = String((legacyErr && legacyErr.message) || legacyErr || 'unknown error');
          throw new Error(`actor release 실패: canonical(${primaryMsg}) / legacy(${legacyMsg})`);
        }
      }
    }

    async function quickClaimTrpgActor(token) {
      if (trpgRoundRunning || trpgBootstrapping || trpgActorMutating) return;
      const actorId = decodeURIComponent(String(token || ''));
      const actor = trpgActorBrowserCache && trpgActorBrowserCache[actorId];
      if (!actor) {
        showToast('액터 정보를 찾지 못했습니다. 새로고침 후 다시 시도하세요.', 'error');
        return;
      }
      const roomId = applyTrpgRoomFromInput();
      const keeperName = trpgActorKeeperFromFormOrPrompt(actor);
      if (!keeperName) {
        setTrpgStatusBoth('오류: claim할 keeper 이름이 필요합니다.', 'error');
        return;
      }
      setTrpgActorMutationBusy(true);
      setTrpgStatusBoth(
        `액터 claim 중: <b>${escapeHtml(actorId)}</b> → keeper <b>${escapeHtml(keeperName)}</b> / room <b>${escapeHtml(roomId)}</b>`,
        'running'
      );
      try {
        await trpgActorClaimCall({
          room_id: roomId,
          actor_id: actorId,
          keeper_name: keeperName,
        });
        const role = String((actor && actor.role) || '').trim().toLowerCase();
        if (role === 'player') {
          upsertTrpgPlayerKeeperLine(actorId, keeperName);
        }
        setTrpgStatusBoth(
          `액터 claim 완료: <b>${escapeHtml(actorId)}</b> → keeper <b>${escapeHtml(keeperName)}</b>`,
          'ok'
        );
        showToast(`Actor claim 완료: ${actorId}`, 'success');
        await fetchTrpg();
      } catch (e) {
        const msg = String((e && e.message) || e || 'unknown error');
        setTrpgStatusBoth(`액터 claim 실패: ${escapeHtml(msg)}`, 'error');
        showToast('Actor claim 실패', 'error');
      } finally {
        setTrpgActorMutationBusy(false);
      }
    }

    async function quickReleaseTrpgActor(token) {
      if (trpgRoundRunning || trpgBootstrapping || trpgActorMutating) return;
      const actorId = decodeURIComponent(String(token || ''));
      const actor = trpgActorBrowserCache && trpgActorBrowserCache[actorId];
      if (!actor) {
        showToast('액터 정보를 찾지 못했습니다. 새로고침 후 다시 시도하세요.', 'error');
        return;
      }
      const roomId = applyTrpgRoomFromInput();
      const keeperName = String((actor && actor.keeper) || '').trim() || trpgActorTextInput('trpg-actor-keeper-input');
      if (!keeperName) {
        setTrpgStatusBoth(
          `오류: actor <b>${escapeHtml(actorId)}</b>의 keeper 정보가 없어 release를 실행할 수 없습니다.`,
          'error'
        );
        return;
      }
      setTrpgActorMutationBusy(true);
      setTrpgStatusBoth(
        `액터 release 중: <b>${escapeHtml(actorId)}</b> / keeper <b>${escapeHtml(keeperName)}</b> / room <b>${escapeHtml(roomId)}</b>`,
        'running'
      );
      try {
        await trpgActorReleaseCall({
          room_id: roomId,
          actor_id: actorId,
          keeper_name: keeperName,
        });
        removeTrpgPlayerKeeperLine(actorId);
        const keeperInput = document.getElementById('trpg-actor-keeper-input');
        const formActorId = trpgActorTextInput('trpg-actor-id-input');
        if (keeperInput && formActorId === actorId) {
          keeperInput.value = '';
        }
        setTrpgStatusBoth(
          `액터 release 완료: <b>${escapeHtml(actorId)}</b> (keeper <b>${escapeHtml(keeperName)}</b>)`,
          'ok'
        );
        showToast(`Actor release 완료: ${actorId}`, 'success');
        await fetchTrpg();
      } catch (e) {
        const msg = String((e && e.message) || e || 'unknown error');
        setTrpgStatusBoth(`액터 release 실패: ${escapeHtml(msg)}`, 'error');
        showToast('Actor release 실패', 'error');
      } finally {
        setTrpgActorMutationBusy(false);
      }
    }

    function renderTrpgGameHistory(events) {
      const el = document.getElementById('trpg-game-history');
      if (!el) return;
      const toggleBtn = document.getElementById('trpg-history-toggle-btn');
      const fullHistory = trpgBuildSessionHistory(events);
      if (!fullHistory.length) {
        trpgHistoryExpanded = false;
        if (toggleBtn) {
          toggleBtn.disabled = true;
          toggleBtn.textContent = '이전 세션 없음';
          toggleBtn.title = '이 room에 기록된 세션이 없습니다.';
        }
        el.innerHTML = '<div class="trpg-empty" style="padding:18px 8px;">이 room의 이전 세션 기록이 없습니다.</div>';
        return;
      }
      const pastCount = Math.max(0, fullHistory.length - 1);
      if (toggleBtn) {
        toggleBtn.disabled = pastCount === 0;
        toggleBtn.textContent = pastCount === 0
          ? '이전 세션 없음'
          : (trpgHistoryExpanded ? `이전 세션 접기 (${pastCount})` : `이전 세션 펼치기 (${pastCount})`);
        toggleBtn.title = pastCount === 0
          ? '현재 세션만 있습니다.'
          : (trpgHistoryExpanded ? '이전 세션 목록을 접습니다.' : '이전 세션 목록을 펼칩니다.');
      }
      const visibleHistory = trpgHistoryExpanded ? fullHistory : fullHistory.slice(0, 1);
      const hiddenCount = Math.max(0, fullHistory.length - visibleHistory.length);
      const cards = visibleHistory.map((session, idx) => {
        const isLatest = idx === 0;
        const cls = isLatest ? 'ok' : '';
        const roomText = session.roomId ? ` · room ${escapeHtml(session.roomId)}` : '';
        const statusText = session.ended ? 'ended' : (isLatest ? 'current' : 'past');
        const tailTime = session.endedAt || session.lastTs;
        const tailLabel = session.endedAt ? '종료' : '최근';
        const durationText = trpgFmtDurationMs(session.durationMs);
        return `
          <div class="trpg-round-item ${cls}">
            <div class="meta">${statusText} · seq ${session.startSeq}~${session.endSeq}</div>
            <div><b>${escapeHtml(session.sessionId)}</b>${roomText}</div>
            <div class="meta">시작 ${escapeHtml(trpgFmtDateTime(session.startedAt))} · ${escapeHtml(tailLabel)} ${escapeHtml(trpgFmtDateTime(tailTime))} · 진행 ${escapeHtml(durationText)}</div>
            <div class="meta">round ${session.maxTurn || 0} · events ${session.eventCount}</div>
          </div>
        `;
      });
      if (hiddenCount > 0) {
        cards.push(`
          <div class="trpg-round-item">
            <div class="meta">history</div>
            <div>이전 ${hiddenCount}개 세션은 접힌 상태입니다. 상단 "이전 세션 펼치기" 버튼으로 확인할 수 있습니다.</div>
          </div>
        `);
      }
      el.innerHTML = cards.join('');
    }

    function toggleTrpgHistoryExpanded() {
      const fullHistory = trpgBuildSessionHistory(trpgEventsCache);
      if (fullHistory.length <= 1) {
        showToast('현재 room에는 펼칠 이전 세션이 없습니다.', 'error');
        return;
      }
      trpgHistoryExpanded = !trpgHistoryExpanded;
      renderTrpgGameHistory(trpgEventsCache);
      showToast(trpgHistoryExpanded ? '이전 세션 목록 펼침' : '이전 세션 목록 접음', 'success');
    }

    function renderTrpgStatus(state, summary, phase) {
      const el = document.getElementById('trpg-status-grid');
      if (!el) return;
      const node = (typeof state.current_node === 'string' && state.current_node.trim() !== '')
        ? state.current_node.trim()
        : '-';
      const timeoutCls = summary.timeouts > 0 ? 'bad' : '';
      const unavailableCls = summary.unavailable > 0 ? 'warn' : '';
      el.innerHTML = `
        <div class="trpg-status-card">
          <div class="trpg-status-label">Phase</div>
          <div class="trpg-status-value">${escapeHtml(String(phase || '-'))}</div>
        </div>
        <div class="trpg-status-card">
          <div class="trpg-status-label">Round</div>
          <div class="trpg-status-value">${summary.round}</div>
        </div>
        <div class="trpg-status-card">
          <div class="trpg-status-label">Node</div>
          <div class="trpg-status-value">${escapeHtml(node)}</div>
        </div>
        <div class="trpg-status-card">
          <div class="trpg-status-label">Proposed</div>
          <div class="trpg-status-value">${summary.proposed}</div>
        </div>
        <div class="trpg-status-card">
          <div class="trpg-status-label">Timeout</div>
          <div class="trpg-status-value ${timeoutCls}">${summary.timeouts}</div>
        </div>
        <div class="trpg-status-card">
          <div class="trpg-status-label">Unavailable</div>
          <div class="trpg-status-value ${unavailableCls}">${summary.unavailable}</div>
        </div>
      `;
    }

    function renderTrpgRoundLog(events, round) {
      const el = document.getElementById('trpg-round-log');
      if (!el) return;
      const filtered = events
        .filter((ev) => {
          const payload = trpgEventPayload(ev);
          const t = Number(payload.turn);
          return Number.isFinite(t) && t === round;
        })
        .filter((ev) => {
          const type = trpgEventType(ev);
          return type === 'narration.posted'
            || type === 'turn.action.proposed'
            || type === 'turn.timeout'
            || type === 'keeper.unavailable';
        })
        .sort((a, b) => (Number(b.seq) || 0) - (Number(a.seq) || 0))
        .slice(0, 14);
      if (filtered.length === 0) {
        el.innerHTML = '<div class="trpg-empty" style="padding:18px 8px;">최근 라운드 이벤트가 없습니다.</div>';
        return;
      }
      el.innerHTML = filtered.map((ev) => {
        const payload = trpgEventPayload(ev);
        const type = trpgEventType(ev);
        const seq = Number(ev.seq) || 0;
        const keeper = payload.keeper || ev.actor_id || '-';
        let body = '-';
        let cls = '';
        if (type === 'narration.posted') {
          body = payload.reply || '(narration)';
        } else if (type === 'turn.action.proposed') {
          body = payload.proposed_action || '(proposed action)';
        } else if (type === 'turn.timeout') {
          cls = 'timeout';
          const timeoutSec = Number(payload.timeout_sec);
          body = `timeout ${Number.isFinite(timeoutSec) ? timeoutSec + 's' : ''}`.trim();
        } else if (type === 'keeper.unavailable') {
          cls = 'unavailable';
          body = payload.reason || 'unavailable';
        }
        return `
          <div class="trpg-round-item ${cls}">
            <div class="meta">#${seq} · ${escapeHtml(trpgFmtEventTime(ev))} · ${escapeHtml(String(keeper))}</div>
            <div>${escapeHtml(String(body))}</div>
          </div>
        `;
      }).join('');
    }

    function renderTrpgParty(state) {
      const el = document.getElementById('trpg-party');
      if (!el) return;
      const partyObj =
        state && state.party && typeof state.party === 'object' && !Array.isArray(state.party)
          ? state.party
          : null;
      const fromState = partyObj
        ? Object.entries(partyObj).map(([actorId, raw]) => {
            const info = (raw && typeof raw === 'object' && !Array.isArray(raw)) ? raw : {};
            const hp = Number(info.hp);
            const maxHpRaw = Number(info.max_hp ?? info.maxHp);
            const maxHp = Number.isFinite(maxHpRaw) && maxHpRaw > 0
              ? maxHpRaw
              : (Number.isFinite(hp) ? hp : null);
            const pct = (Number.isFinite(hp) && Number.isFinite(maxHp) && maxHp > 0)
              ? Math.max(0, Math.min(100, Math.round((hp / maxHp) * 100)))
              : 100;
            return {
              name: info.name || actorId,
              cls: info.class || info.role || info.job || '-',
              hp: Number.isFinite(hp) ? hp : null,
              maxHp: Number.isFinite(maxHp) ? maxHp : null,
              area: info.area || info.position || info.location || '-',
              inventoryCount: Array.isArray(info.inventory) ? info.inventory.length : 0,
              pct,
            };
          })
        : [];
      const party = fromState.length > 0 ? fromState : TRPG_PARTY_FALLBACK;
      el.innerHTML = party.map((p) => {
        const pct = Number.isFinite(p.pct) ? p.pct : Math.round((p.hp / p.maxHp) * 100);
        const cls = pct > 60 ? 'hp-high' : pct > 30 ? 'hp-mid' : 'hp-low';
        const hpText = (Number.isFinite(p.hp) && Number.isFinite(p.maxHp))
          ? `HP ${p.hp}/${p.maxHp}`
          : 'HP -';
        const invText = Number.isFinite(p.inventoryCount) ? ` · 인벤토리 ${p.inventoryCount}` : '';
        return '<div class="trpg-party-card">'
          + '<div style="display:flex;justify-content:space-between;align-items:center;">'
          + '<span><span class="char-name">' + escapeHtml(String(p.name)) + '</span> <span style="color:#64748b;font-size:0.85em;">' + escapeHtml(String(p.cls)) + '</span></span>'
          + '<span style="font-size:0.85em;color:#94a3b8;">' + hpText + '</span>'
          + '</div>'
          + '<div class="trpg-hp-bar"><div class="' + cls + '" style="width:' + Math.max(0, Math.min(100, Number(pct) || 0)) + '%;height:100%;border-radius:3px;"></div></div>'
          + '<div style="font-size:0.75em;color:#475569;margin-top:4px;">위치: ' + escapeHtml(String(p.area || '-')) + invText + '</div>'
          + '</div>';
      }).join('');
    }

    function renderTrpgMap(state, summary) {
      const el = document.getElementById('trpg-map');
      if (!el) return;
      const node =
        (state && typeof state.current_node === 'string' && state.current_node.trim() !== '')
          ? state.current_node.trim()
          : '-';
      const world =
        state && state.world && typeof state.world === 'object' && !Array.isArray(state.world)
          ? state.world
          : {};
      const flags = Array.isArray(world.story_flags) ? world.story_flags.slice(0, 10) : [];
      const lines = [
        `현재 노드: ${node}`,
        `라운드: ${summary.round} · 행동제안 ${summary.proposed} · 내레이션 ${summary.narrations}`,
        `리스크: timeout ${summary.timeouts} / unavailable ${summary.unavailable}`,
        '',
        '[Story Flags]',
        ...(flags.length > 0 ? flags.map(f => `- ${String(f)}`) : ['- (none)']),
      ];
      if (flags.length === 0) {
        lines.push('', '[Fallback Map]', TRPG_MAP_FALLBACK);
      }
      el.textContent = lines.join('\n');
    }

    // Initial load + periodic polling (keepers/perpetual heartbeats don't emit SSE)
    // Initial load: fetchData uses batch /api/v1/dashboard endpoint
    // fetchServerHealth is called from DOMContentLoaded (version badge)
    startPeriodicRefresh();
    fetchData();
    connectSSE();
    window.addEventListener('beforeunload', () => {
      if (sseSource) {
        sseSource.close();
        sseSource = null;
      }
      clearSseReconnectTimer();
    });|}
