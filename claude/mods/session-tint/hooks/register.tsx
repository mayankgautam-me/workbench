import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Tint } from '../types'
import { NAMES, PALETTE, autoName, fmtDuration, parseChoice, washOf } from './core'

// Colours chosen with /tint or /color, by session id, so a resumed session keeps its own.
const CHOSEN_KEY = 'chosen'
const MAX_CHOSEN = 200

const OWN_KINDS = new Set(['composer', 'sdk', 'bridge'])

// Whether the status-band mod is folded to one row; never set where that mod is not installed.
const bandIsCompact = atom({ plugin: 'status-band', key: 'isCompact' } as const, false)
const tint = atom({ plugin: 'session-tint', key: 'tint' } as const, null)
// Whether the agent-map mod's panel is shown; never set where that mod is not installed.
const mapIsOpen = atom({ plugin: 'agent-map', key: 'isOpen' } as const, null)
// Tells the status-band mod that the rule carries the map's toggle while the band is unfolded.
const carriesMap = atom({ plugin: 'session-tint', key: 'carriesMap' } as const, false)
// Counts presses of the map toggle drawn here. The agent-map mod watches it and shows or hides
// its panel; running its /map command instead would print the command into the transcript.
const mapPress = atom({ plugin: 'session-tint', key: 'mapPress' } as const, 0)
// The same three for the git-graph mod's panel and its toggle.
const graphIsOpen = atom({ plugin: 'git-graph', key: 'isOpen' } as const, null)
const carriesGraph = atom({ plugin: 'session-tint', key: 'carriesGraph' } as const, false)
const graphPress = atom({ plugin: 'session-tint', key: 'graphPress' } as const, 0)

const chosenMap = async ($: EngineInterface): Promise<Record<string, string>> => {
  const kept = await $.store.get(CHOSEN_KEY).catch(() => null)
  return kept && typeof kept === 'object' && !Array.isArray(kept) ? (kept as Record<string, string>) : {}
}

const loadTint = async ($: EngineInterface) => {
  const id = await $.session.id()
  const chosen = (await chosenMap($))[id]
  const name = chosen && chosen in PALETTE ? chosen : autoName(id)
  const next: Tint = { name, hex: PALETTE[name] ?? '#7aa2f7' }
  await update($, tint, () => next)
  return next
}

