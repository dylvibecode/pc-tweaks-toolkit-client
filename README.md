# PC Tweaks Toolkit

A Windows PC tuning/diagnostics toolkit — system checks, stress testing, GPU/graphics tweaks, and Windows tuning (taskbar, theme, debloat, gaming, performance), all in one GUI.

## Download & run

See [`HOW TO RUN.txt`](HOW%20TO%20RUN.txt) for step-by-step instructions. Short version:

1. Click **Code → Download ZIP** above, extract it.
2. Double-click **`Launch Toolkit.bat`** to start it (don't run `Toolkit.ps1` directly - see `HOW TO RUN.txt` for why).
3. Approve the one-time SmartScreen prompt and the Administrator prompt.

Windows will show a one-time "Windows protected your PC" SmartScreen warning on first launch — that's expected for any script downloaded from the internet that isn't yet widely recognized, not a sign of an actual problem. See `HOW TO RUN.txt` for the two-click way past it.

## What's included

- **PC Check** — storage, RAM, GPU, temps, BIOS version/settings checks.
- **Stress Test** — CPU (OCCT) and GPU (Heaven + MSI Afterburner) stress testing.
- **Graphics** — GPU driver cleanup (DDU), Safe Mode reboot helper, driver download links, max-performance GPU power state, display settings, a curated NVIDIA settings preset (via NVIDIA Profile Inspector), and the Legacy NVIDIA Control Panel.
- **Windows** — taskbar/Start customization, theme & accent color, context menu, debloat, gaming tweaks, and performance tuning (network, power plan, cleanup).

A few buttons launch third-party diagnostic tools (CPU-Z, GPU-Z, HWiNFO, OCCT, Heaven, MSI Afterburner, DDU, NVIDIA Profile Inspector) that aren't bundled here — the app will point you to the official download page the first time you need one. The Legacy NVIDIA Control Panel is installed via `winget` from the Microsoft Store instead, the first time it's used.

## License

This repository is published for client distribution only. All rights reserved — no license is granted to copy, modify, or redistribute this code.
