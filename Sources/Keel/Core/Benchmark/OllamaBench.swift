import Foundation

/// Local LLM throughput via the Ollama HTTP API (docs.ollama.com/api/generate). All durations are ns.
enum OllamaBench {
    struct Result: Sendable {
        let model: String
        let sizeGB: Double
        let generation: [Double]     // tok/s per timed run
        let prompt: [Double]         // prompt tok/s per timed run
        let coldStartS: Double?      // load_duration of the discarded warm-up
    }

    enum Unavailable: Error, LocalizedError {
        case notInstalled, notRunning, noModel, failed(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Ollama is not installed. Get it from ollama.com, then run: ollama pull qwen3:1.7b"
            case .notRunning: return "Ollama is installed but not running. Start the app or run: ollama serve"
            case .noModel: return "No model installed. Pull a small one: ollama pull qwen3:1.7b (1.4 GB) or qwen3:4b (2.5 GB)"
            case .failed(let s): return "Ollama request failed: \(s)"
            }
        }
    }

    static let base = "http://127.0.0.1:11434"
    static let installPaths = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/Applications/Ollama.app"]

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 300
        c.connectionProxyDictionary = [:]          // never route localhost through a proxy
        return URLSession(configuration: c)
    }()

    static func run(cancel: CancelFlag, progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        var tagsReq = URLRequest(url: URL(string: "\(base)/api/tags")!); tagsReq.timeoutInterval = 3
        guard let (data, _) = try? await session.data(for: tagsReq) else {
            throw installPaths.contains { FileManager.default.fileExists(atPath: $0) } ? Unavailable.notRunning : Unavailable.notInstalled
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else { throw Unavailable.failed("unexpected /api/tags reply") }
        // Embedding-only models cannot generate text.
        let usable = models.filter { m in
            let name = (m["name"] as? String ?? "").lowercased()
            let family = ((m["details"] as? [String: Any])?["family"] as? String ?? "").lowercased()
            return !name.contains("embed") && !family.contains("bert")
        }
        // Smallest model: quickest and least likely to swap on small Macs.
        guard let pick = usable.min(by: { (($0["size"] as? NSNumber)?.int64Value ?? .max) < (($1["size"] as? NSNumber)?.int64Value ?? .max) }),
              let name = pick["name"] as? String else { throw Unavailable.noModel }
        let size = Double((pick["size"] as? NSNumber)?.int64Value ?? 0) / 1e9

        struct Gen { let gen: Double; let prompt: Double?; let load: Double }
        func generate(_ i: Int) async throws -> Gen {
            var r = URLRequest(url: URL(string: "\(base)/api/generate")!)
            r.httpMethod = "POST"; r.timeoutInterval = 300
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // A different opening per run defeats Ollama's prompt cache, so prompt tok/s is real.
            let topics = ["the keel in shipbuilding", "lighthouses", "the printing press", "tide prediction", "early clocks"]
            let prompt = "Run \(i). Write a detailed 400 word essay about the history of \(topics[i % topics.count]). Cover origins, key inventions, the people involved and the lasting impact, in plain language."
            let body: [String: Any] = ["model": name, "prompt": prompt, "stream": false, "keep_alive": "5m",
                                       "options": ["num_predict": 200, "temperature": 0, "seed": 42]]
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (d, resp) = try await session.data(for: r)
            guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw Unavailable.failed("bad reply") }
            if let e = o["error"] as? String { throw Unavailable.failed(e) }
            guard (resp as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                  let ec = (o["eval_count"] as? NSNumber)?.doubleValue, let ed = (o["eval_duration"] as? NSNumber)?.doubleValue, ed > 0 else { throw Unavailable.failed("no timing in reply") }
            let pc = (o["prompt_eval_count"] as? NSNumber)?.doubleValue ?? 0, pd = (o["prompt_eval_duration"] as? NSNumber)?.doubleValue ?? 0
            let load = ((o["load_duration"] as? NSNumber)?.doubleValue ?? 0) / 1e9
            return Gen(gen: ec / ed * 1e9, prompt: pc > 0 && pd > 0 ? pc / pd * 1e9 : nil, load: load)
        }

        let warm = try await generate(0)        // loads the model and compiles Metal kernels; discarded
        progress(0.25)
        var gen: [Double] = [], prompt: [Double] = []
        for i in 1...3 {
            if cancel.isCancelled { throw BenchCancelled() }
            let g = try await generate(i)
            gen.append(g.gen); if let p = g.prompt { prompt.append(p) }
            progress(0.25 + 0.25 * Double(i))
        }
        return Result(model: name, sizeGB: size, generation: gen, prompt: prompt, coldStartS: warm.load > 0 ? warm.load : nil)
    }
}
