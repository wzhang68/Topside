import Foundation
import Testing
@testable import TopsideEngine

@Suite struct LoginEnvironmentTests {
    /// A zsh whose startup files are ours: ZDOTDIR points at a temporary directory.
    private func zdotdir(profile: String, rc: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("topside-zdot-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try profile.write(to: dir.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        try rc.write(to: dir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func readsProfileAndRcAndIgnoresWhatTheyPrint() async throws {
        let dir = try zdotdir(profile: "export PATH=/from/profile:$PATH\necho 'Welcome!'\n",
                              rc: "export PATH=/from/rc:$PATH\nexport MULTI=$'a\\nb'\nprintf 'rc says hi'\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "ZDOTDIR": dir.path]
        let env = try #require(await LoginEnvironment.capture(shell: "/bin/zsh", base: base))
        #expect(env["PATH"]?.hasPrefix("/from/rc:/from/profile:") == true)
        #expect(env["MULTI"] == "a\nb")
    }

    @Test func aHangingShellTimesOut() async throws {
        let dir = try zdotdir(profile: "", rc: "sleep 30\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date()
        let env = await LoginEnvironment.capture(shell: "/bin/zsh", base: ["PATH": "/usr/bin:/bin", "ZDOTDIR": dir.path],
                                                 timeout: 1)
        #expect(env == nil)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func topsideSettingsFromTheAppWin() {
        let merged = LoginEnvironment.merge(
            shell: ["PATH": "/a", "TOPSIDE_HOME": "/shell", "SHLVL": "2", "EDITOR": "vim"],
            process: ["PATH": "/usr/bin", "TOPSIDE_HOME": "/app", "FAKE_AGENT_DELAY": "1", "OTHER": "x"])
        #expect(merged == ["PATH": "/a", "TOPSIDE_HOME": "/app", "FAKE_AGENT_DELAY": "1", "EDITOR": "vim"])
    }

    @Test func fallbackAddsCommonInstallLocations() {
        let env = LoginEnvironment.withCommonPaths(["PATH": "/usr/bin:/bin:/opt/homebrew/bin"])
        let path = env["PATH"]!.split(separator: ":").map(String.init)
        #expect(path.first == "/usr/local/bin")
        #expect(path.filter { $0 == "/opt/homebrew/bin" }.count == 1)
        #expect(path.contains("/usr/bin"))
    }

    @Test func outputWithoutMarkersIsRejected() {
        #expect(LoginEnvironment.parse("PATH=/x\0", marker: "M") == nil)
        #expect(LoginEnvironment.parse("junkMHOME=/h\0M", marker: "M") == nil)   // no PATH
        #expect(LoginEnvironment.parse("junkMPATH=/x\0A=b=c\0M", marker: "M") == ["PATH": "/x", "A": "b=c"])
    }
}
