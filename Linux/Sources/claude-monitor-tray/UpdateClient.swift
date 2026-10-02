import Foundation
#if canImport(Glibc)
import Glibc
#endif
import Autostart
import TrayPresentation
import Update

/// Die I/O-Seite von `--update` (CM-29): Manifest holen, vergleichen, Tarball
/// laden, prüfen, Binary ersetzen, Tray-Dienst neu starten.
///
/// Die **Regeln** stehen im Ziel `Update` (`UpdateManifest`, `UpdateDecision`,
/// `UpdateTexts`). Hier steht nur, was Netz, Dateisystem und Prozessstart
/// braucht. Netz gibt es ausschließlich über `curl` bzw. `wget` als
/// Kindprozess: `URLSession` zöge `libcurl`, `libssl` und weitere Sonamen ins
/// statische Binary, die die ldd-Sollmenge von `release-linux.sh` nicht
/// erlaubt.
///
/// ⚠️ **Ohne Aufruf kein Netz (FE 1).** Dieser Typ wird nur von `--update`
/// erzeugt — aus der Kommandozeile oder aus dem Service, den
/// `--install-auto-update` einrichtet.
struct UpdateClient {

    /// Die Umgebung der Kindprozesse und Quelle von `TMPDIR`.
    let environment: [String: String]
    /// Der Zugang zu `curl`, `wget`, `timeout`, `sha256sum`, `tar`, `systemctl`.
    let runner: CommandRunner
    /// Der Ausgabekanal.
    let emit: (String) -> Void

    /// `--update`
    func run() -> TrayExit {
        // (1) Eigener Pfad — derselbe Weg wie `ExecStart=` der Autostart-Unit.
        let binaryPath: String
        switch AutostartExecutable.resolve() {
        case .usable(let path):
            binaryPath = path
        case .unusable(let reason):
            emit(UpdateTexts.executableNotUsable(reason: reason))
            return .updateRefused
        }
        let directory = parentDirectory(of: binaryPath)

        // FE 12: vor jedem Netzzugriff.
        guard access(directory, W_OK) == 0 else {
            emit(UpdateTexts.directoryNotWritable(directory: directory))
            return .updateRefused
        }

        // (2) FE 10: Sperre auf dem Verzeichnis-Deskriptor — keine Sperrdatei.
        // `O_CLOEXEC` (2b-Auflage 4): Ein Kindprozess erbt den Deskriptor
        // nicht; ein verwaister Abruf hielte sonst die Sperre, ohne dass ein
        // Lauf läuft.
        let directoryDescriptor = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryDescriptor >= 0 else {
            emit(UpdateTexts.lockFailed(reason: errnoName(errno)))
            return .updateRefused
        }
        defer { close(directoryDescriptor) }
        guard flock(directoryDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            emit(code == EWOULDBLOCK ? UpdateTexts.anotherUpdateRunning : UpdateTexts.lockFailed(reason: errnoName(code)))
            return .updateRefused
        }

        // (3) Privates Temp-Verzeichnis (0700); jeder Ausgang räumt es ab.
        let temporary: String
        switch makeTemporaryDirectory() {
        case .success(let path):
            temporary = path
        case .failure(let reason):
            emit(UpdateTexts.temporaryDirectoryFailed(reason: reason.text))
            return .updateUnavailable
        }
        defer { try? FileManager.default.removeItem(atPath: temporary) }

        return update(binaryPath: binaryPath, directory: directory, directoryDescriptor: directoryDescriptor,
                      temporary: temporary)
    }

    // MARK: - Ablauf

