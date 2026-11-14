// Pure colour picking for the mod. Nothing here touches `$`.

// Tokyo Night accents, under the names the built-in /color takes (teal is the mod's own).
export const PALETTE: Record<string, string> = {
  blue: '#7aa2f7',
  purple: '#bb9af7',
  cyan: '#7dcfff',
  green: '#9ece6a',
  yellow: '#e0af68',
  orange: '#ff9e64',
  red: '#f7768e',
  teal: '#73daca',
  pink: '#ff75a0',
}
export const NAMES = Object.keys(PALETTE)

/** The colour a session gets by itself: the same one every time for one id. */
export const autoName = (id: string) => {
  let h = 2166136261
  for (let i = 0; i < id.length; i++) h = Math.imul(h ^ id.charCodeAt(i), 16777619)
  return NAMES[(h >>> 0) % NAMES.length] ?? 'blue'
}

/** What /color was asked for: a palette name, `auto` for the session's own, or nothing recognisable. */
export const parseChoice = (args: string): string | null => {
  const word = args.trim().toLowerCase()
  if (word === 'auto' || word === 'default' || word === 'reset' || word === 'none') return 'auto'
  return word in PALETTE ? word : null
}

export const fmtDuration = (ms: number) => {
  const s = Math.max(0, Math.round(ms / 1000))
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${s % 60}s`
}

/** `hex` laid thinly over the Tokyo Night background: the faint fill of a card in that colour. */
export const washOf = (hex: string, amount = 0.14, base = '#1a1b26') => {
  const part = (h: string, i: number) => parseInt(h.slice(1 + i * 2, 3 + i * 2), 16)
  const mix = (i: number) => Math.round(part(base, i) + (part(hex, i) - part(base, i)) * amount)
  return `#${[0, 1, 2].map(i => mix(i).toString(16).padStart(2, '0')).join('')}`
}
