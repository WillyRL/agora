import AgoraCore
import SwiftUI
import WebKit

/// Logs in to Cloudflare Access for a Hermes behind a Cloudflare Tunnel, either in your own browser
/// (Cloudflare hands the token back to Agora, as with `cloudflared access login`) or on Cloudflare's
/// login page inside Agora. Agora keeps the token in the Keychain. Remembers which you chose.
struct AccessLoginSheet: View {
    @Environment(AgoraCore.self) private var core
    let origin: URL
    let onToken: (String) -> Void
    let onCancel: () -> Void
    @AppStorage("agora.accessLoginInBrowser") private var inBrowser = true
    @State private var loading = true
    @State private var attempt = 0
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield").font(.system(size: 20)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Log in to \(origin.host ?? "Hermes")").font(.system(size: 14, weight: .semibold))
                    Text("This Hermes is behind Cloudflare Access. Agora keeps the login in your Keychain.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !inBrowser {
                    if loading { ProgressView().controlSize(.small) }
                    Button {
                        inBrowser = true
                    } label: {
                        Label("Use My Browser", systemImage: "safari")
                    }
                    .help("Log in in your default browser instead")
                }
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            if inBrowser {
                waitingForBrowser
            } else {
                AccessLoginWebView(origin: origin, loading: $loading, onToken: onToken)
            }
        }
        .frame(width: 540, height: inBrowser ? 330 : 660)
        .task(id: inBrowser ? attempt : -1) {
            guard inBrowser, DebugSnapshot.prefix == nil else { return }
            error = nil
            do {
                let token = try await core.accessTokenFromBrowser(for: origin) { url in
                    Task { @MainActor in NSWorkspace.shared.open(url) }
                }
                onToken(token)
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    var waitingForBrowser: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "safari").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Finish logging in in your browser").font(.system(size: 15, weight: .semibold))
            Text("When Cloudflare says you're logged in, come back here. Agora picks the login up by itself.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).multilineTextAlignment(.center)
            } else {
                ProgressView().controlSize(.small)
            }
            HStack(spacing: 10) {
                Button("Open Browser Again") { attempt += 1 }
                Button("Log In Here Instead") { inBrowser = false }
            }
            Spacer()
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
    }
}

/// A Cloudflare Access login to show (sheet item).
struct AccessLoginTarget: Identifiable {
    let origin: URL
    var id: URL { origin }
}

struct AccessLoginWebView: NSViewRepresentable {
    let origin: URL
    @Binding var loading: Bool
    let onToken: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Kept between logins, so your identity provider remembers you and the next login is quick.
        config.websiteDataStore = .default()
        // Some identity providers (Google) turn away pages that don't look like a browser.
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        context.coordinator.start(web)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.stopLoading()
        web.configuration.websiteDataStore.httpCookieStore.remove(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        var parent: AccessLoginWebView
        weak var web: WKWebView?
        var done = false

        init(_ parent: AccessLoginWebView) { self.parent = parent }

        var host: String { parent.origin.host?.lowercased() ?? "" }

        /// Forgets the host's old Cloudflare cookie first (it's why we're here), then opens the login.
        func start(_ web: WKWebView) {
            self.web = web
            let store = web.configuration.websiteDataStore.httpCookieStore
            store.getAllCookies { cookies in
                let stale = cookies.filter { self.isAppToken($0) }
                Task { @MainActor in
                    for cookie in stale { await store.deleteCookie(cookie) }
                    store.add(self)
                    web.load(URLRequest(url: self.parent.origin.appending(path: "api/status")))
                }
            }
        }

        /// The app token sits on the Hermes host. The one on `<team>.cloudflareaccess.com` is a different token.
        func isAppToken(_ cookie: HTTPCookie) -> Bool {
            guard cookie.name == CloudflareAccess.cookieName else { return false }
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host == domain || host.hasSuffix("." + domain)
        }

        func check() {
            guard !done, let web else { return }
            web.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                guard !self.done, let token = cookies.first(where: { self.isAppToken($0) })?.value, !token.isEmpty else { return }
                self.done = true
                self.parent.onToken(token)
            }
        }

        nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { @MainActor in self.check() }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.loading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            check()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.loading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.loading = false
        }
    }
}
