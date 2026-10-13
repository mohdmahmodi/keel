# What Keel does not do

Many "speed up your Mac" tips are left over from older Macs and older versions of macOS. On an Apple Silicon Mac
they do nothing, or they make things worse. Keel does not offer any of these.

| Tip | Why not |
|---|---|
| `sudo purge` and "RAM cleaner" apps | They empty the file cache, which macOS refills within minutes, so the next file accesses are slower. Memory pressure, not "memory used", is the number that matters. |
| Turning off Spotlight | Search in Finder, Mail and other apps stops working properly. Excluding folders (System Settings › Spotlight) is the better fix. |
| Deleting system caches or `/private/var/folders` | The system volume is sealed, and those folders hold live data for running processes. Apps also rebuild what you delete. |
| Turning off System Integrity Protection, Gatekeeper or FileVault | There is no speed gain. On Apple Silicon the disk is always encrypted in hardware; FileVault only ties the key to your password. You lose protection and gain nothing. |
| Kernel extensions and `nvram boot-args` | They need reduced security in Recovery and can stop the Mac from starting. None of them tunes an Apple Silicon Mac. |
| Defragmenting, "repairing permissions", forcing TRIM, resetting the SMC or NVRAM as maintenance | None of these apply to APFS on Apple Silicon. TRIM is always on for the internal SSD. |
| `periodic` maintenance scripts | Removed in macOS 15. Logs are rotated continuously. |
| `hibernatemode 0` "for faster wake" | The Mac already wakes from memory. Mode 0 only removes the safety copy, so a flat battery loses your open work. |
| Deleting the swap files or the sleep image | macOS recreates them. Deleting the sleep image while the Mac is hibernating loses the session. |
| TCP and network `sysctl` tuning (`delayed_ack`, window scaling, buffer sizes) | macOS sizes these automatically; the classic values are either already in place or worse. |
| Raising `kern.maxfiles` or `ulimit` | The defaults are already far higher than any desktop app needs. |
| Turning off hardware acceleration in browsers | Rendering and video decoding move from the GPU to the CPU, which is slower and uses more power. |
| Deleting language files from apps | It breaks the apps' code signatures, so they may refuse to open. |
| Turning off Time Machine local snapshots "for speed" | Snapshots cost nothing while they sit there, and macOS removes them when space runs low. Keel can release them when you need the space. |
| Flushing the DNS cache as routine maintenance | It only helps after a DNS change. Otherwise it throws away cached answers and makes the next lookups slower. |

If you think one of these does help on current Macs, open an issue with a measurement: the Mac, the macOS version,
and before and after numbers from Keel's Benchmark page or another tool.