    private func update(binaryPath: String, directory: String, directoryDescriptor: Int32,
                        temporary: String) -> TrayExit {
        // (4) Manifest holen.
        let manifestPath = temporary + "/manifest.json"
        let tool: UpdateDecision.FetchTool
        switch fetch(
            UpdateEndpoints.manifestURL,
            to: manifestPath,
            what: "update manifest",
            maxBytes: UpdateDecision.manifestByteLimit,
            seconds: UpdateDecision.manifestTimeoutSeconds,
            followRedirects: false,
            only: nil,
            temporary: temporary
        ) {
        case .success(let used): tool = used
        case .failure(let exit): return exit.code
        }

        // (5) Größe vor dem Parsen, dann prüfen und entscheiden.
        guard let manifestSize = fileSize(manifestPath) else {
            emit(UpdateTexts.manifestUnreadable(reason: "no file was written"))
            return .updateRefused
        }
        guard manifestSize <= UpdateDecision.manifestByteLimit else {
            emit(UpdateTexts.manifestTooLarge(limit: UpdateDecision.manifestByteLimit))
            return .updateRefused
        }
        guard let manifestData = FileManager.default.contents(atPath: manifestPath) else {
            emit(UpdateTexts.manifestUnreadable(reason: "the downloaded file could not be read"))
            return .updateRefused
        }
        let offer: UpdateOffer
        switch UpdateManifest.validate(manifestData) {
        case .success(let value): offer = value
        case .failure(let rejection):
            emit(UpdateTexts.manifestRejected(rejection))
            return .updateRefused
        }
        guard UpdateDecision.decide(offer: offer, ownBuild: TrayTexts.buildVersion) == .update else {
            emit(UpdateTexts.upToDate(version: TrayTexts.version, buildVersion: TrayTexts.buildVersion))
            return .ok
        }

        // (6) FE 7: Kompatibilitätsboden vor dem Download.
        guard let glibc = localGlibcVersion() else {
            emit(UpdateTexts.glibcUnknown)
            return .updateRefused
        }
        guard UpdateDecision.meetsFloor(local: glibc, minimum: offer.minimumGlibc) else {
            emit(UpdateTexts.belowFloor(local: glibc, minimum: offer.minimumGlibc))
            return .updateRefused
        }

        // (7) Tarball laden — mit demselben Werkzeug wie das Manifest.
        let tarballPath = temporary + "/" + UpdateDecision.tarballName(version: offer.version)
        if case .failure(let exit) = fetch(
            offer.url,
            to: tarballPath,
            what: "update",
            maxBytes: offer.size,
            seconds: UpdateDecision.tarballTimeoutSeconds,
            followRedirects: true,
            only: tool,
            temporary: temporary
        ) {
            return exit.code
        }

        // FE 6: erst Größe, dann Prüfsumme.
        let actualSize = fileSize(tarballPath) ?? -1
        guard actualSize == offer.size else {
            emit(UpdateTexts.sizeMismatch(expected: offer.size, actual: max(actualSize, 0)))
            return .updateRefused
        }
        let checksum = runner.run(executable: "sha256sum", arguments: ["--", tarballPath])
        guard checksum.didRun else {
            emit(UpdateTexts.toolNotRunnable(tool: "sha256sum", reason: checksum.standardError))
            return .updateUnavailable
        }
        guard checksum.exitStatus == 0,
              let measured = UpdateDecision.sha256(fromSha256sumOutput: checksum.standardOutput) else {
            emit(UpdateTexts.checksumUnreadable(detail: firstLine(checksum.standardError)))
            return .updateRefused
        }
        guard UpdateDecision.sha256Matches(measured, expected: offer.sha256) else {
            emit(UpdateTexts.checksumMismatch)
            return .updateRefused
        }

        // (8) Nur das eine Mitglied auspacken.
        let member = UpdateDecision.memberPath(version: offer.version)
        let extractDirectory = temporary + "/unpacked"
        guard mkdir(extractDirectory, 0o700) == 0 else {
            emit(UpdateTexts.temporaryDirectoryFailed(reason: errnoName(errno)))
            return .updateUnavailable
        }
        let unpack = runner.run(executable: "tar", arguments: [
            "-xzf", tarballPath, "-C", extractDirectory,
            "--no-same-owner", "--no-same-permissions", "--", member
        ])
        guard unpack.didRun else {
            emit(UpdateTexts.toolNotRunnable(tool: "tar", reason: unpack.standardError))
            return .updateUnavailable
        }
        let unpacked = extractDirectory + "/" + member
        guard unpack.exitStatus == 0, isRegularFile(unpacked) else {
            emit(UpdateTexts.memberMissing(member: member))
            return .updateRefused
        }

        // (9) Staging im SELBEN Verzeichnis — nur so ist `rename` atomar.
        let stagingPath = directory + "/." + lastComponent(of: binaryPath) + ".update-new"
        var replaced = false
        defer { if !replaced { unlink(stagingPath) } }
        if let reason = stage(from: unpacked, to: stagingPath) {
            emit(UpdateTexts.stagingFailed(path: stagingPath, reason: reason))
            return .updateRefused
        }

        // (10) FE 8: Ladeprobe — gelesen wird genau der Kanal, den der
        // Vertrag `UpdateDecision.versionOutputDescriptor` festlegt.
        let probe = runner.run(executable: "timeout", arguments: [
            String(UpdateDecision.probeTimeoutSeconds), stagingPath, "--version"
        ])
        guard probe.didRun else {
            emit(UpdateTexts.toolNotRunnable(tool: "timeout", reason: probe.standardError))
            return .updateUnavailable
        }
        let probeOutput = UpdateDecision.versionOutputDescriptor == 1 ? probe.standardOutput : probe.standardError
        guard UpdateDecision.probeConfirms(exitStatus: probe.exitStatus, output: probeOutput, offer: offer) else {
            emit(UpdateTexts.probeFailed(
                expected: UpdateDecision.versionLine(version: offer.version, buildVersion: offer.buildVersion),
                exitStatus: probe.exitStatus,
                output: probeOutput
            ))
            return .updateRefused
        }

        // (11) FE 9: Austausch nur per `rename`. Das laufende Binary wird nie
        // zum Schreiben geöffnet (das endete mit `ETXTBSY`). FE 16: Danach ist
        // das alte Binary weg — es gibt keinen Rückweg außer dem Handdownload.
        guard rename(stagingPath, binaryPath) == 0 else {
            emit(UpdateTexts.replaceFailed(path: binaryPath, reason: errnoName(errno)))
            return .updateRefused
        }
        replaced = true
        fsync(directoryDescriptor)
        emit(UpdateTexts.updated(version: offer.version, buildVersion: offer.buildVersion, path: binaryPath))

        // (12) FE 11 + 2b-Auflage 5: Neustart nur, wenn systemd für den Namen
        // die eigene Autostart-Unit lädt und die genau dieses Binary startet.
        // Dieselbe Messung wie beim Einrichten (gemeinsamer Code); ihre
        // Meldungen gehören nicht hierher, deshalb ein stiller Installer.
        let measurement = AutostartInstaller(environment: environment, runner: runner, emit: { _ in })
        if measurement.autostartServiceRuns(executablePath: binaryPath) {
            let restart = runner.run(
                executable: "systemctl",
                arguments: ["--user", "try-restart", AutostartPaths.unitName]
            )
            if restart.didRun && restart.exitStatus == 0 {
                emit(UpdateTexts.trayRestarted)
                return .ok
            }
        }
        emit(UpdateTexts.restartTheTray(version: offer.version))
        return .ok
    }

