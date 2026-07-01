import AppKit
import SwiftUI

struct SignInView: View {
    private var auth = SupabaseService.shared

    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var mode: Mode = .signIn

    private enum Mode { case signIn, signUp }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.lg) {
            VStack(spacing: AppTheme.Spacing.xs) {
                Text("Kawenreel")
                    .font(.system(size: AppTheme.FontSize.xl, weight: .bold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(mode == .signIn ? "Sign in to continue" : "Create your account")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }

            VStack(spacing: AppTheme.Spacing.smMd) {
                field("Email", text: $email, secure: false)
                field("Password", text: $password, secure: true)
            }

            if let error {
                Text(error)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
            }

            Button(action: submit) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    if isWorking { ProgressView().controlSize(.small) }
                    Text(mode == .signIn ? "Sign In" : "Sign Up")
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.Accent.primary)
            .disabled(isWorking || email.isEmpty || password.isEmpty)

            Button(mode == .signIn ? "Need an account? Sign up" : "Have an account? Sign in") {
                error = nil
                mode = mode == .signIn ? .signUp : .signIn
            }
            .buttonStyle(.plain)
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(AppTheme.Accent.primary)
        }
        .padding(AppTheme.Spacing.xxl)
        .frame(width: 360)
        .background(.ultraThinMaterial)
    }

    private func field(_ placeholder: String, text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure {
                SecureField(placeholder, text: text).onSubmit(submit)
            } else {
                TextField(placeholder, text: text)
                    .textContentType(.username)
                    .onSubmit(submit)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: AppTheme.FontSize.md))
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(Color.black.opacity(AppTheme.Opacity.muted)))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin))
    }

    private func submit() {
        guard !isWorking, !email.isEmpty, !password.isEmpty else { return }
        isWorking = true
        error = nil
        Task {
            do {
                if mode == .signIn {
                    try await auth.signIn(email: email, password: password)
                } else {
                    try await auth.signUp(email: email, password: password)
                }
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }
}

final class SignInWindowController: NSWindowController {
    static let shared = SignInWindowController()

    private init() {
        let hosting = NSHostingController(rootView: SignInView().tint(AppTheme.Accent.primary))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Sign In"
        // No .closable: the gate can't be dismissed while signed out.
        window.styleMask = [.titled, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = AppTheme.Background.base.withAlphaComponent(0.4)
        window.isOpaque = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Routes the visible window based on auth state. Owns the gate so launch shows
/// sign-in until a session is restored or created.
@MainActor
enum AuthCoordinator {
    static func start() {
        SupabaseService.shared.onAuthChange = route(signedIn:)
        SupabaseService.shared.start()
    }

    private static func route(signedIn: Bool) {
        if signedIn {
            SignInWindowController.shared.close()
            HomeWindowController.shared.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Signed out: show the gate and close every other window so no
            // feature surface (home, editors, settings) remains reachable.
            SignInWindowController.shared.showWindow(nil)
            let gate = SignInWindowController.shared.window
            for window in NSApp.windows where window !== gate {
                window.close()
            }
            gate?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
