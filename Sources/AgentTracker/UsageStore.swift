import Foundation
import SwiftUI

/// Owns all displayed state: Claude and Codex from their CLIs, and Grok
/// from the same weekly product split as grok.com Settings → Usage.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var limits: UsageLimits?
    @Published private(set) var localUsage: LocalUsage = .empty
    @Published private(set) var codexUsage: CodexUsage = .empty
    @Published private(set) var grokUsage: GrokUsage = .empty
    @Published private(set) var subscriptionType: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var grokErrorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var rateLimitedUntil: Date?
    @Published private(set) var grokRateLimitedUntil: Date?

    var isRateLimited: Bool {
        guard let rateLimitedUntil else { return false }
        return rateLimitedUntil > Date()
    }

    var isGrokRateLimited: Bool {
        guard let grokRateLimitedUntil else { return false }
        return grokRateLimitedUntil > Date()
    }

    private var timer: Timer?
    private static let refreshInterval: TimeInterval = 60
    /// Fallback backoff when a 429 doesn't include a Retry-After header.
    private static let defaultRateLimitBackoff: TimeInterval = 60

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
        let claudeLimited = isRateLimited
        let grokLimited = isGrokRateLimited
        Task {
            defer { isRefreshing = false }

            // Local log scans work even when the API/auth is unavailable, and
            // the Codex tab is served entirely from them. Grok is a network
            // call of its own, so a Claude backoff does not skip it.
            async let scanned = Task.detached(priority: .utility) {
                (claude: LocalUsageScanner.scan(), codex: CodexUsageScanner.scan())
            }.value
            async let grok = GrokUsageAPI.load(skipNetwork: grokLimited)

            let local = await scanned
            localUsage = local.claude
            codexUsage = local.codex
            apply(await grok)

            // Claude's usage API is the only rate-limited part of its refresh.
            // Credential loading never refreshes the token; the CLI owns that.
            if !claudeLimited {
                do {
                    let credentials = try CredentialsProvider.loadValid()
                    subscriptionType = credentials.subscriptionType?.uppercased()
                    limits = try await UsageAPI.fetchLimits(accessToken: credentials.accessToken)
                    errorMessage = nil
                    rateLimitedUntil = nil
                } catch UsageAPIError.rateLimited(let resetsAt) {
                    rateLimitedUntil = resetsAt ?? Date().addingTimeInterval(Self.defaultRateLimitBackoff)
                    errorMessage = UsageAPIError.rateLimited(resetsAt).localizedDescription
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            lastUpdated = Date()
        }
    }

    private func apply(_ result: GrokLoadResult) {
        if result.keepPrevious {
            if grokUsage.isSignedIn == false, let usage = result.usage, usage.isSignedIn {
                grokUsage = usage
            }
        } else if let usage = result.usage {
            if usage.hasSnapshot || !grokUsage.hasSnapshot || !usage.isSignedIn {
                grokUsage = usage
            } else {
                grokUsage = GrokUsage(
                    isSignedIn: usage.isSignedIn,
                    planType: usage.planType ?? grokUsage.planType,
                    weeklyPercent: grokUsage.weeklyPercent,
                    resetsAt: grokUsage.resetsAt,
                    products: grokUsage.products,
                    extraCreditsUSD: usage.extraCreditsUSD ?? grokUsage.extraCreditsUSD
                )
            }
        }
        if result.clearError {
            grokErrorMessage = nil
        } else if let errorMessage = result.errorMessage {
            grokErrorMessage = errorMessage
        }
        if result.clearRateLimit {
            grokRateLimitedUntil = nil
        } else if let until = result.rateLimitedUntil {
            grokRateLimitedUntil = until
        }
    }
}
