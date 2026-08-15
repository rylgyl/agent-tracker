import Foundation
import SwiftUI

/// Owns all displayed state: limit percentages from the OAuth usage API
/// plus token totals scanned from the CLI's local session logs.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var limits: UsageLimits?
    @Published private(set) var localUsage: LocalUsage = .empty
    @Published private(set) var subscriptionType: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?

    private var timer: Timer?
    private static let refreshInterval: TimeInterval = 60

    init() {
        refresh()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            defer { isRefreshing = false }

            // Local log scan works even when the API/auth is unavailable.
            let scanned = await Task.detached(priority: .utility) {
                LocalUsageScanner.scan()
            }.value
            localUsage = scanned

            do {
                let credentials = try await CredentialsProvider.loadValid()
                subscriptionType = credentials.subscriptionType?.uppercased()
                limits = try await UsageAPI.fetchLimits(accessToken: credentials.accessToken)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            lastUpdated = Date()
        }
    }
}
