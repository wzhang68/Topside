import Darwin
import Foundation
import TopsideCore

/// Agent processes that outlive the engine (design doc 8.1, verified in M0
/// with Spikes/m0-detach/detach.py).
///
/// A short-lived launcher (`bash`, in a new session, with job control on)
/// starts the wrapper in the background and exits at once, so the wrapper is
/// adopted by launchd and is never a descendant of the engine: tools that kill
/// a whole process tree (IDE task runners, process managers) cannot take the
/// agents down with the engine. Job control matters: without it bash would
/// start the background job with SIGINT ignored and stdin from /dev/null.
///
/// The wrapper records the agent's exit code in a file, so the code is known
/// to whichever engine is running when the agent ends. stdout goes straight to
/// a file, never through a pipe, so nothing breaks if the engine goes away.
public enum ProcessSupervisor {
    public struct Launched: Sendable, Equatable {
        public var pid: Int32
        public var startTime: Double
    }

    public enum Files {
        public static let events = "events.jsonl"
        public static let stderr = "stderr.log"
        public static let exitCode = "exit-code"
        public static let stdin = "stdin.txt"
        public static let pid = "pid"
    }

    /// Starts the wrapper as a background job in its own process group and
    /// reports its pid. `$@` is the agent command line.
    static let launcher = """
    set -m
    /bin/bash -c "$TOPSIDE_WRAPPER" topside-run "$@" < "$TOPSIDE_STDIN" >> "$TOPSIDE_EVENTS" 2>> "$TOPSIDE_STDERR" &
    printf '%s\\n' "$!" > "$TOPSIDE_PID_FILE"
    """

    /// Traps INT/TERM/HUP with a handler (not SIG_IGN, which the agent would
    /// inherit), so it outlives the agent long enough to record the exit code;
    /// bash defers the trap until the foreground child exits.
    static let wrapper = """
    trap ':' INT TERM HUP
    exit_file=$TOPSIDE_EXIT_FILE
    cd "$TOPSIDE_CWD" || exit 127
    unset TOPSIDE_WRAPPER TOPSIDE_STDIN TOPSIDE_EVENTS TOPSIDE_STDERR TOPSIDE_PID_FILE TOPSIDE_EXIT_FILE TOPSIDE_CWD
    "$@"
    code=$?
    printf '%s\\n' "$code" > "$exit_file.tmp" && mv -f "$exit_file.tmp" "$exit_file"
    exit "$code"
    """

    public struct SpawnError: Error, CustomStringConvertible {
        public var description: String
    }

    public static func spawnDetached(_ spec: ProcessSpec, runDirectory: URL) throws -> Launched {
        let fm = FileManager.default
        try fm.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let stdinPath = runDirectory.appendingPathComponent(Files.stdin).path
        try (spec.standardInput ?? "").write(toFile: stdinPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stdinPath)
        let eventsPath = runDirectory.appendingPathComponent(Files.events).path
        let stderrPath = runDirectory.appendingPathComponent(Files.stderr).path
        let pidPath = runDirectory.appendingPathComponent(Files.pid).path
        for path in [eventsPath, stderrPath] where !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? fm.removeItem(atPath: pidPath)

        var environment = spec.environment
        environment["TOPSIDE_WRAPPER"] = wrapper
        environment["TOPSIDE_STDIN"] = stdinPath
        environment["TOPSIDE_EVENTS"] = eventsPath
        environment["TOPSIDE_STDERR"] = stderrPath
        environment["TOPSIDE_PID_FILE"] = pidPath
        environment["TOPSIDE_EXIT_FILE"] = runDirectory.appendingPathComponent(Files.exitCode).path
        environment["TOPSIDE_CWD"] = spec.workingDirectory
        let argv = ["/bin/bash", "-c", launcher, "topside-launch", spec.executable] + spec.arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // New session (so terminal signals and the engine's own group never reach it),
        // default signal dispositions, empty mask, and no inherited file descriptors.
        let flags = Int32(POSIX_SPAWN_SETSID) | Int32(POSIX_SPAWN_SETSIGDEF) | Int32(POSIX_SPAWN_SETSIGMASK)
            | Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        posix_spawnattr_setflags(&attr, Int16(flags))
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attr, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)

        // The launcher's own output (only bash errors) goes to stderr.log.
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, stderrPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_addopen(&actions, 2, stderrPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)

        var launcherPID: pid_t = 0
        let rc = withCStrings(argv) { cArgv in
            withCStrings(envp) { cEnv in
                posix_spawn(&launcherPID, "/bin/bash", &actions, &attr, cArgv, cEnv)
            }
        }
        guard rc == 0 else { throw SpawnError(description: "posix_spawn failed: \(String(cString: strerror(rc)))") }
        // The launcher exits as soon as the job is in the background (milliseconds).
        var status: Int32 = 0
        while waitpid(launcherPID, &status, 0) < 0 && errno == EINTR {}

