<script setup lang="ts">
// A field you can pick from or type into: the suggestions drop down as you
// focus or type, narrowed by what is typed (value, label or note), and any
// value can still be typed. ↑ ↓ move, Enter picks, Escape closes the list
// (not the dialog around it).
import { computed, ref } from 'vue'

export type ComboOption = { value: string; label?: string; note?: string; tone?: 'ok' | 'warn' | 'err' }
const props = withDefaults(defineProps<{
  modelValue: string | number | undefined | null
  options: ComboOption[]
  placeholder?: string
  type?: 'text' | 'number'
  disabled?: boolean
  test?: string
}>(), { placeholder: '', type: 'text', disabled: false, test: undefined })
// pick: an option chosen from the list (not typed): a tag input adds it at once
const emit = defineEmits<{ 'update:modelValue': [string]; pick: [string] }>()

const open = ref(false)
const active = ref(-1)
const typed = ref(false)   // narrowed only once something is typed: a focus shows them all
const text = computed(() => (props.modelValue ?? '').toString())
const shown = computed(() => {
  const q = text.value.trim().toLowerCase()
  if (!typed.value || !q) return props.options
  return props.options.filter((o) => [o.value, o.label ?? '', o.note ?? ''].some((s) => s.toLowerCase().includes(q)))
})

function input(e: Event) {
  typed.value = true
  open.value = true
  active.value = -1
  emit('update:modelValue', (e.target as HTMLInputElement).value)
}
function pick(o: ComboOption) {
  emit('update:modelValue', o.value)
  emit('pick', o.value)
  open.value = false
  typed.value = false
}
function key(e: KeyboardEvent) {
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault()
    if (!open.value) { open.value = true; return }
    const n = shown.value.length
    if (n) active.value = (active.value + (e.key === 'ArrowDown' ? 1 : n - 1)) % n
  } else if (e.key === 'Enter' && open.value && active.value >= 0 && shown.value[active.value]) {
    e.preventDefault()
    pick(shown.value[active.value])
  } else if (e.key === 'Escape' && open.value) {
    e.stopPropagation()
    open.value = false
  }
}
// the caret opens the list with the focus in the field, so a click elsewhere or Escape closes it
const field = ref<HTMLInputElement | null>(null)
function caret() {
  if (open.value) { open.value = false; return }
  field.value?.focus()
  open.value = true
}
// a click on the list lands before the blur would close it
function blur() { setTimeout(() => { open.value = false; typed.value = false }, 120) }
</script>

<template>
  <div class="combo" :class="{ open: open && shown.length }">
    <input ref="field" class="input" :type="type" :value="text" :placeholder="placeholder" :disabled="disabled" :data-test="test"
      autocomplete="off" spellcheck="false" role="combobox" :aria-expanded="open && shown.length > 0"
      @focus="open = true" @click="open = true" @input="input" @keydown="key" @blur="blur">
    <button v-if="options.length && !disabled" type="button" class="combo-caret" tabindex="-1" aria-label="展开选项"
      @mousedown.prevent="caret">⌄</button>
    <ul v-if="open && shown.length" class="combo-menu" role="listbox">
      <li v-for="(o, i) in shown" :key="o.value" role="option" :aria-selected="o.value === text"
        :class="{ on: i === active, picked: o.value === text }" :data-test="test ? `${test}-option` : undefined"
        @mousedown.prevent="pick(o)" @mouseenter="active = i">
        <span class="combo-main">
          <span class="combo-value">{{ o.label ? o.label : o.value }}</span>
          <span v-if="o.label" class="combo-sub">{{ o.value }}</span>
        </span>
        <span v-if="o.note" class="combo-note" :class="o.tone">{{ o.note }}</span>
      </li>
    </ul>
  </div>
</template>
