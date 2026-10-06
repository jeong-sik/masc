import { readBrowserActivity, writeBrowserActivity, type BrowserActivityLane } from './browser-lane-activity'
import { announceBrowserLaneObservationChanged } from './browser-lane-observation'
import { laneActivitySessions, type LaneActivitySession } from './lane-activity-session'

export type BrowserLaneActivitySession = LaneActivitySession<BrowserActivityLane, never>

// Browser activity is already published by the raw-save route. Model setup
// resume cannot install a Browser executor or apply startup paths, so a
// Browser save has no afterCommit.
const browser = laneActivitySessions<BrowserActivityLane>({
  key: lane => lane,
  read: readBrowserActivity,
  write: writeBrowserActivity,
  announceObservation: announceBrowserLaneObservationChanged,
})

export const browserLaneActivitySessionFor = browser.sessionFor
export const resetBrowserLaneActivitySessionsForTesting = browser.resetForTesting
