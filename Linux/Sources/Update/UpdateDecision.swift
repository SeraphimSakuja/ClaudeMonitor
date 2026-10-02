import Foundation

/// Alle Fachregeln des Linux-Auto-Updates, die ohne Netz, Datei und
/// Prozessstart entscheidbar sind (CM-29).
public enum UpdateDecision {

    // MARK: - Versionsvergleich (FE 2)

    /// Ergebnis des Vergleichs Manifest ↔ laufendes Binary.
    public enum Outcome: Equatable, Sendable {
        /// Gleich alt oder älter — nie ein Downgrade.
        case upToDate
        /// Das Manifest bietet eine neuere Fassung an.
        case update
    }

    /// Verglichen wird **nur** `buildVersion` (Ganzzahl). Die
    /// Marketing-Version dient der Anzeige und dem Mitgliedspfad im Tarball.
    public static func decide(offer: UpdateOffer, ownBuild: Int) -> Outcome {
        offer.buildVersion > ownBuild ? .update : .upToDate
    }

    // MARK: - Herkunft der Download-Adresse (FE 5)

    /// Die Download-Adresse, die der Erzeuger für eine Fassung bildet.
    ///
    /// Gleiche Formel wie `scripts/release-linux.sh` (`TAR_NAME`,
    /// `DOWNLOAD_URL`). Das Manifest darf nur genau diese Adresse nennen: Der
    /// zweite Netz-Host kommt damit aus dem Code, nicht aus dem Manifest. Die
    /// Herkunft des Tarballs sichert die sha256 aus einem umleitungsfreien
    /// https-Manifest.
    public static func expectedURL(version: String) -> String {
        UpdateEndpoints.downloadURLBase + "/v" + version + "/" + tarballName(version: version)
    }

    /// `claude-monitor-tray-<version>-linux-x86_64.tar.gz`
    public static func tarballName(version: String) -> String {
        UpdateEndpoints.product + "-" + version + "-" + UpdateEndpoints.platform + ".tar.gz"
    }

    /// Der Pfad des Binarys im Tarball: `claude-monitor-tray-<version>/claude-monitor-tray`.
    ///
    /// ⚠️ **Eingefrorener Client-Vertrag** (Gegenstück `release-linux.sh`,
    /// Schritt 4/7 `PAYLOAD`): Jeder installierte Client packt genau diesen
    /// Pfad aus. Ändert eine spätere Fassung den Aufbau des Tarballs, lehnen
    /// alle installierten Clients jedes Update mit 13 ab.
    public static func memberPath(version: String) -> String {
        UpdateEndpoints.product + "-" + version + "/" + UpdateEndpoints.product
    }

    /// `^[0-9]+(\.[0-9]+)*$`
    public static func isPlainVersion(_ value: String) -> Bool {
        numericComponents(value) != nil
    }

    // MARK: - Kompatibilitätsboden (FE 7)