    // MARK: - Abruf (2b-Auflage 3, 11)

    /// Ein Abbruch mit seinem Exit-Code; die Meldung ist schon ausgegeben.
    private struct Stop: Error {
        let code: TrayExit
    }

    /// Lädt `url` nach `destination`.
    ///
    /// * `curl` immer mit `-q` als ERSTEM Argument — sonst läse es
    ///   `~/.curlrc`, und eine Zeile `insecure` dort schaltete die
    ///   TLS-Prüfung ab.
    /// * `wget` NUR, wenn `curl` nicht startbar ist (`posix_spawnp` →
    ///   `ENOENT`) — nie nach einem gescheiterten `curl`-Lauf: Sonst umginge
    ///   `wget` eine von `curl` abgelehnte http-Weiterleitung.
    /// * `wget` mit `--no-config` und `--hsts-file` im Temp-Verzeichnis (sonst
    ///   bliebe `~/.wget-hsts` liegen), unter `timeout` (`wget` kennt keine
    ///   Gesamtzeit), beim Manifest mit `--max-redirect=0`.
    ///
    /// - Parameter only: das Werkzeug, mit dem schon das Manifest kam; `nil`
    ///   = erst `curl`, bei `ENOENT` `wget`.
    private func fetch(
        _ url: String,
        to destination: String,
        what: String,
        maxBytes: Int,
        seconds: Int,
        followRedirects: Bool,
        only: UpdateDecision.FetchTool?,
        temporary: String
    ) -> Result<UpdateDecision.FetchTool, Stop> {
        if only != .wget {
            var arguments = [
                "-q", "-sS", "--fail",
                "--proto", "=https", "--proto-redir", "=https",
                "--max-filesize", String(maxBytes),
                "--connect-timeout", String(UpdateDecision.connectTimeoutSeconds),
                "--max-time", String(seconds)
            ]
            // Manifest: `--location --max-redirs 0` — eine Umleitung endet mit
            // curl 47 (⇒ 12) statt mit Exit 0 und einem Rumpf in der Datei (⇒ 13).
            arguments += followRedirects ? ["--location"] : ["--location", "--max-redirs", "0"]
            arguments += ["-o", destination, url]
            let outcome = runner.run(executable: "curl", arguments: arguments)
            if outcome.didRun {
                return evaluate(outcome, tool: .curl, toolName: "curl", what: what).map { _ in .curl }
            }
            guard outcome.spawnErrno == ENOENT, only == nil else {
                emit(UpdateTexts.fetchToolNotRunnable(tool: "curl", reason: outcome.standardError))
                return .failure(Stop(code: .updateUnavailable))
            }
        }

        var arguments = [
            String(seconds), "wget",
            "--no-config", "--hsts-file=" + temporary + "/hsts",
            "-q", "--tries=1", "--timeout=" + String(UpdateDecision.connectTimeoutSeconds)
        ]
        if !followRedirects { arguments.append("--max-redirect=0") }
        arguments += ["-O", destination, url]
        let outcome = runner.run(executable: "timeout", arguments: arguments)
        guard outcome.didRun else {
            emit(UpdateTexts.fetchToolNotRunnable(tool: "timeout", reason: outcome.standardError))
            return .failure(Stop(code: .updateUnavailable))
        }
        // `timeout` meldet 127, wenn es `wget` nicht findet, 126, wenn es
        // `wget` nicht ausführen kann.
        if outcome.exitStatus == 127 {
            emit(UpdateTexts.noFetchTool)
            return .failure(Stop(code: .updateUnavailable))
        }
        return evaluate(outcome, tool: .wget, toolName: "wget", what: what).map { _ in .wget }
    }

