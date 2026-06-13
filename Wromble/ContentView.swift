import SwiftUI
import WebKit
import CoreLocation
import LocalAuthentication
import Network

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var showSplash = true
    @State private var selectedTab = 0
    @State private var homeURL: URL? = URL(string: "https://wromble.dk/")
    @State private var ordersURL: URL? = URL(string: "https://wromble.dk/private/orders/")
    @StateObject private var locationManager = LocationManager()
    @StateObject private var networkMonitor = NetworkMonitor()

    var body: some View {
        ZStack {
            if !appState.hasCompletedOnboarding {
                OnboardingView()
            } else {
                mainContent
            }

            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.easeOut(duration: 0.5)) {
                    showSplash = false
                }
            }
            networkMonitor.start()
        }
        .onChange(of: networkMonitor.isConnected) { newValue in
            appState.networkAvailable = newValue
        }
    }

    var mainContent: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    ZStack {
                        WrombleWebView(url: $homeURL, locationManager: locationManager)
                        if !appState.networkAvailable {
                            OfflineView { homeURL = URL(string: "https://wromble.dk/") }
                        }
                    }
                    .navigationBarHidden(true)
                }
                .tabItem {
                    Image(systemName: "house.fill")
                    Text("Hjem")
                }
                .tag(0)

                NavigationStack {
                    NearbyView(locationManager: locationManager) { url in
                        homeURL = url
                        selectedTab = 0
                    }
                }
                .tabItem {
                    Image(systemName: "magnifyingglass")
                    Text("Udforsk")
                }
                .tag(1)

                NavigationStack {
                    ZStack {
                        WrombleWebView(url: $ordersURL, locationManager: locationManager)
                        if !appState.networkAvailable {
                            OfflineView { ordersURL = URL(string: "https://wromble.dk/private/orders/") }
                        }
                    }
                    .navigationBarHidden(true)
                }
                .tabItem {
                    Image(systemName: "bag.fill")
                    Text("Ordrer")
                }
                .tag(2)

                NavigationStack {
                    ProfileView(locationManager: locationManager)
                }
                .tabItem {
                    Image(systemName: "person.fill")
                    Text("Profil")
                }
                .tag(3)
            }
            .accentColor(Color(red: 226/255, green: 15/255, blue: 30/255))
            .onChange(of: selectedTab) { _ in
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.impactOccurred()
            }
        }
    }
}

// MARK: - Splash Screen