    /// Zerlegt `2.38` in `[2, 38]`; `nil`, wenn es keine reine Punkt-Zahl ist.
    public static func numericComponents(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part) else {
                return nil
            }
            numbers.append(number)
        }
        return numbers
    }

    /// Ob `local` mindestens `minimum` ist — **numerisch je Komponente**,
    /// nicht lexikografisch: `2.9 < 2.38`, `2.38 ≤ 2.38`, `2.39 > 2.38`.
    /// Fehlende Komponenten zählen als 0. Nicht lesbar ⇒ `false`.
    public static func meetsFloor(local: String, minimum: String) -> Bool {
        guard let lhs = numericComponents(local), let rhs = numericComponents(minimum) else { return false }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return true
    }

    /// Liest die glibc-Fassung aus der Antwort von
    /// `confstr(_CS_GNU_LIBC_VERSION)` (`"glibc 2.39"`).
    public static func glibcVersion(fromConfstr value: String) -> String? {
        let words = value.split(separator: " ")
        guard words.count == 2, words[0] == "glibc", isPlainVersion(String(words[1])) else { return nil }
        return String(words[1])
    }

    // MARK: - `--version` und Ladeprobe (FE 8)

    /// Der Kanal der `--version`-Ausgabe: **stdout** (fd 1).
    ///
    /// ⚠️ **Eingefrorener Client-Vertrag.** Die Ladeprobe jedes installierten
    /// Clients liest genau diesen Kanal und vergleicht zeichengleich mit
    /// ``versionLine(version:buildVersion:)``. Ändert eine spätere Fassung
    /// Kanal oder Wortlaut, lehnen alle installierten Clients jedes Update
    /// dauerhaft mit 13 ab. `release-linux.sh` prüft die Zeile deshalb am
    /// gebauten und am ausgepackten Binary.
    public static let versionOutputDescriptor: Int32 = 1

    /// `claude-monitor-tray 1.0.2 (build 3)` — ohne Zeilenende.
    public static func versionLine(version: String, buildVersion: Int) -> String {
        "\(UpdateEndpoints.product) \(version) (build \(buildVersion))"
    }

    /// Ob die Ladeprobe das angebotene Binary bestätigt: Exit 0 und genau die
    /// Versionszeile (ein abschließendes Zeilenende zählt nicht).
    public static func probeConfirms(exitStatus: Int32, output: String, offer: UpdateOffer) -> Bool {
        guard exitStatus == 0 else { return false }
        var line = output
        if line.hasSuffix("\n") { line.removeLast() }
        return line == versionLine(version: offer.version, buildVersion: offer.buildVersion)
    }

    // MARK: - Integrität (FE 6)

    /// Liest die Prüfsumme aus der Ausgabe von `sha256sum -- <datei>`.
    public static func sha256(fromSha256sumOutput output: String) -> String? {
        guard let first = output.split(separator: " ", maxSplits: 1).first else { return nil }
        let value = String(first)
        return isSha256(value) ? value.lowercased() : nil
    }

    /// 64 Hex-Zeichen, Groß/Klein egal.
    public static func isSha256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && $0.isASCII }
    }

    /// Vergleich ohne Groß/Klein-Unterschied.
    public static func sha256Matches(_ measured: String, expected: String) -> Bool {
        isSha256(measured) && isSha256(expected) && measured.lowercased() == expected.lowercased()
    }

    // MARK: - Rückgabecodes der Abrufwerkzeuge (Auflage 11)

    /// Das Werkzeug, mit dem abgerufen wurde.
    public enum FetchTool: Equatable, Sendable {
        /// `curl` direkt.
        case curl
        /// `wget`, gestartet unter `timeout` (coreutils).
        case wget
    }

    /// Wie ein misslungener Abruf zählt.
    public enum FetchFailure: Equatable, Sendable {
        /// Nichts gemessen — Werkzeug fehlt, Netz, HTTP-Fehler, Zeitüberschreitung ⇒ Exit 12.
        case unavailable
        /// Abgelehnt — die Antwort verletzt eine Zusage (Größe, Protokoll) ⇒ Exit 13.
        case refused
    }

    /// Bildet einen Rückgabecode ≠ 0 auf 12/13 ab.
    ///
    /// * `curl` 63 — die Datei ist größer als `--max-filesize` (Manifest-Grenze
    ///   bzw. `size` aus dem Manifest): Ablehnung nach FE 6.
    /// * `curl` 1 — nicht unterstütztes Protokoll; mit `--proto-redir =https`
    ///   ist das die abgelehnte http-Weiterleitung: Ablehnung nach FE 5.
    /// * alles andere (`curl` 6/7/28/35/22 …, `wget` 4/5/8 …, `timeout` 124,
    ///   Startfehler 127) — Netz, HTTP oder Werkzeug: nichts gemessen.
    ///
    /// `wget` kennt keinen eigenen Code für eine abgelehnte Weiterleitung:
    /// `--max-redirect=0` endet bei einer Umleitung mit 8, wie ein 404
    /// (gemessen, wget 1.25). Beim Manifest ist das der HTTP-Fall.
    public static func fetchFailure(tool: FetchTool, exitStatus: Int32) -> FetchFailure {
        switch tool {
        case .curl:
            return exitStatus == 63 || exitStatus == 1 ? .refused : .unavailable
        case .wget:
            return .unavailable
        }
    }

    // MARK: - Grenzen

    /// Höchstgröße des Manifests in Byte — vor dem Parsen geprüft.
    public static let manifestByteLimit = 65536
    /// Verbindungsaufbau je Abruf.
    public static let connectTimeoutSeconds = 30
    /// Gesamtzeit des Manifest-Abrufs (Schritt 4).
    public static let manifestTimeoutSeconds = 120
    /// Gesamtzeit des Tarball-Abrufs (Schritt 7).
    public static let tarballTimeoutSeconds = 600
    /// Gesamtzeit der Ladeprobe (Schritt 10).
    public static let probeTimeoutSeconds = 30
}
