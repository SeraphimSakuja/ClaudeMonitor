import Foundation

// CM-21 · `systemctl`-Attrappe für die Autostart-Unterbefehle (Testinfrastruktur).
//
// ⚠️ Diese Datei trägt **keine** Testfälle. Sie ist Werkzeug — dasselbe Muster
// wie `FakeSessionBus.swift`: eingehängt wird an der **Prozessgrenze**, der
// Produktivcode bleibt unverändert und läuft als echtes Kind.
//
// Der dokumentierte Bau-/Testcontainer (`swift:6.3.3`) hat weder `systemctl`
// noch `/run/systemd/system` — gemessen. Die Attrappe ist deshalb ein
// Shell-Skript namens `systemctl`, das in einem eigenen Verzeichnis liegt;
// dieses Verzeichnis wird dem `PATH` des Tray-Kindes vorangestellt. Der
// Injektionspunkt ist der bereits vorhandene: `PosixCommandRunner` startet
// `systemctl` über `posix_spawnp`, also über `PATH`.

/// Ein `systemctl`, das antwortet, was der Testfall braucht — und jeden Aufruf
/// protokolliert.
struct AutostartSystemctlStub {

    /// Das Verzeichnis, das dem `PATH` vorangestellt wird.
    let binVerzeichnis: URL
    /// Die Datei, in die jeder Aufruf eine Zeile schreibt.
    let protokollPfad: String
    /// Das Home, aus dem die Unit-Pfade abgeleitet werden.
    private let home: URL

    /// Legt Skript und Protokolldatei unterhalb von `home` an.
    ///
    /// Beides liegt IM temporären Home des Kindes: Das Home wird ohnehin je
    /// Testfall neu angelegt und am Ende entfernt.
    init(home: URL) throws {
        binVerzeichnis = home.appendingPathComponent("stub-bin", isDirectory: true)
        protokollPfad = home.appendingPathComponent("systemctl-aufrufe.log").path
        try FileManager.default.createDirectory(at: binVerzeichnis, withIntermediateDirectories: true)

        let skript = """
            #!/bin/sh
            printf '%s\\n' "$*" >> "$CM_STUB_LOG"
            case "$2" in
              is-enabled)
                if [ -n "$CM_STUB_SERVICE_IS_ENABLED_OUT" ] && [ "$3" = "claude-monitor-tray-update.service" ]; then
                  printf '%s\\n' "$CM_STUB_SERVICE_IS_ENABLED_OUT"
                  exit 0
                fi
                if [ -n "$CM_STUB_ENABLE_STATE" ] && [ -e "$CM_STUB_ENABLE_STATE.$3" ]; then
                  printf 'enabled\\n'
                  exit 0
                fi
                if [ -n "$CM_STUB_IS_ENABLED_OUT" ]; then printf '%s\\n' "$CM_STUB_IS_ENABLED_OUT"; fi
                if [ -n "$CM_STUB_IS_ENABLED_ERR" ]; then printf '%s\\n' "$CM_STUB_IS_ENABLED_ERR" >&2; fi
                exit "$CM_STUB_IS_ENABLED_RC"
                ;;
              is-active)
                printf '%s\\n' "$CM_STUB_IS_ACTIVE_OUT"
                exit 0
                ;;
              show)
                printf '%s\\n' "$CM_STUB_SHOW_OUT"
                if [ -n "$CM_STUB_SHOW_ERR" ]; then printf '%s\\n' "$CM_STUB_SHOW_ERR" >&2; fi
                exit "$CM_STUB_SHOW_RC"
                ;;
              enable)
                if [ -n "$CM_STUB_ENABLE_STATE" ]; then : > "$CM_STUB_ENABLE_STATE.$3"; fi
                exit 0
                ;;
              daemon-reload)
                exit "$CM_STUB_RELOAD_RC"
                ;;
            esac
            exit 0

            """
        let skriptPfad = binVerzeichnis.appendingPathComponent("systemctl")
        try skript.write(to: skriptPfad, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: skriptPfad.path)
        _ = FileManager.default.createFile(atPath: protokollPfad, contents: Data())
        self.home = home
    }

    /// Die Umgebung für das Tray-Kind.
    ///
    /// `XDG_RUNTIME_DIR` ist gesetzt, damit die **Auswertung** der Antwort
    /// geprüft wird und nicht die Vorbedingung „kein Nutzermanager möglich" —
    /// die greift sonst schon vor dem ersten `systemctl`-Aufruf.
    func umgebung(
        isEnabled: String,
        isEnabledRC: Int32 = 0,
        isEnabledStderr: String = "",
        isActive: String = "active",
        show: String = "",
        showRC: Int32 = 0,
        showStderr: String = "",
        reloadRC: Int32 = 0,
        serviceIsEnabled: String = "",
        enableSchaltetUm: Bool = false,
        zusaetzlich: [String: String] = [:]
    ) -> [String: String] {
        var umgebung: [String: String] = [
            "HOME": home.path,
            "XDG_RUNTIME_DIR": "/run/user/1000",
            "PATH": "\(binVerzeichnis.path):/usr/bin:/bin",
            "CM_STUB_LOG": protokollPfad,
            "CM_STUB_IS_ENABLED_OUT": isEnabled,
            "CM_STUB_IS_ENABLED_ERR": isEnabledStderr,
            "CM_STUB_IS_ENABLED_RC": "\(isEnabledRC)",
            "CM_STUB_IS_ACTIVE_OUT": isActive,
            "CM_STUB_SHOW_OUT": show,
            "CM_STUB_SHOW_RC": "\(showRC)",
            "CM_STUB_SHOW_ERR": showStderr,
            "CM_STUB_RELOAD_RC": "\(reloadRC)",
            // CM-29: der statische Update-Service antwortet auf `is-enabled`
            // anders als der Timer; `enable` kann den Timer umschalten.
            "CM_STUB_SERVICE_IS_ENABLED_OUT": serviceIsEnabled,
            "CM_STUB_ENABLE_STATE": enableSchaltetUm ? home.appendingPathComponent("enabled-zustand").path : ""
        ]
        umgebung.merge(zusaetzlich) { _, neu in neu }
        return umgebung
    }

