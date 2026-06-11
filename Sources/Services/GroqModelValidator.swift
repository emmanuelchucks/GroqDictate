import Foundation

enum GroqModelValidationResult: Equatable {
    case valid
    case invalidKey
    case accountRestricted
    case modelUnavailable
    case networkUnavailable
    case serviceUnavailable
    case other(String)
}

enum GroqModelValidator {
    private struct ModelsResponse: Decodable {
        struct Model: Decodable {
            let id: String
        }

        let data: [Model]
    }

    static func validate(
        apiKey: String,
        model: String,
        completion: @escaping (GroqModelValidationResult) -> Void
    ) {
        var request = URLRequest(url: AppConstants.URLs.groqModels)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12

        let session = URLSession(configuration: configuration)
        session.dataTask(with: request) { data, response, error in
            defer { session.invalidateAndCancel() }

            if let error = error as NSError? {
                AppLog.debug(
                    "model validation network unavailable error=\(GroqAPI.transportErrorName(for: error))",
                    category: .network
                )
                completion(.networkUnavailable)
                return
            }

            guard let http = response as? HTTPURLResponse else {
                completion(.networkUnavailable)
                return
            }

            let requestID = http.value(forHTTPHeaderField: "x-request-id") ?? "n/a"
            AppLog.metric(
                "groq_model_validation",
                category: .network,
                level: .debug,
                values: [
                    "model": model,
                    "request_id": requestID,
                    "status": String(http.statusCode)
                ]
            )

            switch http.statusCode {
            case 200:
                guard
                    let data,
                    let models = try? JSONDecoder().decode(ModelsResponse.self, from: data)
                else {
                    completion(.other("Invalid model response"))
                    return
                }

                completion(models.data.contains(where: { $0.id == model }) ? .valid : .modelUnavailable)
            case 401:
                completion(.invalidKey)
            case 403:
                completion(.accountRestricted)
            case 429, 498, 500, 502, 503, 504:
                completion(.networkUnavailable)
            default:
                let message = GroqAPI.parseAPIErrorMessage(from: data ?? Data()) ?? "HTTP \(http.statusCode)"
                completion(.other(message))
            }
        }.resume()
    }
}
