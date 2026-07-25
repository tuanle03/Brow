import Foundation

enum BridgePost {
    /// Blocking POST. `timeout` is long for interactive events so the agent waits for the user.
    static func send(source: String, payload: Data, context: HookRuntimeContext, timeout: TimeInterval) -> Data? {
        var envelope: [String: Any] = ["source": source]
        envelope["payload"] = (try? JSONSerialization.jsonObject(with: payload)) ?? String(data: payload, encoding: .utf8) ?? ""
        if let ctx = try? JSONEncoder().encode(context),
           let ctxObj = try? JSONSerialization.jsonObject(with: ctx) {
            envelope["context"] = ctxObj
        }
        guard let body = try? JSONSerialization.data(withJSONObject: envelope) else { return nil }

        var req = URLRequest(url: URL(string: "http://127.0.0.1:21064/event")!)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: req) { data, _, _ in result = data; sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        return result
    }
}
