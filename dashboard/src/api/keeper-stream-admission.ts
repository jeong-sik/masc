import { currentStoredTokenRevision } from './core'

export interface KeeperStreamAdmission {
  readonly keeperName: string
  readonly operationId: string
  readonly authRevision: number
}

export class KeeperStreamAuthenticationSupersededError extends Error {
  constructor(readonly admission: KeeperStreamAdmission) {
    super('Keeper stream authentication scope changed')
    this.name = 'KeeperStreamAuthenticationSupersededError'
  }
}

export function assertCurrentKeeperStreamAdmission(admission: KeeperStreamAdmission): void {
  if (admission.authRevision !== currentStoredTokenRevision()) {
    throw new KeeperStreamAuthenticationSupersededError(admission)
  }
}
