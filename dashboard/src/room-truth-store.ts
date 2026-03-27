// Barrel re-export for backward compatibility.
// Room truth store is split into room-truth-signals, room-truth-normalizers, room-truth-actions.
export {
  roomTruth,
  roomTruthLoading,
  roomTruthError,
  roomTruthInitializing,
} from './room-truth-signals'
export { normalizeRoomTruth } from './room-truth-normalizers'
export { refreshRoomTruth, requestRoomTruth, requestRoomTruthNow, disposeRoomTruthScheduler } from './room-truth-actions'