        guard let text = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw SpawnError(description: "The agent could not be started. \(stderrTail(in: runDirectory) ?? "")")
        }
        // If it has already finished (e.g. the command was not found), the
        // watcher sees it as gone and reads the recorded exit code.
        return Launched(pid: pid, startTime: startTime(of: pid) ?? 0)
    }

    /// Start time of a live (non-zombie) process, or nil.
    public static func startTime(of pid: Int32) -> Double? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        guard info.kp_proc.p_stat != SZOMB else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
    }

    /// True if `pid` is alive and is the same process that started at `startTime`
    /// (a recycled pid belongs to someone else).
    public static func isAlive(pid: Int32, startTime: Double) -> Bool {
        guard let now = ProcessSupervisor.startTime(of: pid) else { return false }
        return abs(now - startTime) < 0.001
    }

    /// Signal the run's whole process group (wrapper + agent + its children).
    @discardableResult
    public static func signal(pid: Int32, startTime: Double, _ sig: Int32) -> Bool {
        guard isAlive(pid: pid, startTime: startTime) else { return false }
        return killpg(pid, sig) == 0
    }

    public static func recordedExitCode(in runDirectory: URL) -> Int32? {
        let url = runDirectory.appendingPathComponent(Files.exitCode)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Last `lines` lines of the run's stderr, for failure details.
    public static func stderrTail(in runDirectory: URL, lines: Int = 15) -> String? {
        let url = runDirectory.appendingPathComponent(Files.stderr)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 16_384 ? size - 16_384 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        let tail = text.split(whereSeparator: \.isNewline).suffix(lines).joined(separator: "\n")
        return tail.isEmpty ? nil : tail
    }

    static func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}

/// Follows one run: new complete lines of events.jsonl as they are written
/// (file-system notifications, no polling), then the exit.
final class RunWatcher: @unchecked Sendable {
    enum Output: Sendable {
        case lines([Data], endOffset: UInt64)
        case exited(Int32?)
    }

    let stream: AsyncStream<Output>
    private let continuation: AsyncStream<Output>.Continuation
    private let directory: URL
    private let pid: Int32
    private let startTime: Double
    private let queue: DispatchQueue
    private var offset: UInt64
    private var fd: Int32 = -1
    private var reader: FileHandle?
    private var fileSource: DispatchSourceFileSystemObject?
    private var exitSource: DispatchSourceProcess?
    private var finished = false

    init(directory: URL, pid: Int32, startTime: Double, offset: UInt64) {
        self.directory = directory
        self.pid = pid
        self.startTime = startTime
        self.offset = offset
        self.queue = DispatchQueue(label: "topside.run.\(pid)")
        (stream, continuation) = AsyncStream.makeStream(of: Output.self)
    }

    func start() {
        queue.async { [self] in
            let path = directory.appendingPathComponent(ProcessSupervisor.Files.events).path
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            reader = FileHandle(forReadingAtPath: path)
            fd = open(path, O_RDONLY | O_EVTONLY)
            if fd >= 0 {
                let fs = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.extend, .write],
                                                                   queue: queue)
                fs.setEventHandler { [weak self] in self?.readNew(final: false) }
                fileSource = fs
                fs.resume()
            }
            readNew(final: false)

            guard ProcessSupervisor.isAlive(pid: pid, startTime: startTime) else {
                finish()
                return
            }
            let ps = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            ps.setEventHandler { [weak self] in self?.finish() }
            exitSource = ps
            ps.resume()
            // It may have exited between the check and the registration.
            if !ProcessSupervisor.isAlive(pid: pid, startTime: startTime) { finish() }
        }
    }

    /// Stop following without touching the process (the engine is going away).
    func cancel() {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            teardown()
            continuation.finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        var status: Int32 = 0
        _ = waitpid(pid, &status, WNOHANG)   // reap it if it was our child
        readNew(final: true)
        let code = ProcessSupervisor.recordedExitCode(in: directory)
        teardown()
        continuation.yield(.exited(code))
        continuation.finish()
    }

    private func teardown() {
        fileSource?.cancel()
        exitSource?.cancel()
        fileSource = nil
        exitSource = nil
        if fd >= 0 { close(fd); fd = -1 }
        try? reader?.close()
        reader = nil
    }

    /// Read from `offset` to EOF; emit complete lines. At the end, a trailing
    /// partial line is emitted too.
    private func readNew(final: Bool) {
        guard let handle = reader else { return }
        do { try handle.seek(toOffset: offset) } catch { return }
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty else { return }
        var consumed = data.count
        if !final, let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
            consumed = lastNewline + 1
        } else if !final {
            return   // no complete line yet
        }
        let chunk = data.prefix(consumed)
        let lines = chunk.split(separator: UInt8(ascii: "\n")).map { Data($0) }
        offset += UInt64(consumed)
        if !lines.isEmpty { continuation.yield(.lines(lines, endOffset: offset)) }
    }
}
