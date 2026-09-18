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

    init(exitStatus: Int32, standardOutput: String, standardError: String, didRun: Bool = true) {
        self.exitStatus = exitStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.didRun = didRun
    }

    /// Ein Ergebnis, das gar nicht erst zustande kam (Spawn/Pipe gescheitert).
    static func notRun(reason: String) -> CommandOutcome {
        CommandOutcome(exitStatus: -1, standardOutput: "", standardError: reason, didRun: false)
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
            return .notRun(reason: "spawn failed errno=\(spawnResult)")
        }

        // Nacheinander gelesen und nicht über `poll`: Die einzigen Befehle,
        // die hier laufen, sind `systemctl --user is-enabled/is-active/
        // daemon-reload/enable/disable`. Ihre Ausgabe ist ein paar Zeilen und
        // bleibt weit unter der Pipe-Puffergröße; ein Verklemmen setzte
        // voraus, dass der zweite Kanal 64 KiB füllt, während der erste noch
        // offen ist.
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
