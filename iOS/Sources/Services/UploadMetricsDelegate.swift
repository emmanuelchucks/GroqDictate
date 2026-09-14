import Foundation

/// Per-task observer: records connection behavior without changing request policy.
final class UploadMetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    struct Transaction: Codable {
        let index: Int
        let fetchStart: Double?
        let dnsStart: Double?
        let dnsEnd: Double?
        let connectStart: Double?
        let connectEnd: Double?
        let tlsStart: Double?
        let tlsEnd: Double?
        let uploadStart: Double?
        let uploadEnd: Double?
        let responseStart: Double?
        let responseEnd: Double?
        let reusedConnection: Bool
        let proxyConnection: Bool
        let cellular: Bool
        let expensive: Bool
        let constrained: Bool
        let protocolName: String?
        let fetchType: Int
        let bytesSent: Int64
        let bytesReceived: Int64
        let status: Int?
        let serverRequestID: String?

        init(_ metric: URLSessionTaskTransactionMetrics, index: Int, origin: Date) {
            self.index = index
            func offset(_ date: Date?) -> Double? { date.map { $0.timeIntervalSince(origin) } }
            fetchStart = offset(metric.fetchStartDate)
            dnsStart = offset(metric.domainLookupStartDate)
            dnsEnd = offset(metric.domainLookupEndDate)
            connectStart = offset(metric.connectStartDate)
            connectEnd = offset(metric.connectEndDate)
            tlsStart = offset(metric.secureConnectionStartDate)
            tlsEnd = offset(metric.secureConnectionEndDate)
            uploadStart = offset(metric.requestStartDate)
            uploadEnd = offset(metric.requestEndDate)
            responseStart = offset(metric.responseStartDate)
            responseEnd = offset(metric.responseEndDate)
            reusedConnection = metric.isReusedConnection
            proxyConnection = metric.isProxyConnection
            cellular = metric.isCellular
            expensive = metric.isExpensive
            constrained = metric.isConstrained
            protocolName = ["h2", "h3", "http/1.1", "http/1.0"].contains(metric.networkProtocolName ?? "") ? metric.networkProtocolName : nil
            fetchType = metric.resourceFetchType.rawValue
            bytesSent = metric.countOfRequestBodyBytesSent
            bytesReceived = metric.countOfResponseBodyBytesReceived
            let response = metric.response as? HTTPURLResponse
            status = response?.statusCode
            serverRequestID = Self.safeRequestID(response?.value(forHTTPHeaderField: "x-request-id"))
        }

        static func safeRequestID(_ value: String?) -> String? {
            guard let value, !value.isEmpty, value.utf8.count <= 128,
                  value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
            return value
        }
    }

    private let requestID: UUID
    private let sessionID: UUID?
    private let attempt: Int

    init(requestID: UUID, sessionID: UUID?, attempt: Int) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.attempt = attempt
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        // Each transaction is a bounded row, including incomplete phases on failed requests.
        for (index, metric) in metrics.transactionMetrics.enumerated() {
            TimingDiagnostics.shared.record(.transactionMetrics, requestID: requestID, sessionID: sessionID,
                                            attempt: attempt, elapsedSeconds: metrics.taskInterval.duration,
                                            transaction: Transaction(metric, index: index, origin: metrics.taskInterval.start))
        }
    }
}
