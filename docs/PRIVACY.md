# Privacy

Keel has no account, no analytics, no crash reporting and no telemetry. It does not send anything about your Mac,
your settings or your files anywhere. Everything it records stays in `~/Library/Application Support/Keel/` and in its
preferences file, `~/Library/Preferences/com.mohdmahmodi.keel.plist`.

Keel makes network connections in two situations, both listed below: the optional update check, and the benchmark's
network tests when you run them. Nothing else in the app touches the network.

## 1. Update check (optional)

| | |
|---|---|
| Endpoint | `GET https://api.github.com/repos/mohdmahmodi/keel/releases/latest` |
| When | At most once a day while Keel runs, and when you click **Check now** in Settings |
| Sends | A standard HTTPS request with the header `User-Agent: Keel/<version>`. No identifiers, no cookies (ephemeral session), no information about your Mac |
| Receives | The latest release's version, name, notes, page URL and download URL |
| Turn off | Settings › Updates › *Check for updates once a day* |

GitHub sees your IP address, as with any web request; see GitHub's privacy statement. Keel never downloads or
installs an update itself. **Download** opens the release's `.dmg` link (on `github.com`) in your browser.

## 2. Benchmark network tests (only when you run them)

The Benchmark page's network group runs only when you start it. It sends no data beyond the probes themselves.

| Test | Destination | What is sent |
|---|---|---|
| Ping gateway, 1.1.1.1, 8.8.8.8 | Your router, Cloudflare `1.1.1.1`, Google `8.8.8.8` | ICMP echo, 50 packets each at 0.2 s intervals, run in parallel |
| Nearest AWS region | `dynamodb.<region>.amazonaws.com` port 443 in 20 regions (TCP connect only, no data), then ICMP echo to the fastest | TCP handshakes, ICMP echo |
| DNS lookup | Your network's DNS server, `1.1.1.1`, `8.8.8.8`, `9.9.9.9` (UDP 53) | Two lookups each of apple.com, github.com, google.com, wikipedia.org, amazon.com, microsoft.com, youtube.com, cloudflare.com, npmjs.com, pypi.org; ten lookups of random names under apple.com, github.com, wikipedia.org, microsoft.com and amazon.com (to measure uncached resolution) |
| Network responsiveness | Apple's servers, through Apple's own `/usr/bin/networkQuality -s -c -M 20` | Saturates your download, then your upload, for up to 20 seconds each; typically transfers several hundred MB. Apple's privacy policy covers this tool |
| Ollama tokens/s | `http://127.0.0.1:11434` (your own Mac) | A short prompt to a model you already installed. Never leaves your Mac |

Untick any test on the Benchmark page to skip it; the network responsiveness test is the only one that moves a
meaningful amount of data.

macOS may ask to allow Keel to find devices on your local network the first time the gateway or DNS test runs.

## Things that stay on your Mac

- Recorded originals (backups) of every setting Keel changed, and copies of files it moved.
- The activity log and benchmark results.
- The machine profile (chip, memory, macOS version, power sources and so on) is read on launch so that tweaks match
  your hardware. It is never sent anywhere.

## Permissions

| Permission | Used for |
|---|---|
| Administrator password, or the optional helper | Applying and reverting tweaks that need root, through an allow-list of operations |
| Automation (Finder) | Measuring and emptying the Trash |
| Local Network | The gateway and local-DNS benchmark tests |
| Full Disk Access (optional, granted by you) | Measuring the Trash, Mail downloads and iOS device backups |

Keel asks for none of these up front; macOS asks the first time a feature needs one.
