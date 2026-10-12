import Foundation

public actor SyncClient {
    private let baseURL: URL
    private let session: URLSession
    private let store: SQLiteStore
    private let privacy: PrivacyBoundary
    private let encoder: JSONEncoder

    public init(baseURL: URL, store: SQLiteStore, privacy: PrivacyBoundary, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.store = store
        self.privacy = privacy
        self.session = session
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
    }

    public func syncPending() async throws {
        for observation in try await store.pendingObservations() {
            let correction = try await store.activeCorrection(at: observation.occurredAt)
            try await post(privacy.sanitize(observation, activeCorrection: correction), path: "v1/observations")
            try await store.markObservationSynced(id: observation.id)
        }
        for correction in try await store.pendingCorrections() {
            try await post(privacy.sanitize(correction), path: "v1/corrections")
            try await store.markCorrectionSynced(id: correction.id)
        }
    }

    private func post<T: Encodable & Sendable>(_ value: T, path: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(value)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
