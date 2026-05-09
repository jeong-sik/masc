// Barrel re-export for backward compatibility.
// All implementation has been decomposed into keeper-detail-*.ts modules.

export { KeeperDetailPage } from './keeper-detail-page'
export {
  selectedKeeper,
  openKeeperDetail,
  clearKeeperDetailSelection,
  closeKeeperDetail,
} from './keeper-detail-state'
export {
  filterCheckpointHistory,
  lineageTransitionLabel,
  lineageVerdictMeta,
} from './keeper-detail-history'
