# Weaver — Domain Glossary

Ubiquitous language for the Weaver project. Terms are added as they crystallize
in design sessions. No implementation details live here.

## Widget

A self-contained, always-available surface living on the desktop layer.
Ranges from a live data display (clock, visualizer, graph) through interactive
controls (media controller with seek, todo with text input) up to a tiny
self-contained app (pomodoro with settings, chat overlay, simple game).

**Boundary:** embedded live web content (a rendered webpage) is *not* a
Widget. Widgets reach the web through APIs, not by embedding pages.
(Decided 2026-07-12: web embedding is very low priority and likely cut —
"since we have APIs the need for this is zero.")

## Provider

A data source collected once by the host and fanned out to every subscribed
Widget (system stats, media, time, weather). Distinct from a Widget's own
direct API access: Providers are shared and curated; direct API access is
per-Widget and declared.

## Standard surface

What a Widget may do without any user-facing consent: subscribe to Providers,
call network origins it declared in its manifest, and keep its own scoped
key-value state.

## The Loop

Weaver's core product motion, three verbs on one flywheel: **Conjure** (prompt
your agent, a widget appears on your desktop), **Share** (send the widget —
which is always its source), **Remix** (your agent patches someone else's
widget to your taste). Each verb's output is the next verb's input. None
stands alone; the platform is designed so that building Conjure makes Share
and Remix nearly free.

## Conjure

Creating a widget by prompting your own agent, prompt-to-desktop in under a
minute. The primary authoring act in Weaver; hand-writing widget code is the
special case, not the norm.

## Remix

The act of personalizing someone else's Widget by having your agent patch its
source — restyle it, resize it, rewire its data. Remixing is Weaver's answer
to personalization; there is no global theming system. The author's shipped
look is the intended vision; making it yours is a remix, not a runtime
override.

## System capability

Anything that touches the user's machine beyond the standard surface. Not one
bucket — a ladder: notifications (harmless) → launch app / open URL (mild) →
run commands / read arbitrary files (dangerous). The dangerous rungs exist but
require loud, explicit, per-Widget consent. Weaver deliberately rejects the
genre-incumbent posture where skins can simply do anything.
