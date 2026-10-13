import Foundation

enum TweakCatalog {
    static let all: [Tweak] = visual + power + network + background + developer + ai + memory + storage + privacy + rosetta + finder + input

    static let hiddenGems: Set<String> = [
        // AI tools
        "gpu-wired-limit", "ollama-no-cloud", "ollama-localhost-only", "ollama-gpu-overhead", "ollama-max-loaded-models-1",
        // Network, privacy & security
        "content-caching", "terminal-secure-keyboard", "bonjour-advertising-off", "awdl-session-down", "airplay-receiver-off",
        "screen-lock-immediate", "lookup-suggestions-off", "login-name-and-password",
        // Power, performance, memory
        "sleep-blockers-check", "power-ac-not-low", "simulators-shutdown", "thermal-check", "memory-pressure-check",
        "video-streaming-sdr-battery", "womp-battery-off", "metal-hud", "battery-health-check",
        // Background apps & developer
        "login-reopen-apps-off", "bg-orphaned-launch-items", "bg-docker-vmnetd", "bg-adobe-elements", "xcode-on-device-predictions-off",
        "xcode-index-progress-numbers", "git-fsmonitor", "ssh-connection-reuse", "terminal-developer-tool", "crash-reports-as-notifications",
        "dev-plain-quotes-dashes", "docker-resource-caps", "spotlight-exclude-repos",
        // Visual & storage
        "click-wallpaper-reveal-off", "spaces-rearrange-off", "window-drag-anywhere", "proxy-icon-instant", "finder-search-current-folder",
        "save-dialogs-expanded", "screenshot-thumbnail-off", "free-space-headroom", "tm-thin-local-snapshots", "tm-no-new-disk-prompt",
        "new-docs-save-local", "finder-new-window-home", "screenshot-folder", "keyboard-navigation", "trackpad-three-finger-drag", "startup-chime-off",
    ]
}
