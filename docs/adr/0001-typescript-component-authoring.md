# Widgets are authored as TypeScript components, not declarative markup

With the widget ceiling set at tiny interactive apps (state, inputs, seek
bars — not just data displays) and agents as the primary authors, one TSX
module per widget beats a manifest + markup + logic-file triad: it's a single
mental model that scales from a 10-line clock to a pomodoro app, it's the most
familiar shape in agent training data, and it eliminates cross-file binding
contracts (each one an opportunity for agent inconsistency). This reverses the
earlier markup-first design, which optimized for what the Native SDK substrate
compiles nicely rather than for the product ceiling.

## Considered Options

- Markup-first with a TS escape hatch — rejected: interactivity is normal at
  our ceiling, not exceptional, so the escape hatch becomes the main path.
- Both as equal paths — rejected: every feature designed twice, and authors
  must pick a lane before understanding the trade-off.

## Consequences

Every widget needs an embedded JS runtime (QuickJS/Hermes class), which
weakens the "few-MB static binary" story and requires re-auditing the
substrate choice (Native SDK) against the July 2026 gate measurements once
the product spec is complete.