struct SplashView: View {
    @Environment(\.horizontalSizeClass) var sizeClass

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.white.edgesIgnoringSafeArea(.all)
                VStack(spacing: sizeClass == .regular ? 24 : 16) {
                    Image("SplashLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: logoSize(for: geo.size), height: logoSize(for: geo.size))
                    Text("Wromble")
                        .font(.system(size: sizeClass == .regular ? 44 : 32, weight: .heavy))
                        .foregroundColor(Color(red: 226/255, green: 15/255, blue: 30/255))
                    Text("Nemt & Enkelt")
                        .font(.system(size: sizeClass == .regular ? 22 : 16, weight: .medium))
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    func logoSize(for size: CGSize) -> CGFloat {
        let shortest = min(size.width, size.height)
        return min(max(shortest * 0.3, 140), 320)
    }
}

// MARK: - Offline View

struct OfflineView: View {
    @Environment(\.horizontalSizeClass) var sizeClass
    var onRetry: () -> Void

    var body: some View {
        VStack(spacing: sizeClass == .regular ? 32 : 20) {
            Spacer()
            Image(systemName: "wifi.slash")
                .font(.system(size: sizeClass == .regular ? 80 : 60))
                .foregroundColor(.gray)
            Text("Ingen internetforbindelse")
                .font(sizeClass == .regular ? .title.bold() : .title2.bold())
            Text("Tjek din forbindelse og proev igen")
                .font(sizeClass == .regular ? .title3 : .body)
                .foregroundColor(.secondary)
            Button(action: {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.warning)
                onRetry()
            }) {
                Text("Proev igen")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, sizeClass == .regular ? 60 : 40)
                    .padding(.vertical, sizeClass == .regular ? 18 : 14)
                    .background(Color(red: 226/255, green: 15/255, blue: 30/255))
                    .cornerRadius(12)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.horizontalSizeClass) var sizeClass
    @State private var currentPage = 0

    let pages: [(icon: String, title: String, subtitle: String)] = [
        ("fork.knife", "Bestil mad", "Find restauranter i naerheden og faa maden leveret til doeren"),
        ("bag.fill", "Shop lokalt", "Koeb specialvarer fra butikker i dit omraade"),
        ("bell.badge.fill", "Hold dig opdateret", "Faa besked naar din ordre er paa vej"),
        ("location.fill", "Find naerliggende", "Vi finder de bedste steder taet paa dig"),
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(.systemBackground).edgesIgnoringSafeArea(.all)
                VStack {
                    TabView(selection: $currentPage) {
                        ForEach(0..<pages.count, id: \.self) { index in
                            VStack(spacing: sizeClass == .regular ? 36 : 24) {
                                Spacer()
                                Image(systemName: pages[index].icon)
                                    .font(.system(size: iconSize(for: geo.size)))
                                    .foregroundColor(Color(red: 226/255, green: 15/255, blue: 30/255))
                                    .padding(.bottom, 10)
                                Text(pages[index].title)
                                    .font(sizeClass == .regular ? .largeTitle.bold() : .title.bold())
                                Text(pages[index].subtitle)
                                    .font(sizeClass == .regular ? .title3 : .body)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, sizeClass == .regular ? 80 : 40)
                                    .frame(maxWidth: 600)
                                Spacer()
                            }
                            .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .always))

                    Button(action: {
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.impactOccurred()
                        if currentPage < pages.count - 1 {
                            withAnimation { currentPage += 1 }
                        } else {
                            requestPermissions()
                            appState.hasCompletedOnboarding = true
                            appState.save()
                        }
                    }) {
                        Text(currentPage == pages.count - 1 ? "Kom i gang" : "Naeste")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: sizeClass == .regular ? 400 : .infinity)
                            .padding(.vertical, sizeClass == .regular ? 18 : 16)
                            .background(Color(red: 226/255, green: 15/255, blue: 30/255))
                            .cornerRadius(14)
                    }
                    .padding(.horizontal, sizeClass == .regular ? 60 : 30)
                    .padding(.bottom, 50)
                }
            }
        }
    }

    func iconSize(for size: CGSize) -> CGFloat {
        let shortest = min(size.width, size.height)
        return min(max(shortest * 0.15, 60), 120)
    }

    func requestPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            DispatchQueue.main.async {
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                    appState.notificationsEnabled = true
                    appState.save()
                }
            }
        }
    }
}

// MARK: - Nearby / Explore View (Native)

struct NearbyView: View {
    @ObservedObject var locationManager: LocationManager
    @EnvironmentObject var appState: AppState
    @Environment(\.horizontalSizeClass) var sizeClass
    var onOpenURL: (URL) -> Void

    let categories: [(name: String, icon: String, path: String)] = [
        ("Restauranter", "fork.knife", "/category/spisesteder/"),
        ("Butikker", "bag.fill", "/category/butikker/"),
        ("Cafeer", "cup.and.saucer.fill", "/category/spisesteder/"),
        ("Bagerier", "birthday.cake.fill", "/category/spisesteder/"),
    ]

    let quickActions: [(name: String, icon: String, path: String)] = [
        ("Bordbestilling", "calendar.badge.clock", "/"),
        ("Wromble+", "star.fill", "/"),
        ("Bliv partner", "handshake.fill", "/bliv-partner.php"),
        ("Support", "message.fill", "/contact/"),
    ]

