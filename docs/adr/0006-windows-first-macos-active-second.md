# Windows ships first; macOS is an active second; Linux is acknowledged, not served

Windows leads because the desktop-customization culture (the Rainmeter
diaspora) lives there. macOS is developed and tested alongside — not a
someday port — since the team has Mac hardware in daily use. Linux is
deliberately very low priority: kept architecturally possible, not worked on.
The insurance policy that keeps this from becoming "Windows-only with
dreams": all platform-specific windowing behavior (layering, transparency,
show-desktop survival, tray) lives behind one internal platform seam from day
one, and no OS-ism ever leaks into the widget-facing SDK.
