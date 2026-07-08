// PersonaForm unit tests — no template literals to avoid Write guard.
import { describe, expect, it, vi } from 'vitest'

vi.mock('./keeper-spawn-state', () => ({
  showCreateForm: { value: false },
  editingPersona: { value: null },
  createPersona: vi.fn().mockResolvedValue(true),
  updatePersona: vi.fn().mockResolvedValue(true),
}))

vi.mock('../common/input', () => ({
  TextInput: () => null,
  TextArea: () => null,
}))

vi.mock('../common/button', () => ({
  ActionButton: () => null,
}))

import { PersonaForm } from './persona-form'
import { showCreateForm, editingPersona } from './keeper-spawn-state'

describe('PersonaForm', () => {
  it('returns null when not visible', () => {
    showCreateForm.value = false
    editingPersona.value = null
    expect(PersonaForm()).toBeNull()
  })

  it('returns non-null when showCreateForm is true', () => {
    showCreateForm.value = true
    const result = PersonaForm()
    expect(result).not.toBeNull()
  })

  it('returns non-null when editingPersona is set', () => {
    editingPersona.value = {
      name: 'test-persona',
      displayName: 'Test',
      role: 'reviewer',
      mode: 'chat',
      description: 'test',
    }
    const result = PersonaForm()
    expect(result).not.toBeNull()
  })
})