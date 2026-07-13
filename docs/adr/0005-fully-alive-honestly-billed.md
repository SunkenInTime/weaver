# Widgets may animate freely; the platform enforces idle-zero and shows the bill

Any widget may render at any rate — sustained 60fps visualizers are a
first-class use case, not an abuse. In exchange, two platform guarantees:
(1) idle-zero — a widget whose data isn't changing costs 0% CPU (event-driven
repaints only; no polling render loops in the platform); (2) cost accounting —
every widget's live CPU/RAM is visible in the manager and surfaceable when
sharing. Efficiency posture is "you always know what things cost," not "we
forbid expensive things" (rejected: capping motion kills visualizers and the
alive-desktop identity) and not Rainmeter's unaccounted free-for-all
(rejected: that's how platforms become battery-hog folklore). Consequence:
the high-frame-rate present path is a headline engineering workstream, and
"under N% CPU" becomes a checkable spec agents can optimize against.
