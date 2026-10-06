import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Das Ergebnis eines Fremdprozesses.
///
/// Es trägt **beide** Kanäle und den Rückgabecode, weil die Auswertung in
/// ``AutostartStatus`` genau diese drei braucht: `systemctl --user is-enabled`
/// antwortet ohne Nutzermanager mit leerem stdout, einer Verbindungsmeldung
/// auf stderr und rc=1 — an der Textausgabe allein ist das nicht von
/// „nicht eingerichtet" zu unterscheiden.
struct CommandOutcome: Equatable {
    let exitStatus: Int32
    let standardOutput: String
    let standardError: String
    /// Ob der Fremdprozess tatsächlich gestartet wurde. `false` bei
    /// ``notRun(reason:)`` — dann ist `standardError` der echte Ausfallgrund
    /// (z. B. „spawn failed errno=2") und darf nicht als Antwort von
    /// `systemctl` selbst gelesen werden.
    let didRun: Bool
    /// Der `errno` von `posix_spawnp`, wenn der Start daran scheiterte.
    ///
    /// CM-29: `ENOENT` heißt „Werkzeug nicht installiert" — nur dann darf der
    /// Update-Abruf von `curl` auf `wget` ausweichen (2b-Auflage 3), nie nach
    /// einem gescheiterten `curl`-Lauf.
    let spawnErrno: Int32?

    init(
        exitStatus: Int32,
        standardOutput: String,
        standardError: String,
        didRun: Bool = true,
        spawnErrno: Int32? = nil
    ) {
        self.exitStatus = exitStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.didRun = didRun
        self.spawnErrno = spawnErrno
    }

    /// Ein Ergebnis, das gar nicht erst zustande kam (Spawn/Pipe gescheitert).
    static func notRun(reason: String, spawnErrno: Int32? = nil) -> CommandOutcome {
        CommandOutcome(exitStatus: -1, standardOutput: "", standardError: reason, didRun: false, spawnErrno: spawnErrno)
    }
}

/// Die EINE Stelle, an der dieser Prozess einen Fremdprozess startet.
///
/// Als Protokoll, damit die Regeln darüber ohne `systemctl` prüfbar bleiben:
/// Der dokumentierte Bau-/Testcontainer (`swift:6.3.3`) hat weder `systemctl`
/// noch `/run/systemd/system` — gemessen. Ein Test, der hier einen echten
/// Aufruf bräuchte, wäre dort nicht lauffähig.
protocol CommandRunner {
    func run(executable: String, arguments: [String]) -> CommandOutcome
}

/// Stand eines im Hintergrund gestarteten Kindes.
enum BackgroundPoll: Equatable {
    case running
    /// Beendet; Signaltod und nicht abholbar ⇒ `-1` (wie `exitStatus(from:)`).
    case exited(Int32)
}

/// Die EINE Stelle, an der dieser Prozess ein Kind startet, **ohne auf es zu
/// warten** (CM-37: „Check for updates now"). Eine Naht neben ``CommandRunner``,
/// der blockierend wartet (`PosixCommandRunner.run`): Ein `--update` dauert
/// bis zu Minuten (Manifest 120 s + Tarball 600 s, `UpdateUnits.swift:25-29`),
/// die Gegenstelle des Menüs gibt nach 10 s auf.
protocol BackgroundStarter {
    /// Startet `executable` (absoluter Pfad) mit `arguments`; `nil`, wenn der
    /// Start scheiterte.
    func start(executable: String, arguments: [String]) -> pid_t?
    /// Holt das Kind ab, falls es beendet ist — ohne zu blockieren.
    func poll(_ pid: pid_t) -> BackgroundPoll
}

/// Standard-Implementierung über `posix_spawn` und `waitpid(WNOHANG)`.
///
/// Bewusst **ohne** `posix_spawnattr` (2b-Mitnahme 3): Das Kind erbt die
/// Prozessgruppe des Trays und das ignorierte `SIGPIPE` (`main.swift`,
/// `signal(SIGPIPE, SIG_IGN)`; `execve` behält ignorierte Signale). Beides ist
/// harmlos — die Staging-Datei räumt der nächste Lauf weg
/// (`UpdateClient.swift:388`), Temp liegt unter `$TMPDIR`/`/tmp`. Folge, als
/// Ergänzung zu FE 12: Strg-C am Terminal-Tray beendet auch eine laufende
/// Prüfung. Am Verhalten ändert sich dadurch nichts.
struct PosixBackgroundStarter: BackgroundStarter {