    var gridColumns: [GridItem] {
        if sizeClass == .regular {
            return [GridItem(.adaptive(minimum: 240), spacing: 16)]
        }
        return [GridItem(.flexible()), GridItem(.flexible())]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: sizeClass == .regular ? 36 : 24) {
                if let loc = locationManager.location {
                    HStack(spacing: 8) {
                        Image(systemName: "location.fill")
                            .foregroundColor(Color(red: 226/255, green: 15/255, blue: 30/255))
                        Text("Din placering fundet")
                            .font(sizeClass == .regular ? .body : .subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "%.4f, %.4f", loc.coordinate.latitude, loc.coordinate.longitude))
                            .font(sizeClass == .regular ? .subheadline : .caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                } else if locationManager.authorizationStatus == .denied {
                    HStack(spacing: 8) {
                        Image(systemName: "location.slash.fill")
                            .foregroundColor(.orange)
                        Text("Placering deaktiveret")
                            .font(sizeClass == .regular ? .body : .subheadline)
                        Spacer()
                        Button("Aktiver") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(sizeClass == .regular ? .body.bold() : .subheadline.bold())
                        .foregroundColor(Color(red: 226/255, green: 15/255, blue: 30/255))
                    }
                    .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                }

                VStack(alignment: .leading, spacing: sizeClass == .regular ? 18 : 12) {
                    Text("Kategorier")
                        .font(sizeClass == .regular ? .title.bold() : .title2.bold())
                        .padding(.horizontal, sizeClass == .regular ? 24 : 16)

                    LazyVGrid(columns: gridColumns, spacing: sizeClass == .regular ? 16 : 12) {
                        ForEach(categories, id: \.name) { cat in
                            Button(action: {
                                let generator = UIImpactFeedbackGenerator(style: .medium)
                                generator.impactOccurred()
                                onOpenURL(URL(string: "https://wromble.dk\(cat.path)")!)
                            }) {
                                HStack(spacing: sizeClass == .regular ? 16 : 12) {
                                    Image(systemName: cat.icon)
                                        .font(sizeClass == .regular ? .title2 : .title3)
                                        .foregroundColor(.white)
                                        .frame(width: sizeClass == .regular ? 56 : 44, height: sizeClass == .regular ? 56 : 44)
                                        .background(Color(red: 226/255, green: 15/255, blue: 30/255))
                                        .cornerRadius(sizeClass == .regular ? 14 : 12)
                                    Text(cat.name)
                                        .font(sizeClass == .regular ? .body.bold() : .subheadline.bold())
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.secondary)
                                        .font(sizeClass == .regular ? .subheadline : .caption)
                                }
                                .padding(sizeClass == .regular ? 16 : 12)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(14)
                            }
                        }
                    }
                    .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                }

                VStack(alignment: .leading, spacing: sizeClass == .regular ? 18 : 12) {
                    Text("Hurtig adgang")
                        .font(sizeClass == .regular ? .title.bold() : .title2.bold())
                        .padding(.horizontal, sizeClass == .regular ? 24 : 16)

                    LazyVGrid(columns: sizeClass == .regular ? [GridItem(.adaptive(minimum: 300), spacing: 16)] : [GridItem(.flexible())], spacing: sizeClass == .regular ? 16 : 0) {
                        ForEach(quickActions, id: \.name) { action in
                            Button(action: {
                                let generator = UIImpactFeedbackGenerator(style: .light)
                                generator.impactOccurred()
                                onOpenURL(URL(string: "https://wromble.dk\(action.path)")!)
                            }) {
                                HStack(spacing: sizeClass == .regular ? 18 : 14) {
                                    Image(systemName: action.icon)
                                        .font(sizeClass == .regular ? .title2 : .title3)
                                        .foregroundColor(Color(red: 226/255, green: 15/255, blue: 30/255))
                                        .frame(width: sizeClass == .regular ? 40 : 32)
                                    Text(action.name)
                                        .font(sizeClass == .regular ? .title3 : .body)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.secondary)
                                        .font(sizeClass == .regular ? .subheadline : .caption)
                                }
                                .padding(.horizontal, sizeClass == .regular ? 20 : 16)
                                .padding(.vertical, sizeClass == .regular ? 18 : 14)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(12)
                            }
                            .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                        }
                    }
                }

                Spacer(minLength: 40)
            }
            .padding(.top, 8)
        }
        .navigationTitle("Udforsk")
        .onAppear {
            if appState.locationEnabled {
                locationManager.requestLocation()
            }
        }
    }
}

// MARK: - Profile View (Fully Native)

