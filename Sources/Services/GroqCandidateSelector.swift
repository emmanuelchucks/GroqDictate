import Foundation

enum GroqCandidateSelector {
    final class Request {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false

        func setTask(_ task: URLSessionTask) {
            lock.lock()
            self.task = task
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel { task.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = task
            lock.unlock()
            task?.cancel()
        }
    }

    static func select(
        raw: String,
        hinted: String,
        apiKey: String,
        completion: @escaping (String?) -> Void
    ) -> Request {
        let handle = Request()
        let startedAt = CFAbsoluteTimeGetCurrent()
        var request = URLRequest(url: AppConstants.URLs.groqChatCompletions)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let system = """
        Select the more faithful verbatim transcription of the same recording. Return exactly A or B.
        Prioritize preserved meaning, complete clauses, repetitions, and technical terms. Penalize invented,
        omitted, rewritten, or polished content. Punctuation alone is not important. If B is not clearly more
        faithful than A, return A. Never merge, edit, explain, or reproduce either transcript.
        """
        let body: [String: Any] = [
            "model": "openai/gpt-oss-120b",
            "temperature": 0,
            "max_completion_tokens": 64,
            "reasoning_effort": "low",
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": "A:\n\(raw)\n\nB:\n\(hinted)"]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            completion(nil)
            return handle
        }
        request.httpBody = data

        let session = URLSession(configuration: GroqAPI.makeTranscriptionSessionConfiguration())
        let task = session.dataTask(with: request) { data, response, error in
            defer { session.invalidateAndCancel() }
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
            let http = response as? HTTPURLResponse
            let requestID = http?.value(forHTTPHeaderField: "x-request-id") ?? "n/a"
            let choice = error == nil && http?.statusCode == 200
                ? parseChoice(from: data ?? Data())
                : nil

            AppLog.metric(
                "transcription_candidate_selection",
                category: .network,
                level: .debug,
                values: [
                    "choice": choice ?? "fallback_raw",
                    "request_id": requestID,
                    "status": http.map { String($0.statusCode) } ?? "n/a",
                    "total_ms": String(format: "%.0f", elapsedMs)
                ]
            )
            completion(choice)
        }
        handle.setTask(task)
        task.resume()
        return handle
    }

    static func parseChoice(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else { return nil }

        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized == "A" || normalized == "B" ? normalized : nil
    }
}
