import Foundation

/// The signed-in user's profile row (onboarding answers). Remote is the source of
/// truth; a per-user UserDefaults mirror keeps offline relaunches from re-showing
/// onboarding.
@MainActor
@Observable
final class UserProfileStore {
    static let shared = UserProfileStore()

    struct Profile: Codable, Sendable {
        var user_id: String
        var editing_domain: String?
        var onboarding_completed_at: Date?
    }

    private(set) var profile: Profile?
    private(set) var isLoaded = false

    private init() {}

    /// True when onboarding should be skipped for the current user.
    var isOnboarded: Bool {
        if profile?.onboarding_completed_at != nil { return true }
        guard let uid = SupabaseService.shared.currentUserId else { return false }
        return Self.localMirror(userId: uid.uuidString)
    }

    static func localMirror(userId: String) -> Bool {
        UserDefaults.standard.bool(forKey: "onboarded-\(userId)")
    }

    static func setLocalMirror(userId: String, onboarded: Bool) {
        UserDefaults.standard.set(onboarded, forKey: "onboarded-\(userId)")
    }

    /// Fetches the profile row; call after sign-in before routing. Failure (offline)
    /// leaves the local mirror in charge.
    func load() async {
        defer { isLoaded = true }
        profile = nil
        guard let uid = SupabaseService.shared.currentUserId else { return }
        do {
            let rows: [Profile] = try await SupabaseService.shared.client
                .from("user_profiles")
                .select("user_id, editing_domain, onboarding_completed_at")
                .eq("user_id", value: uid.uuidString)
                .execute()
                .value
            profile = rows.first
            if profile?.onboarding_completed_at != nil {
                Self.setLocalMirror(userId: uid.uuidString, onboarded: true)
            }
        } catch {
            Log.account.warning("profile load failed: \(error.localizedDescription)")
        }
    }

    func saveEditingDomain(_ domain: String) {
        guard let uid = SupabaseService.shared.currentUserId else { return }
        var p = profile ?? Profile(user_id: uid.uuidString)
        p.editing_domain = domain
        profile = p
        upsert(p)
    }

    func markOnboarded() {
        guard let uid = SupabaseService.shared.currentUserId else { return }
        var p = profile ?? Profile(user_id: uid.uuidString)
        p.onboarding_completed_at = Date()
        profile = p
        Self.setLocalMirror(userId: uid.uuidString, onboarded: true)
        upsert(p)
    }

    private func upsert(_ p: Profile) {
        let client = SupabaseService.shared.client
        Task.detached(priority: .utility) {
            do {
                try await client.from("user_profiles").upsert(p).execute()
            } catch {
                Log.account.warning("profile upsert failed: \(error.localizedDescription)")
            }
        }
    }
}