const setChoice = async ($: EngineInterface, choice: string) => {
  const id = await $.session.id()
  const map = await chosenMap($)
  delete map[id]
  if (choice !== 'auto') map[id] = choice
  await $.store.set(CHOSEN_KEY, Object.fromEntries(Object.entries(map).slice(-MAX_CHOSEN)))
  return loadTint($)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await loadTint($).catch(() => undefined)
    await update($, carriesMap, () => true).catch(() => undefined)
    await update($, carriesGraph, () => true).catch(() => undefined)
    // /color is the engine's and does not reach a mod on every surface; /tint is this mod's own.
    await $.command
      .register({ name: 'tint', description: `Set this session's colour: ${NAMES.join(', ')} or auto` })
      .catch(() => undefined)
    return next(e)
  })

  on('command.run', { command: 'tint' }, async ($, e) => {
    const choice = parseChoice(e.args ?? '')
    if (!choice) {
      const now = await read($, tint)
      return { text: `This session is ${now?.name ?? 'not coloured yet'}. /tint ${NAMES.join(' | ')} | auto` }
    }
    const now = await setChoice($, choice)
    return { text: `Session colour set to: ${now.name}` }
  })

  // /color is the engine's own command: let it run, then take the colour it was given, so
  // the one command sets both. A name only this mod knows (teal) is answered here.
  on('command.run', { command: 'color' }, async ($, e, next) => {
    const choice = parseChoice(e.args ?? '')
    const ran = choice === 'teal' ? null : await next(e)
    if (!choice) return ran ?? { text: '' }
    const now = await setChoice($, choice)
    return ran ?? { text: `Session color set to: ${now.name}` }
  })

  // A rule in the session's colour on top of whatever else draws in the band.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const beneath = await next(e)
    const t = (await read($, tint)) ?? (await loadTint($).catch(() => null))
    if (!t || e.props.hasSurvey) return beneath
    // A folded status band shows the colour itself, as a bar at its left edge: no rule above it.
    if ((await read($, bandIsCompact).catch(() => false)) === true) return beneath
    // The engine's own answer draws nothing here and cannot sit inside a tree, so it is left out.
    const below = beneath.type === 'engine' ? null : beneath
    const { Box, Button, Text } = $.ui.resolve(e)
    // With the agent-map mod installed, the rule starts after a `map` toggle on the same row.
    const mapOpen = await read($, mapIsOpen).catch(() => null)
    const hasMap = mapOpen === true || mapOpen === false
    // And ends before a `graph` toggle at its right end, with the git-graph mod installed and the session in a repository.
    const graphOpen = await read($, graphIsOpen).catch(() => null)
    const hasGraph = graphOpen === true || graphOpen === false
    let line
    if (e.surface === 'terminal') {
      line = (
        <Text color={t.hex} wrap="truncate">
          {'─'.repeat(Math.max(1, (e.props.bodyColumns || 80) - (hasMap ? 6 : 0) - (hasGraph ? 8 : 0)))}
        </Text>
      )
    } else {
      // A thin vector line stretched to the band's width.
      const { Svg } = $.ui.resolve(e)
      const source =
        `<svg xmlns="http://www.w3.org/2000/svg" width="2000" height="10" viewBox="0 0 100 10" preserveAspectRatio="none">` +
        `<rect x="0" y="4" width="100" height="2" fill="${t.hex}"/></svg>`
      line = <Svg source={source} alt={`session colour ${t.name}`} height={10} />
    }
    return (
      <Box flexDirection="column" width="100%">
        <Box width="100%" alignItems="center">
          {hasMap ? (
            <Box key="map" flexShrink={0} paddingRight={1}>
              <Button
                key="map-toggle"
                plain
                label="map"
                onPress={async () => {
                  await update($, mapPress, n => (n ?? 0) + 1).catch(() => undefined)
                }}
              />
            </Box>
          ) : null}
          <Box flexGrow={1} flexShrink={1} minWidth={0}>
            {line}
          </Box>
          {hasGraph ? (
            <Box key="graph" flexShrink={0} paddingLeft={1}>
              <Button
                key="graph-toggle"
                plain
                label="graph"
                onPress={async () => {
                  await update($, graphPress, n => (n ?? 0) + 1).catch(() => undefined)
                }}
              />
            </Box>
          ) : null}
        </Box>
        {below}
      </Box>
    )
  })

  // Your own prompts, in the session's colour. Notifications and other senders keep the engine's row.
  on('ui.render', { component: 'UserMessage' }, async ($, e, next) => {
    const t = (await read($, tint)) ?? (await loadTint($).catch(() => null))
    // The person's own words: typed at the terminal, sent from the desktop app (which hands
    // them over as the SDK host's turn) or through Remote Control.
    const isOwn = OWN_KINDS.has(e.props.origin.kind)
    // The terminal's expanded view (ctrl+o) keeps the engine's full row; other surfaces have no such view.
    if (!t || !isOwn || (e.surface === 'terminal' && e.props.isExpanded)) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    // The desktop app sets your messages against the right edge, here in a card outlined and
    // faintly filled with the session's colour; the terminal marks them at the left.
    if (e.surface !== 'terminal') {
      return (
        <Box width="100%" justifyContent="flex-end">
          <Box borderStyle="round" borderColor={t.hex} backgroundColor={washOf(t.hex)} paddingX={2} paddingY={1}>
            <Text color={t.hex} bold>
              {e.props.text}
            </Text>
          </Box>
        </Box>
      )
    }
    return (
      <Box width="100%">
        <Text color={t.hex} bold>{'▌ '}</Text>
        <Text color={t.hex}>{e.props.text}</Text>
      </Box>
    )
  })

  on('ui.render', { component: 'Spinner' }, async ($, e, next) => {
    const t = (await read($, tint)) ?? (await loadTint($).catch(() => null))
    if (!t) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    // An override that is set but empty still means the word.
    const words = `● ${e.props.message || e.props.word}${e.props.suffix}`
    return (
      <Box>
        <Text color={t.hex}>{words}</Text>
      </Box>
    )
  })

  on('ui.render', { component: 'TurnDuration' }, async ($, e, next) => {
    const t = (await read($, tint)) ?? (await loadTint($).catch(() => null))
    if (!t) return next(e)
    const { Text } = $.ui.resolve(e)
    return <Text color={t.hex}>{`● ${e.props.word} for ${fmtDuration(e.props.durationMs)}`}</Text>
  })
}