    /// Ordnet einen Abruf-Rückgabecode 12 oder 13 zu (2b-Auflage 11).
    private func evaluate(
        _ outcome: CommandOutcome,
        tool: UpdateDecision.FetchTool,
        toolName: String,
        what: String
    ) -> Result<Void, Stop> {
        guard outcome.exitStatus != 0 else { return .success(()) }
        switch UpdateDecision.fetchFailure(tool: tool, exitStatus: outcome.exitStatus) {
        case .refused:
            emit(UpdateTexts.refusedFetch(what: what, tool: toolName, exitStatus: outcome.exitStatus))
            return .failure(Stop(code: .updateRefused))
        case .unavailable:
            emit(UpdateTexts.fetchFailed(
                what: what,
                tool: toolName,
                exitStatus: outcome.exitStatus,
                detail: firstLine(outcome.standardError)
            ))
            return .failure(Stop(code: .updateUnavailable))
        }
    }

    // MARK: - System

    /// glibc dieses Rechners über `confstr(_CS_GNU_LIBC_VERSION)` —
    /// `gnu_get_libc_version` steht im Swift-Modul `Glibc` nicht zur Verfügung.
    private func localGlibcVersion() -> String? {
        let name = Int32(_CS_GNU_LIBC_VERSION)
        let length = confstr(name, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(name, &buffer, length) > 0 else { return nil }
        return UpdateDecision.glibcVersion(fromConfstr: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    private struct TemporaryFailure: Error {
        let text: String
    }

    private func makeTemporaryDirectory() -> Result<String, TemporaryFailure> {
        var base = environment["TMPDIR"] ?? ""
        if !base.hasPrefix("/") { base = "/tmp" }
        while base.count > 1 && base.hasSuffix("/") { base.removeLast() }
        var template = Array((base + "/claude-monitor-tray-update.XXXXXX").utf8CString)
        let created = template.withUnsafeMutableBufferPointer { pointer -> Bool in
            guard let address = pointer.baseAddress else { return false }
            return mkdtemp(address) != nil
        }
        guard created else { return .failure(TemporaryFailure(text: errnoName(errno))) }
        return .success(template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
    }

    /// Kopiert das ausgepackte Binary in die Staging-Datei.
    ///
    /// `O_EXCL|O_NOFOLLOW`: Ein Rest aus einem Absturz wird vorher entfernt,
    /// ein Symlink am Staging-Pfad nie verfolgt. `fchmod` NACH dem Anlegen
    /// (2b-Auflage 8): Der Modus von `open` unterliegt der umask — unter
    /// `umask 077` entstünde 0700 statt 0755.
    ///
    /// - Returns: `nil` bei Erfolg, sonst der benannte Grund.
    private func stage(from source: String, to staging: String) -> String? {
        if unlink(staging) != 0 && errno != ENOENT { return errnoName(errno) }
        let input = open(source, O_RDONLY | O_CLOEXEC)
        guard input >= 0 else { return errnoName(errno) }
        defer { close(input) }
        let output = open(staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o755))
        guard output >= 0 else { return errnoName(errno) }
        defer { close(output) }

        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(input, base, raw.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return errnoName(errno)
            }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return write(output, base + offset, count - offset)
                }
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                return errnoName(errno)
            }
        }
        guard fchmod(output, 0o755) == 0 else { return errnoName(errno) }
        guard fsync(output) == 0 else { return errnoName(errno) }
        return nil
    }

    private func fileSize(_ path: String) -> Int? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Int(info.st_size)
    }

    private func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    private func parentDirectory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        let parent = String(path[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    private func lastComponent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    private func firstLine(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: "\n").first.map(String.init) ?? ""
    }

    private func errnoName(_ code: Int32) -> String {
        AutostartInstaller.errnoName(code)
    }
}
