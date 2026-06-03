import { describe, expect, it } from 'vitest'
import { selectPreferredIdeRepositoryId } from './ide-data-workspace-store'
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
    created_at: null,
    updated_at: null,
  }
}

describe('selectPreferredIdeRepositoryId', () => {
  it('keeps the current repository when it is still present', () => {
    const repositories = [
      repo('masc', '/Users/dancer/me/workspace/yousleepwhen/masc'),
      repo('oas', '.masc/repos/oas'),
    ]

    expect(selectPreferredIdeRepositoryId(repositories, 'oas')).toBe('oas')
  })

  it('prefers the actual masc workspace over managed mirrors', () => {
    const repositories = [
      repo('masc', '.masc/repos/masc'),
      repo('oas', '.masc/repos/oas'),
      repo('masc', '/Users/dancer/me/workspace/yousleepwhen/masc'),
    ]

    expect(selectPreferredIdeRepositoryId(repositories, null)).toBe('masc')
  })

  it('prefers a masc workspace when a same-name mirror appears first', () => {
    const repositories = [
      repo('mirror-masc', '.masc/repos/mirror-masc', 'masc'),
      repo('workspace-masc', '/Users/dancer/me/workspace/yousleepwhen/masc', 'masc'),
    ]

    expect(selectPreferredIdeRepositoryId(repositories, null)).toBe('workspace-masc')
  })

  it('does not treat absolute .masc/repos mirrors as workspace checkouts', () => {
    const repositories = [
      repo('mirror-masc', '/Users/dancer/me/.masc/repos/mirror-masc', 'masc'),
      repo('workspace-oas', '/Users/dancer/me/workspace/yousleepwhen/oas', 'oas'),
    ]

    expect(selectPreferredIdeRepositoryId(repositories, null)).toBe('workspace-oas')
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
