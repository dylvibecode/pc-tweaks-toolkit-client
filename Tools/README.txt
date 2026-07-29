Drop portable tool .exe files here so the Toolkit can launch them instantly
on every client PC without redownloading. Get each one ONCE from its
official vendor site (never a third-party mirror):

  CPU-Z  -> https://www.cpuid.com/softwares/cpu-z.html
            That page has TWO options - grab the "Portable/ZIP" one, NOT
            "Setup" (Setup installs to Program Files, which is not what
            we want here). Extract the zip, save cpuz_x64.exe here.

  GPU-Z  -> https://www.techpowerup.com/download/techpowerup-gpu-z/
            Downloads as a versioned filename (e.g. GPU-Z.2.70.0.exe) -
            rename it to: GPU-Z.exe

  HWiNFO -> https://www.hwinfo.com/download/
            Download the portable ZIP, extract, save as: HWiNFO64.exe

  OCCT, Heaven Benchmark, and MSI Afterburner (Stress Test tab) still get
  cached here, but unlike the three above they aren't self-contained
  standalone tools - Heaven and Afterburner are installers (run once per
  client PC; Afterburner also installs a driver + background service).
    OCCT             -> https://www.ocbase.com/download
                        Save as: OCCT.exe
    Heaven Benchmark -> https://benchmark.unigine.com/heaven
                        Downloads as a versioned filename (e.g.
                        Unigine_Heaven-4.0.exe) - rename to: Heaven-Setup.exe
    MSI Afterburner  -> https://www.msi.com/Landing/afterburner/graphics-cards
                        Downloads as a zip - extract the installer inside and
                        rename it to: MSIAfterburnerSetup.exe

  DDU (Graphics tab) -> https://www.wagnardsoft.com/
                        Ships as a self-extracting archive, not a single exe -
                        run the download once, extract it into a subfolder
                        here named exactly: DDU
                        (so the result is Tools\DDU\Display Driver Uninstaller.exe
                        alongside its other extracted files, which it needs).

Note: each portable tool writes its own .ini settings file next to itself
the first time it runs (e.g. cpuz.ini, HWiNFO64.INI). That's normal portable-
app behavior, not client data - safe to delete before handing this folder
off, and it'll just get recreated fresh on the next PC.
