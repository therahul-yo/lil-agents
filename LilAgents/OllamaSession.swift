import Foundation

class OllamaSession: AgentSession {
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var lineBuffer = ""
    private(set) var isRunning = false
    private(set) var isBusy = false

    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onToolUse: ((String, [String: Any]) -> Void)?
    var onToolResult: ((String, Bool) -> Void)?
    var onSessionReady: (() -> Void)?
    var onTurnComplete: (() -> Void)?
    var onProcessExit: (() -> Void)?

    var history: [AgentMessage] = []

    // MARK: - Ollama Configuration (stored in UserDefaults)

    private static let defaultsKeyEndpoint = "ollamaEndpoint"
    private static let defaultsKeyModel = "ollamaModel"
    private static let defaultsKeyUseClaudeCode = "ollamaUseClaudeCode"

    static var endpoint: String {
        get { UserDefaults.standard.string(forKey: defaultsKeyEndpoint) ?? "http://localhost:11434" }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKeyEndpoint) }
    }

    static var model: String {
        get { UserDefaults.standard.string(forKey: defaultsKeyModel) ?? "llama3" }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKeyModel) }
    }

    /// When true, launches Claude Code CLI with Ollama as backend via ANTHROPIC_BASE_URL
    /// When false, uses direct Ollama REST API
    static var useClaudeCode: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKeyUseClaudeCode) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKeyUseClaudeCode) }
    }

    // MARK: - Process Lifecycle

    func start() {
        if Self.useClaudeCode {
            startWithClaudeCode()
        } else {
            startDirectAPI()
        }
    }

    // MARK: - Mode 1: Claude Code + Ollama Backend

    private func startWithClaudeCode() {
        // Find claude binary
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        ShellEnvironment.findBinary(name: "claude", fallbackPaths: [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude"
        ]) { [weak self] path in
            guard let self = self, let binaryPath = path else {
                let msg = "Claude CLI not found.\n\nTo install:\n  curl -fsSL https://claude.ai/install.sh | sh\n\nOr use Direct API mode (configure in settings)."
                self?.onError?(msg)
                self?.history.append(AgentMessage(role: .error, text: msg))
                return
            }
            self.launchClaudeCodeWithOllama(binaryPath: binaryPath)
        }
    }

    private func launchClaudeCodeWithOllama(binaryPath: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)

        let endpoint = Self.endpoint
        let model = Self.model

        // Claude Code CLI flags
        proc.arguments = [
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose",
            "--dangerously-skip-permissions",
            "--model", model
        ]
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        // Set environment to point Claude Code at Ollama
        var env = ShellEnvironment.processEnvironment()
        env["ANTHROPIC_BASE_URL"] = "\(endpoint)/v1"
        env["ANTHROPIC_API_KEY"] = "ollama"  // Ollama doesn't need a real key
        proc.environment = env

        setupPipesAndLaunch(proc: proc)
    }

    // MARK: - Mode 2: Direct Ollama REST API

    private func startDirectAPI() {
        isRunning = true
        // Verify Ollama is reachable
        checkConnection { [weak self] success in
            DispatchQueue.main.async {
                if success {
                    self?.onSessionReady?()
                } else {
                    let endpoint = OllamaSession.endpoint
                    let msg = "Could not connect to Ollama at \(endpoint).\n\nMake sure Ollama is running:\n  ollama serve\n\nOr set a custom endpoint in settings."
                    self?.onError?(msg)
                    self?.history.append(AgentMessage(role: .error, text: msg))
                }
            }
        }
    }

    private func checkConnection(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(Self.endpoint)/api/tags") else {
            completion(false)
            return
        }
        URLSession.shared.dataTask(with: url) { _, response, _ in
            completion((response as? HTTPURLResponse)?.statusCode == 200)
        }.resume()
    }

    // MARK: - Shared Pipe Setup (for Claude Code mode)

    private func setupPipesAndLaunch(proc: Process) {
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.isBusy = false
                self?.onProcessExit?()
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self?.processOutput(text)
                }
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self?.onError?(text)
                }
            }
        }

        do {
            try proc.run()
            process = proc
            inputPipe = inPipe
            outputPipe = outPipe
            errorPipe = errPipe
            isRunning = true
        } catch {
            let msg = "Failed to launch with Ollama backend.\n\nError: \(error.localizedDescription)\n\nMake sure Ollama is running:\n  ollama serve"
            onError?(msg)
            history.append(AgentMessage(role: .error, text: msg))
        }
    }

    // MARK: - Send (handles both modes)

    func send(message: String) {
        guard isRunning else { return }
        isBusy = true
        history.append(AgentMessage(role: .user, text: message))

        if Self.useClaudeCode {
            sendViaClaudeCode(message: message)
        } else {
            sendViaDirectAPI(message: message)
        }
    }

    private func sendViaClaudeCode(message: String) {
        guard let pipe = inputPipe else { return }
        let payload: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": message]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonStr = String(data: data, encoding: .utf8) else { return }
        pipe.fileHandleForWriting.write((jsonStr + "\n").data(using: .utf8)!)
    }

    private func sendViaDirectAPI(message: String) {
        // Build messages from history
        var messages: [[String: String]] = []
        for msg in history {
            switch msg.role {
            case .user:
                messages.append(["role": "user", "content": msg.text])
            case .assistant:
                messages.append(["role": "assistant", "content": msg.text])
            default: break
            }
        }

        guard let url = URL(string: "\(Self.endpoint)/api/chat") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["model": Self.model, "messages": messages, "stream": true]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.isBusy = false
                    self?.onError?("Ollama error: \(error.localizedDescription)")
                    self?.onTurnComplete?()
                    return
                }
                guard let data = data, let str = String(data: data, encoding: .utf8) else {
                    self?.isBusy = false
                    self?.onError?("No response from Ollama")
                    self?.onTurnComplete?()
                    return
                }
                self?.parseDirectAPIResponse(str)
            }
        }.resume()
    }

    private func parseDirectAPIResponse(_ text: String) {
        var fullResponse = ""
        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? String {
                fullResponse += content
            }
            if json["done"] as? Bool == true { break }
        }
        if !fullResponse.isEmpty {
            onText?(fullResponse)
            history.append(AgentMessage(role: .assistant, text: fullResponse))
        }
        isBusy = false
        onTurnComplete?()
    }

    // MARK: - Output Processing (Claude Code mode — same as ClaudeSession)

    private func processOutput(_ text: String) {
        lineBuffer += text
        while let range = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[lineBuffer.startIndex..<range.lowerBound])
            lineBuffer = String(lineBuffer[range.upperBound...])
            if !line.isEmpty { parseLine(line) }
        }
    }

    private func parseLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        switch json["type"] as? String ?? "" {
        case "system":
            if json["subtype"] as? String == "init" { onSessionReady?() }

        case "assistant":
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    if block["type"] as? String == "text", let text = block["text"] as? String {
                        onText?(text)
                    } else if block["type"] as? String == "tool_use" {
                        let name = block["name"] as? String ?? "Tool"
                        let input = block["input"] as? [String: Any] ?? [:]
                        onToolUse?(name, input)
                    }
                }
            }

        case "user":
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    if block["type"] as? String == "tool_result" {
                        let isError = block["is_error"] as? Bool ?? false
                        let summary = (block["content"] as? String ?? "").prefix(80)
                        onToolResult?(String(summary), isError)
                    }
                }
            }

        case "result":
            isBusy = false
            if let result = json["result"] as? String, !result.isEmpty {
                history.append(AgentMessage(role: .assistant, text: result))
            }
            onTurnComplete?()

        default: break
        }
    }

    // MARK: - Terminate

    func terminate() {
        process?.terminate()
        isRunning = false
        isBusy = false
    }
}