struct ProfileView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var locationManager: LocationManager
    @Environment(\.horizontalSizeClass) var sizeClass
    @State private var showBiometricAlert = false
    @State private var showShareSheet = false
    @State private var showAbout = false

    var body: some View {
        List {
            Section {
                HStack(spacing: sizeClass == .regular ? 20 : 16) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: sizeClass == .regular ? 64 : 50))
                        .foregroundColor(Color(red: 226/255, green: 15/255, blue: 30/255))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Wromble")
                            .font(sizeClass == .regular ? .title2.bold() : .title3.bold())
                        Text("wromble.dk")
                            .font(sizeClass == .regular ? .body : .subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, sizeClass == .regular ? 12 : 8)
            }

            Section(header: Text("Notifikationer")) {
                Toggle(isOn: $appState.notificationsEnabled) {
                    Label("Push-notifikationer", systemImage: "bell.badge.fill")
                }
                .tint(Color(red: 226/255, green: 15/255, blue: 30/255))
                .onChange(of: appState.notificationsEnabled) { newValue in
                    if newValue {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                            DispatchQueue.main.async {
                                if granted {
                                    UIApplication.shared.registerForRemoteNotifications()
                                } else {
                                    appState.notificationsEnabled = false
                                }
                                appState.save()
                            }
                        }
                    } else {
                        appState.save()
                    }
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()
                }
            }

            Section(header: Text("Placering")) {
                Toggle(isOn: $appState.locationEnabled) {
                    Label("Brug placering", systemImage: "location.fill")
                }
                .tint(Color(red: 226/255, green: 15/255, blue: 30/255))
                .onChange(of: appState.locationEnabled) { newValue in
                    if newValue {
                        locationManager.requestLocation()
                    }
                    appState.save()
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()
                }

                if let loc = locationManager.location {
                    HStack {
                        Text("Aktuel position")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "%.2f, %.2f", loc.coordinate.latitude, loc.coordinate.longitude))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section(header: Text("Sikkerhed")) {
                Toggle(isOn: $appState.biometricEnabled) {
                    Label(biometricLabel, systemImage: biometricIcon)
                }
                .tint(Color(red: 226/255, green: 15/255, blue: 30/255))
                .onChange(of: appState.biometricEnabled) { newValue in
                    if newValue {
                        authenticateBiometric()
                    }
                    appState.save()
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()
                }
            }

            Section(header: Text("Del & Support")) {
                Button(action: {
                    showShareSheet = true
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()
                }) {
                    Label("Del Wromble med venner", systemImage: "square.and.arrow.up")
                        .foregroundColor(.primary)
                }

                Link(destination: URL(string: "https://wromble.dk/contact/")!) {
                    Label("Kontakt support", systemImage: "envelope.fill")
                        .foregroundColor(.primary)
                }

                Link(destination: URL(string: "https://wromble.dk/privacy-policy/app.php")!) {
                    Label("Privatlivspolitik", systemImage: "hand.raised.fill")
                        .foregroundColor(.primary)
                }
            }

            Section(header: Text("Om")) {
                HStack {
                    Label("Version", systemImage: "info.circle")
                    Spacer()
                    Text("1.0 (4)")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Label("Netvaerk", systemImage: appState.networkAvailable ? "wifi" : "wifi.slash")
                    Spacer()
                    Text(appState.networkAvailable ? "Forbundet" : "Ikke forbundet")
                        .foregroundColor(appState.networkAvailable ? .green : .red)
                        .font(.subheadline)
                }

                if !appState.deviceToken.isEmpty {
                    HStack {
                        Label("Push token", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        Text(String(appState.deviceToken.prefix(16)) + "...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Profil")
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [
                "Proev Wromble - bestil mad og specialvarer fra lokale butikker! Download her: https://wromble.dk/"
            ])
        }
        .alert("Biometrisk login", isPresented: $showBiometricAlert) {
            Button("OK") {
                appState.biometricEnabled = false
                appState.save()
            }
        } message: {
            Text("Biometrisk login er ikke tilgaengelig paa denne enhed.")
        }
    }

    var biometricLabel: String {
        let context = LAContext()
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
            return context.biometryType == .faceID ? "Face ID" : "Touch ID"
        }
        return "Biometrisk login"
    }

    var biometricIcon: String {
        let context = LAContext()
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
            return context.biometryType == .faceID ? "faceid" : "touchid"
        }
        return "lock.shield.fill"
    }

    func authenticateBiometric() {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Log ind med biometri") { success, _ in
                DispatchQueue.main.async {
                    if !success {
                        appState.biometricEnabled = false
                        appState.save()
                    }
                }
            }
        } else {
            showBiometricAlert = true
        }
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = UIView()
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - WebView

