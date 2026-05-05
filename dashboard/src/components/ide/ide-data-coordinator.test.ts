import { describe, expect, it } from 'vitest'
import { selectPreferredIdeRepositoryId } from './ide-data-coordinator'
import type { Repository } from '../../api/repositories'

function repo(
  id: string,
  localPath: string,
  name = id,
): Repository {
  return {
    id,
    name,
    url: '',
    local_path: localPath,
    default_branch: 'main',
    status: 'active',
    auto_sync: false,
    sync_interval: 300,
    credential_id: null,
    created_at: null,
    updated_at: null,
  }
}

describe('selectPreferredIdeRepositoryId', () => {
  it('keeps the current repository when it is still present', () => {
    const repositories = [
      repo('masc-mcp', '/Users/dancer/me/workspace/yousleepwhen/masc-mcp'),
      repo('oas', '.masc/repos/oas'),
    ]

    expect(selectPreferredIdeRepositoryId(repositories, 'oas')).toBe('oas')
  })

  it('prefers the actual masc-mcp workspace over managed mirrors', () => {
    const repositories = [
      repo('masc', '.masc/repos/masc'),
      repo('oas', '.masc/repos/oas'),
      repo('masc-mcp', '/Users/dancer/me/workspace/yousleepwhen/masc-mcp'),
    ]

    expect(selectPreferredIdeRepositoryId(repositories, null)).toBe('masc-mcp')
  })

  it('falls back to the first visible absolute workspace repository', () => {
    const repositories = [
      repo('masc', '.masc/repos/masc'),
      repo('kidsnote-shop', '/Users/dancer/me/workspace/kidsnote/kidsnote-shop'),
    ]

    expect(selectPreferredIdeRepositoryId(repositories, null)).toBe('kidsnote-shop')
  })

  it('falls back to the first repository when only mirrors exist', () => {
    const repositories = [
      repo('masc', '.masc/repos/masc'),
      repo('oas', '.masc/repos/oas'),
    ]

    expect(selectPreferredIdeRepositoryId(repositories, null)).toBe('masc')
  })
})
