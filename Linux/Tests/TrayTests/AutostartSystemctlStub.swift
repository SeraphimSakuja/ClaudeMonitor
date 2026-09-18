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
                if [ -n "$CM_STUB_IS_ENABLED_OUT" ]; then printf '%s\\n' "$CM_STUB_IS_ENABLED_OUT"; fi
                if [ -n "$CM_STUB_IS_ENABLED_ERR" ]; then printf '%s\\n' "$CM_STUB_IS_ENABLED_ERR" >&2; fi
                exit "$CM_STUB_IS_ENABLED_RC"
                ;;
              is-active)
                printf '%s\\n' "$CM_STUB_IS_ACTIVE_OUT"
                exit 0
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
        isActive: String = "active"
    ) -> [String: String] {
        [
            "HOME": home.path,
            "XDG_RUNTIME_DIR": "/run/user/1000",
            "PATH": "\(binVerzeichnis.path):/usr/bin:/bin",
            "CM_STUB_LOG": protokollPfad,
            "CM_STUB_IS_ENABLED_OUT": isEnabled,
            "CM_STUB_IS_ENABLED_ERR": isEnabledStderr,
            "CM_STUB_IS_ENABLED_RC": "\(isEnabledRC)",
            "CM_STUB_IS_ACTIVE_OUT": isActive
        ]
    }

    /// Alle bisherigen Aufrufe, je einer pro Zeile (`--user is-enabled …`).
    func aufrufe() -> [String] {
        guard let text = try? String(contentsOfFile: protokollPfad, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}
