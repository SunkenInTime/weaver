# The permission wall sits between "declared APIs + own state" and "touches your system"

Widgets get a quiet standard surface — host providers, network calls to
origins declared in their manifest (auditable at install), and scoped
key-value persistence — with no consent friction. System capabilities are a
graded ladder (notifications → launch app/open URL → run commands/read files)
where the dangerous rungs exist but demand loud, explicit, per-widget consent
that a future gallery can surface as warning badges. We deliberately reject
Rainmeter's posture, where skins can execute anything invisibly: Weaver is
designed for a sharing ecosystem where strangers install each other's
widgets, and tightening a loose permission model later breaks the ecosystem,
while loosening a tight one doesn't.