struct WrombleWebView: UIViewRepresentable {
    @Binding var url: URL?
    @ObservedObject var locationManager: LocationManager

    func makeCoordinator() -> WebCoordinator {
        WebCoordinator(locationManager: locationManager)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let userController = WKUserContentController()
        userController.add(context.coordinator, name: "wrombleNative")

        let viewportScript = WKUserScript(
            source: "var meta = document.querySelector('meta[name=viewport]'); if (!meta) { meta = document.createElement('meta'); meta.name = 'viewport'; document.head.appendChild(meta); } meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes';",
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        userController.addUserScript(viewportScript)
        config.userContentController = userController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.scrollView.bounces = true
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .white
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic

        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator, action: #selector(WebCoordinator.handleRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        context.coordinator.webView = webView

        if let url = url {
            webView.load(URLRequest(url: url))
        }

        NotificationCenter.default.addObserver(forName: .init("OpenURL"), object: nil, queue: .main) { notification in
            if let url = notification.object as? URL {
                webView.load(URLRequest(url: url))
            }
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if let newURL = url, uiView.url != newURL {
            uiView.load(URLRequest(url: newURL))
        }
    }

    class WebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var locationManager: LocationManager

        init(locationManager: LocationManager) {
            self.locationManager = locationManager
        }

        @objc func handleRefresh(_ refreshControl: UIRefreshControl) {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            webView?.reload()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                refreshControl.endRefreshing()
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }

            switch action {
            case "share":
                let text = body["text"] as? String ?? "Tjek Wromble ud!"
                let url = body["url"] as? String ?? "https://wromble.dk/"
                let items: [Any] = [text, URL(string: url)!]
                let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
                if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                   let rootVC = scene.windows.first?.rootViewController {
                    vc.popoverPresentationController?.sourceView = rootVC.view
                    vc.popoverPresentationController?.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
                    vc.popoverPresentationController?.permittedArrowDirections = []
                    rootVC.present(vc, animated: true)
                }

            case "haptic":
                let style = body["style"] as? String ?? "light"
                switch style {
                case "medium": UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                case "heavy": UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
                case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
                default: UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }

            case "getLocation":
                if let loc = locationManager.location {
                    let js = "window.wrombleLocation = {lat: \(loc.coordinate.latitude), lng: \(loc.coordinate.longitude)}; if(window.onWrombleLocation) window.onWrombleLocation(window.wrombleLocation);"
                    webView?.evaluateJavaScript(js)
                }

            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let loc = locationManager.location {
                let js = "window.wrombleNative = true; window.wrombleLocation = {lat: \(loc.coordinate.latitude), lng: \(loc.coordinate.longitude)};"
                webView.evaluateJavaScript(js)
            } else {
                webView.evaluateJavaScript("window.wrombleNative = true;")
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let host = url.host ?? ""

            if host.contains("wromble.dk") || host.isEmpty {
                decisionHandler(.allow)
                return
            }

            if url.scheme == "tel" || url.scheme == "mailto" {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            // OAuth / auth flows must stay in-app
            let authDomains = ["facebook.com", "fbcdn.net", "facebook.net",
                               "google.com", "googleapis.com", "gstatic.com",
                               "apple.com", "icloud.com",
                               "stripe.com", "mobilepay"]
            if authDomains.contains(where: { host.contains($0) }) {
                decisionHandler(.allow)
                return
            }

            if host.contains("maps.google") || host.contains("maps.apple") {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil || !(navigationAction.targetFrame!.isMainFrame) {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.grant)
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let ac = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            ac.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
               let rootVC = scene.windows.first?.rootViewController {
                rootVC.present(ac, animated: true)
            }
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let ac = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            ac.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
            ac.addAction(UIAlertAction(title: "Annuller", style: .cancel) { _ in completionHandler(false) })
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
               let rootVC = scene.windows.first?.rootViewController {
                rootVC.present(ac, animated: true)
            }
        }
    }
}

// MARK: - Location Manager

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var location: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestLocation() {
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }
}

// MARK: - Network Monitor

class NetworkMonitor: ObservableObject {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    @Published var isConnected: Bool = true

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
