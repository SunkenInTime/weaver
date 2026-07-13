# No global theming system — personalization is agent remixing

Weaver has no theme layer, no token roles widgets must bind to, and no
"restyle the whole desktop" switch. A widget ships looking exactly as its
author intended; a user who wants it to match their setup has their agent
patch the widget's source (a remix). Rationale: runtime theming is
indirection built for a world where restyling by hand was expensive — with
agents, restyling is a thirty-second operation on the source itself, so the
indirection layer is machinery without a problem. Styling is therefore fully
free at the platform level (arbitrary values, any colors); the built-in
component library still has good defaults so low-effort widgets look decent,
but that is a library property, not a platform law.

## Consequences

- Widgets must be distributed in a form agents can read and patch — this
  constrains the packaging/distribution design (see future ADR).
- "Agents build good-looking widgets" is served by library defaults and
  templates, not by platform-enforced token vocabularies.
- The earlier design-doc sections on tokens/theming are superseded.