    /// Alle bisherigen Aufrufe, je einer pro Zeile (`--user is-enabled …`).
    func aufrufe() -> [String] {
        guard let text = try? String(contentsOfFile: protokollPfad, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    // MARK: - curl und wget (CM-29)

    /// Legt `curl` und `wget` neben die `systemctl`-Attrappe.
    ///
    /// `curl` liefert je URL (Dateiname hinter dem letzten `/`) eine Datei aus
    /// `antwortVerzeichnis` bzw. den Exit-Code aus `<name>.rc`, sonst Exit 6;
    /// jeder Aufruf steht im Protokoll. `wget` protokolliert nur und scheitert
    /// mit Exit 4. Echte `timeout`, `sha256sum`, `tar` bleiben über `PATH`.
    func abrufAttrappen() throws -> AbrufAttrappen {
        let verzeichnis = home.appendingPathComponent("abruf-antworten", isDirectory: true)
        try FileManager.default.createDirectory(at: verzeichnis, withIntermediateDirectories: true)
        let attrappen = AbrufAttrappen(
            curlProtokoll: home.appendingPathComponent("curl-aufrufe.log").path,
            wgetProtokoll: home.appendingPathComponent("wget-aufrufe.log").path,
            antwortVerzeichnis: verzeichnis
        )
        let curl = """
            #!/bin/sh
            printf '%s\\n' "$*" >> "$CM_STUB_CURL_LOG"
            dest=""; prev=""; url=""
            for a in "$@"; do
              if [ "$prev" = "-o" ]; then dest="$a"; fi
              prev="$a"; url="$a"
            done
            name="${url##*/}"
            if [ -f "$CM_STUB_FETCH_DIR/$name.rc" ]; then exit "$(cat "$CM_STUB_FETCH_DIR/$name.rc")"; fi
            if [ -f "$CM_STUB_FETCH_DIR/$name" ]; then cp "$CM_STUB_FETCH_DIR/$name" "$dest"; exit 0; fi
            exit 6

            """
        let wget = """
            #!/bin/sh
            printf '%s\\n' "$*" >> "$CM_STUB_WGET_LOG"
            exit 4

            """
        for (name, text) in [("curl", curl), ("wget", wget)] {
            let pfad = binVerzeichnis.appendingPathComponent(name)
            try text.write(to: pfad, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pfad.path)
        }
        _ = FileManager.default.createFile(atPath: attrappen.curlProtokoll, contents: Data())
        _ = FileManager.default.createFile(atPath: attrappen.wgetProtokoll, contents: Data())
        return attrappen
    }
}

/// Protokolle und Antworten der `curl`-/`wget`-Attrappe.
struct AbrufAttrappen {
    let curlProtokoll: String
    let wgetProtokoll: String
    let antwortVerzeichnis: URL

    /// Umgebungsvariablen, die die Attrappen brauchen.
    var umgebung: [String: String] {
        [
            "CM_STUB_CURL_LOG": curlProtokoll,
            "CM_STUB_WGET_LOG": wgetProtokoll,
            "CM_STUB_FETCH_DIR": antwortVerzeichnis.path
        ]
    }

    func curlAufrufe() -> [String] { zeilen(curlProtokoll) }
    func wgetAufrufe() -> [String] { zeilen(wgetProtokoll) }

    /// Verwirft alle Antworten und Protokolle — Ausgangslage eines Schritts.
    func zuruecksetzen() throws {
        let dateien = FileManager.default
        for name in try dateien.contentsOfDirectory(atPath: antwortVerzeichnis.path) {
            try dateien.removeItem(at: antwortVerzeichnis.appendingPathComponent(name))
        }
        try Data().write(to: URL(fileURLWithPath: curlProtokoll))
        try Data().write(to: URL(fileURLWithPath: wgetProtokoll))
    }

    /// `curl` liefert für die URL mit diesem Dateinamen den Inhalt.
    func liefert(_ name: String, inhalt: Data) throws {
        try inhalt.write(to: antwortVerzeichnis.appendingPathComponent(name))
    }

    /// `curl` endet für die URL mit diesem Dateinamen mit `code`.
    func scheitert(_ name: String, mitCode code: Int32) throws {
        try Data("\(code)".utf8).write(to: antwortVerzeichnis.appendingPathComponent(name + ".rc"))
    }

    private func zeilen(_ pfad: String) -> [String] {
        guard let text = try? String(contentsOfFile: pfad, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}