    /// Die Umgebung des Kindes — die des Trays.
    let environment: [String: String]
    /// Für die Zeile bei einem nicht abholbaren Kind.
    let log: (String) -> Void

    func start(executable: String, arguments: [String]) -> pid_t? {
        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // stdin = /dev/null; stdout und stderr erbt das Kind (Journal bzw.
        // Terminal des Trays, FE 11).
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
            for pointer in envp where pointer != nil { free(pointer) }
        }

        var pid: pid_t = 0
        // Absoluter Pfad, nicht `posix_spawnp`: gestartet wird genau dieses Binary.
        guard posix_spawn(&pid, executable, &actions, nil, argv, envp) == 0 else { return nil }
        return pid
    }

    func poll(_ pid: pid_t) -> BackgroundPoll {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == 0 { return .running }
            if result == pid {
                return .exited((status & 0x7f) == 0 ? (status >> 8) & 0xff : -1)
            }
            if errno == EINTR { continue }
            // 2b-Auflage 2: `-1` mit errno ≠ EINTR (z. B. ECHILD) — das Kind ist
            // nicht mehr abholbar. Es gibt keinen Pfad, auf dem „läuft" ohne
            // lebendes Kind bestehen bleibt: Menü zeigt „could not run".
            log("update=check exit=-1 errno=\(errno)")
            return .exited(-1)
        }
    }
}

/// Die Standard-Implementierung über `posix_spawnp`.
struct PosixCommandRunner: CommandRunner {

    /// Die Umgebung, die das Kind bekommt — dieselbe, aus der auch die Pfade
    /// abgeleitet werden. Zwei getrennt ermittelte Umgebungen gingen im
    /// Container auseinander.
    let environment: [String: String]

    func run(executable: String, arguments: [String]) -> CommandOutcome {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { return .notRun(reason: "pipe failed errno=\(errno)") }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            return .notRun(reason: "pipe failed errno=\(errno)")
        }

        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addclose(&actions, outPipe[0])
        posix_spawn_file_actions_addclose(&actions, errPipe[0])
        posix_spawn_file_actions_addclose(&actions, outPipe[1])
        posix_spawn_file_actions_addclose(&actions, errPipe[1])

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
            for pointer in envp where pointer != nil { free(pointer) }
        }

        var pid: pid_t = 0
        let spawnResult = posix_spawnp(&pid, executable, &actions, nil, argv, envp)
        posix_spawn_file_actions_destroy(&actions)
        close(outPipe[1])
        close(errPipe[1])
        guard spawnResult == 0 else {
            close(outPipe[0]); close(errPipe[0])
            return .notRun(reason: "spawn failed errno=\(spawnResult)", spawnErrno: spawnResult)
        }

        // Nacheinander gelesen und nicht über `poll`: Die einzigen Befehle,
        // die hier laufen, sind `systemctl --user is-enabled/is-active/
        // daemon-reload/enable/disable/stop/try-restart` und `show -p …`,
        // seit CM-29 außerdem `curl`, `timeout … wget`, `sha256sum`, `tar` und
        // `timeout … <neues Binary> --version`. Ihre Ausgabe ist ein paar
        // Zeilen und bleibt weit unter der Pipe-Puffergröße — die Abrufe
        // schreiben per `-o`/`-O` in Dateien, nicht nach stdout; ein Verklemmen
        // setzte voraus, dass der zweite Kanal 64 KiB füllt, während der erste
        // noch offen ist.
        let output = readAll(descriptor: outPipe[0])
        let errorOutput = readAll(descriptor: errPipe[0])
        close(outPipe[0])
        close(errPipe[0])

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR { continue }
        return CommandOutcome(
            exitStatus: exitStatus(from: status),
            standardOutput: output,
            standardError: errorOutput
        )
    }

    /// `WIFEXITED`/`WEXITSTATUS` von Hand — die Makros stehen Swift nicht zur
    /// Verfügung. Durch ein Signal beendet ⇒ `-1`, damit ein Signaltod nie als
    /// gültiger Rückgabecode durchgeht.
    private func exitStatus(from raw: Int32) -> Int32 {
        (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : -1
    }

    private func readAll(descriptor: Int32) -> String {
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return read(descriptor, base, raw.count)
            }
            if count > 0 {
                bytes.append(contentsOf: buffer[0..<count])
                continue
            }
            if count < 0 && errno == EINTR { continue }
            break
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
