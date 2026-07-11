import SwiftUI
import WebKit
import CoreLocation
import LocalAuthentication
import Network
import MapKit
import AuthenticationServices
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import AVFoundation
import AudioToolbox

let wrombleRed = Color(red: 226/255, green: 15/255, blue: 30/255)
let baseURL = "https://wromble.dk"

// API'et returnerer nogle billeder som fulde URL'er (https://...) og andre som filnavne.
// Denne helper undgaar dobbelt-URL som https://wromble.dk/uploads/https://...
func wrombleImageURL(_ path: String?) -> URL? {
    guard let p = path, !p.isEmpty else { return nil }
    if p.hasPrefix("http") { return URL(string: p) }
    return URL(string: "\(baseURL)/uploads/\(p)")
}

// MARK: - Cached, retrying image loader
// Fixes intermittent blank product images: SwiftUI's AsyncImage never caches and
// never retries, so when wromble.dk (shared hosting) briefly rate-limits a burst
// of image requests (HTTP 429), that cell stays blank forever - even though the
// exact same image loads fine in another row. This loader caches every image on
// disk+memory and retries a few times with backoff before giving up.
private let wrombleImageCache: URLCache = URLCache(
    memoryCapacity: 32 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024, diskPath: "wromble_img")

// Limits how many image downloads hit wromble.dk at the same time. Shared hosting
// (one.com) starts returning 429 when a whole menu screen fires 20-30 requests at
// once, so we let only a handful through concurrently and queue the rest. This
// spreads the load instead of bursting - the app-side version of "don't request
// them all at the same time".
private actor ImageDownloadGate {
    static let shared = ImageDownloadGate()
    private let maxConcurrent = 4
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if active < maxConcurrent { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
        active += 1
    }
    func release() {
        active -= 1
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }
}

@MainActor
final class WrombleImageLoader: ObservableObject {
    @Published var phase: AsyncImagePhase = .empty
    private var loadedURL: URL?

    func load(_ url: URL?) {
        guard let url = url else { phase = .empty; return }
        if loadedURL == url, case .success = phase { return }   // already have it
        loadedURL = url
        phase = .empty
        Task { await fetch(url) }
    }

    // One attempt against the network, gated so we don't burst the server.
    private func attemptNetwork(_ req: URLRequest) async throws -> UIImage {
        await ImageDownloadGate.shared.acquire()
        defer { Task { await ImageDownloadGate.shared.release() } }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)   // 429 / 5xx -> retry
        }
        guard let ui = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
        // cache manually (server may not send Cache-Control headers)
        wrombleImageCache.storeCachedResponse(CachedURLResponse(response: resp, data: data), for: req)
        return ui
    }

    private func fetch(_ url: URL) async {
        let req = URLRequest(url: url)
        // 1) serve from cache instantly if we have it
        if let cached = wrombleImageCache.cachedResponse(for: req),
           let ui = UIImage(data: cached.data) {
            if loadedURL == url { phase = .success(Image(uiImage: ui)) }
            return
        }
        // 2) fetch from network, retrying with backoff on failure (429/5xx/timeout)
        for attempt in 0...3 {
            do {
                let ui = try await attemptNetwork(req)
                if loadedURL == url { phase = .success(Image(uiImage: ui)) }
                return
            } catch {
                guard attempt < 3 else {
                    if loadedURL == url { phase = .failure(error) }
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 400_000_000) // 0.4/0.8/1.2s
                if loadedURL != url { return }   // URL changed while waiting - abandon
            }
        }
    }
}

// Drop-in replacement for AsyncImage(url:content:) - same closure signature,
// so call sites only change the type name.
struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    @ViewBuilder var content: (AsyncImagePhase) -> Content
    @StateObject private var loader = WrombleImageLoader()

    var body: some View {
        content(loader.phase)
            .onAppear { loader.load(url) }
            .onChange(of: url) { newURL in loader.load(newURL) }
    }
}

// MARK: - Models

struct UserProfile: Codable {
    let id: Int
    let name: String
    let email: String
    let phone: String?
    let type: String
}

struct Restaurant: Identifiable, Codable, Hashable {
    let id: Int
    let name: String
    let alias: String
    let type: Int
    let type_label: String
    let address: String
    let lat: Double
    let lng: Double
    let image: String?
    let logo: String?
    let categories: Int
    let items: Int

    static func == (lhs: Restaurant, rhs: Restaurant) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct MenuCategory: Identifiable, Codable {
    let id: Int
    let name: String
    let products: [MenuItem]
}

struct MenuItem: Identifiable, Codable {
    let id: Int
    let name: String
    let description: String?
    let price: Double
    let image: String?
    let extra_images: [String]?
}

struct CartItem: Identifiable {
    let id: Int
    let name: String
    let price: Double
    var quantity: Int
}

struct Order: Identifiable {
    let id: Int
    let companyName: String
    let date: String
    let total: Double
    let status: String
    let items: [OrderItem]
}

struct OrderItem {
    let name: String
    let quantity: Int
    let price: Double
}

struct ChatMessage: Identifiable {
    let id: Int
    let senderType: String
    let senderName: String
    let message: String
    let fileURL: String?
    let fileType: String?
    let fileName: String?
    let createdAt: String
}

// MARK: - Produkt-kategorier (forside, hentes fra api/home-categories.php)

struct ProductCatCompany: Codable, Identifiable {
    let id: Int
    let product: String?
}

// Et konkret produkt i en kategori - linker til firmaet der har det
struct CatProduct: Codable, Identifiable {
    let id: Int
    let name: String
    let price: Double?
    let image: String?
    let companyId: Int
    let companyName: String?
    enum CodingKeys: String, CodingKey {
        case id, name, price, image
        case companyId = "company_id"
        case companyName = "company_name"
    }
}

struct ProductCat: Codable, Identifiable {
    let key: String
    let name: String
    let image: String?
    let companies: [ProductCatCompany]
    let products: [CatProduct]?
    var id: String { key }
}

// Fast visuel stil (emoji + gradient) pr. kategori-noegle - bruges som fallback
// hvis kategorien ikke har et rigtigt produktbillede endnu.
struct CatStyle { let emoji: String; let colors: [Color] }

func catStyle(_ key: String) -> CatStyle {
    switch key {
    case "all":     return CatStyle(emoji: "✨", colors: [Color(red: 0.36, green: 0.36, blue: 0.42), Color(red: 0.20, green: 0.20, blue: 0.26)])
    case "varme":   return CatStyle(emoji: "🍽️", colors: [Color(red: 0.85, green: 0.16, blue: 0.20), Color(red: 0.55, green: 0.06, blue: 0.10)])
    case "kolde":   return CatStyle(emoji: "🥗", colors: [Color(red: 0.15, green: 0.55, blue: 0.45), Color(red: 0.05, green: 0.33, blue: 0.27)])
    case "drikke":  return CatStyle(emoji: "🥤", colors: [Color(red: 0.20, green: 0.45, blue: 0.85), Color(red: 0.10, green: 0.25, blue: 0.55)])
    case "slik":    return CatStyle(emoji: "🍰", colors: [Color(red: 0.80, green: 0.35, blue: 0.55), Color(red: 0.52, green: 0.15, blue: 0.33)])
    case "dessert": return CatStyle(emoji: "🍨", colors: [Color(red: 0.55, green: 0.35, blue: 0.75), Color(red: 0.33, green: 0.18, blue: 0.50)])
    default:        return CatStyle(emoji: "🍴", colors: [Color(red: 0.50, green: 0.30, blue: 0.20), Color(red: 0.30, green: 0.16, blue: 0.08)])
    }
}

// MARK: - Order tracking model

struct OrderStatus {
    let stage: Int          // -1 afvist, 0 modtaget, 1 bekraeftet, 2 paa vej, 3 leveret
    let label: String
    let description: String
    let companyName: String
    let total: Double
    var isDelivery: Bool = false
    var companyLat: Double = 0
    var companyLng: Double = 0
    var companyAddress: String = ""
    var customerLat: Double = 0
    var customerLng: Double = 0
}

// MARK: - Favorites Manager

class FavoritesManager: ObservableObject {
    static let shared = FavoritesManager()
    @Published var favoriteIds: Set<Int> = []

    init() {
        if let saved = UserDefaults.standard.array(forKey: "favoriteRestaurants") as? [Int] {
            favoriteIds = Set(saved)
        }
    }

    func toggle(_ id: Int) {
        if favoriteIds.contains(id) {
            favoriteIds.remove(id)
        } else {
            favoriteIds.insert(id)
        }
        UserDefaults.standard.set(Array(favoriteIds), forKey: "favoriteRestaurants")
    }

    func isFavorite(_ id: Int) -> Bool { favoriteIds.contains(id) }
}

// MARK: - Cart Manager

class CartManager: ObservableObject {
    static let shared = CartManager()
    @Published var items: [CartItem] = []
    @Published var restaurantId: Int = 0
    @Published var restaurantName: String = ""

    var total: Double { items.reduce(0) { $0 + $1.price * Double($1.quantity) } }
    var itemCount: Int { items.reduce(0) { $0 + $1.quantity } }

    func addItem(_ item: MenuItem, forRestaurant rid: Int, name rname: String) {
        if restaurantId != rid && restaurantId != 0 {
            items.removeAll()
        }
        restaurantId = rid
        restaurantName = rname
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].quantity += 1
        } else {
            items.append(CartItem(id: item.id, name: item.name, price: item.price, quantity: 1))
        }
    }

    func removeItem(_ id: Int) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            if items[idx].quantity > 1 {
                items[idx].quantity -= 1
            } else {
                items.remove(at: idx)
                if items.isEmpty { restaurantId = 0; restaurantName = "" }
            }
        }
    }

    func clear() {
        items.removeAll()
        restaurantId = 0
        restaurantName = ""
    }
}

// MARK: - Root View

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var showSplash = true
    @State private var selectedTab = 0
    @StateObject private var locationManager = LocationManager()
    @StateObject private var networkMonitor = NetworkMonitor()

    var body: some View {
        ZStack {
            if !appState.hasCompletedOnboarding {
                OnboardingView()
            } else if appState.biometricEnabled && !appState.isAuthenticated {
                BiometricLockView()
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
                withAnimation(.easeOut(duration: 0.5)) { showSplash = false }
            }
            networkMonitor.start()
            // Bed om notifikations-tilladelse med det samme ved opstart, saa "Tillad"
            // vises tidligt (iOS kraever brugerens ja - kan ikke saettes til paa forhaand).
            wrombleEnsurePushRegistered()
            // Bed ogsaa om placering ved opstart, saa iOS spoerger tidligt. Toggles i
            // Profil synkroniseres automatisk med systemets faktiske svar (se onChange).
            locationManager.requestLocation()
            syncLocationPreference(locationManager.authorizationStatus)
            if !appState.biometricEnabled { appState.isAuthenticated = true }
        }
        .onChange(of: networkMonitor.isConnected) { newValue in
            appState.networkAvailable = newValue
        }
        // Naar brugeren giver (eller fjerner) placeringstilladelse i systemet - fx paa
        // forsiden - opdateres "Brug placering" i Profil automatisk, saa den altid
        // afspejler den rigtige tilstand.
        .onChange(of: locationManager.authorizationStatus) { status in
            syncLocationPreference(status)
        }
    }

    // Holder "Brug placering"-toggle i Profil i sync med systemets faktiske tilladelse.
    func syncLocationPreference(_ status: CLAuthorizationStatus) {
        let granted = (status == .authorizedWhenInUse || status == .authorizedAlways)
        if appState.locationEnabled != granted {
            appState.locationEnabled = granted
            appState.save()
        }
    }

    var mainContent: some View {
        ZStack {
            if !appState.networkAvailable {
                OfflineView { networkMonitor.start() }
            } else {
                TabView(selection: $selectedTab) {
                    NavigationStack {
                        HomeView(locationManager: locationManager)
                    }
                    .tabItem { Image(systemName: "house.fill"); Text("Hjem") }
                    .tag(0)

                    NavigationStack {
                        MapTabView(locationManager: locationManager)
                    }
                    .tabItem { Image(systemName: "map.fill"); Text("Kort") }
                    .tag(1)

                    NavigationStack {
                        OrdersView()
                    }
                    .tabItem { Image(systemName: "bag.fill"); Text("Ordrer") }
                    .tag(2)

                    NavigationStack {
                        ChatView()
                    }
                    .tabItem { Image(systemName: "message.fill"); Text("Chat") }
                    .tag(3)

                    NavigationStack {
                        ProfileView(locationManager: locationManager)
                    }
                    .tabItem { Image(systemName: "person.fill"); Text("Profil") }
                    .tag(4)
                }
                .accentColor(wrombleRed)
                .onChange(of: selectedTab) { _ in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
        }
    }
}

// MARK: - Splash Screen

struct SplashView: View {
    @Environment(\.horizontalSizeClass) var sizeClass

    // Animations-tilstande
    @State private var logoIn = false
    @State private var titleIn = false
    @State private var taglineIn = false
    @State private var glowPulse = false
    @State private var pop = false

    // Roed brand-gradient til ordmaerket
    private var wordmarkGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 255/255, green: 74/255, blue: 74/255),
                wrombleRed,
                Color(red: 176/255, green: 8/255, blue: 20/255)
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Bloed baggrund med et roedt skaer
                LinearGradient(
                    colors: [Color.white, Color(red: 1.0, green: 0.96, blue: 0.96)],
                    startPoint: .top, endPoint: .bottom)
                    .edgesIgnoringSafeArea(.all)

                VStack(spacing: sizeClass == .regular ? 30 : 22) {
                    // Logo med pulserende gloed bag
                    ZStack {
                        Circle()
                            .fill(wrombleRed.opacity(0.18))
                            .frame(width: logoSize(for: geo.size) * 1.35,
                                   height: logoSize(for: geo.size) * 1.35)
                            .blur(radius: 30)
                            .scaleEffect(glowPulse ? 1.12 : 0.9)
                            .opacity(glowPulse ? 0.9 : 0.5)

                        Image("SplashLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: logoSize(for: geo.size), height: logoSize(for: geo.size))
                            .shadow(color: wrombleRed.opacity(0.35), radius: 20, y: 10)
                    }
                    .scaleEffect(logoIn ? 1 : 0.55)
                    .opacity(logoIn ? 1 : 0)

                    // "Wromble" - bogstaver der popper ud eet ad gangen med roed gradient
                    HStack(spacing: 1) {
                        ForEach(Array("Wromble".enumerated()), id: \.offset) { idx, ch in
                            Text(String(ch))
                                .font(.system(size: titleSize(for: geo.size), weight: .black, design: .rounded))
                                .foregroundStyle(wordmarkGradient)
                                .scaleEffect(pop ? 1 : 0.3)
                                .opacity(pop ? 1 : 0)
                                .animation(
                                    .spring(response: 0.4, dampingFraction: 0.5)
                                        .delay(Double(idx) * 0.07),
                                    value: pop)
                        }
                    }
                    .offset(y: titleIn ? 0 : 18)

                    // Intro-tekst / tagline - stoerre og med glid-ind
                    Text("Nemt & Enkelt")
                        .font(.system(size: taglineSize(for: geo.size), weight: .semibold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(colors: [wrombleRed.opacity(0.85), Color(red: 0.55, green: 0.05, blue: 0.10)],
                                           startPoint: .leading, endPoint: .trailing))
                        .tracking(3)
                        .opacity(taglineIn ? 1 : 0)
                        .offset(y: taglineIn ? 0 : 14)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear { runAnimations() }
        }
    }

    private func runAnimations() {
        withAnimation(.spring(response: 0.7, dampingFraction: 0.55)) { logoIn = true }
        withAnimation(.easeOut(duration: 0.6).delay(0.25)) { titleIn = true }
        withAnimation(.easeOut(duration: 0.6).delay(0.5)) { taglineIn = true }
        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { glowPulse = true }
        // Bogstaverne "popper" ud eet ad gangen naar logoet er kommet ind
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { pop = true }
    }

    func logoSize(for size: CGSize) -> CGFloat {
        let shortest = min(size.width, size.height)
        return min(max(shortest * 0.32, 150), 340)
    }

    func titleSize(for size: CGSize) -> CGFloat {
        let base = min(size.width, size.height)
        return min(max(base * 0.155, sizeClass == .regular ? 68 : 52), 120)
    }

    func taglineSize(for size: CGSize) -> CGFloat {
        let base = min(size.width, size.height)
        return min(max(base * 0.07, sizeClass == .regular ? 30 : 22), 44)
    }
}

// MARK: - Biometric Lock

struct BiometricLockView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.horizontalSizeClass) var sizeClass

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: biometricIcon)
                .font(.system(size: sizeClass == .regular ? 80 : 60))
                .foregroundColor(wrombleRed)
            Text("Wromble er laast")
                .font(sizeClass == .regular ? .title.bold() : .title2.bold())
            Text("Brug \(biometricLabel) for at laase op")
                .foregroundColor(.secondary)
            Button(action: authenticate) {
                Text("Laas op")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 14)
                    .background(wrombleRed)
                    .cornerRadius(12)
            }
            Spacer()
        }
        .onAppear { authenticate() }
    }

    var biometricLabel: String {
        let ctx = LAContext()
        if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
            return ctx.biometryType == .faceID ? "Face ID" : "Touch ID"
        }
        return "biometri"
    }

    var biometricIcon: String {
        let ctx = LAContext()
        if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
            return ctx.biometryType == .faceID ? "faceid" : "touchid"
        }
        return "lock.shield.fill"
    }

    func authenticate() {
        let ctx = LAContext()
        var error: NSError?
        if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Log ind med biometri") { success, _ in
                DispatchQueue.main.async { if success { appState.isAuthenticated = true } }
            }
        }
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
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                onRetry()
            }) {
                Text("Proev igen")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, sizeClass == .regular ? 60 : 40)
                    .padding(.vertical, sizeClass == .regular ? 18 : 14)
                    .background(wrombleRed)
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
        ("map.fill", "Find naerliggende", "Se restauranter og butikker paa kortet"),
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
                                    .foregroundColor(wrombleRed)
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
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
                            .background(wrombleRed)
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
        // Bed ogsaa om placering ved afslutning af onboarding, saa nye brugere bliver
        // spurgt om baade notifikationer og placering fra start.
        onboardingLocationManager.requestLocation()
    }

    @StateObject private var onboardingLocationManager = LocationManager()
}

// MARK: - Login View

enum LoginRole: String, CaseIterable {
    case privat = "Privat"
    case forretning = "Forretning"
    case chauffor = "Chauffør"

    // Login-tilstand der sendes til api/login.php
    var apiMode: String {
        switch self {
        case .privat: return "customer"
        case .forretning: return "company"
        case .chauffor: return "rider"
        }
    }
    var portalTitle: String {
        switch self {
        case .privat: return ""
        case .forretning: return "Log ind som forretning"
        case .chauffor: return "Log ind som chauffoer"
        }
    }
    var portalInfo: String {
        switch self {
        case .privat: return ""
        case .forretning: return "Se og haandter indkomne ordrer for din forretning. Ogsaa for medarbejdere."
        case .chauffor: return "Se dine aktive leverancer og marker dem som leveret."
        }
    }
    var portalIcon: String {
        switch self {
        case .privat: return "person.fill"
        case .forretning: return "building.2.fill"
        case .chauffor: return "bicycle"
        }
    }
}

// Login-session for personale (chauffoer / forretning) - holdes adskilt fra kunde-login
struct StaffSession: Identifiable {
    let id: Int
    let name: String
    let email: String
    let companyId: Int
    let role: String
    let type: String   // "rider" eller "company"
}

struct LoginView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.horizontalSizeClass) var sizeClass
    @State private var role: LoginRole = .privat
    @State private var isLogin = true
    @State private var email = ""
    @State private var password = ""
    @State private var firstname = ""
    @State private var lastname = ""
    @State private var phone = ""
    @State private var errorMessage = ""
    @State private var isLoading = false
    @State private var staffSession: StaffSession?
    var onLogin: (UserProfile) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: sizeClass == .regular ? 28 : 20) {
                Spacer(minLength: sizeClass == .regular ? 40 : 20)
                Image("SplashLogo")
                    .resizable().scaledToFit()
                    .frame(width: sizeClass == .regular ? 100 : 70, height: sizeClass == .regular ? 100 : 70)
                Text(isLogin ? "Log ind" : "Opret konto")
                    .font(sizeClass == .regular ? .largeTitle.bold() : .title.bold())
                Text(role == .privat ? (isLogin ? "Log ind med din Wromble konto" : "Opret en gratis Wromble konto") : "Vaelg hvordan du vil logge ind")
                    .font(.subheadline).foregroundColor(.secondary)

                // Rolle-valg (Privat / Forretning / Medarbejder) - som paa wromble.dk
                Picker("", selection: $role) {
                    ForEach(LoginRole.allCases, id: \.self) { r in Text(r.rawValue).tag(r) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: sizeClass == .regular ? 400 : .infinity)

                if role != .privat {
                    rolePortalView
                } else {

                Picker("", selection: $isLogin) {
                    Text("Log ind").tag(true)
                    Text("Opret konto").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: sizeClass == .regular ? 400 : .infinity)

                VStack(spacing: 14) {
                    if !isLogin {
                        HStack(spacing: 12) {
                            inputField("Fornavn", text: $firstname, icon: "person.fill")
                            inputField("Efternavn", text: $lastname, icon: "person.fill")
                        }
                        inputField("Telefon (valgfrit)", text: $phone, icon: "phone.fill", keyboard: .phonePad)
                    }
                    inputField("Email", text: $email, icon: "envelope.fill", keyboard: .emailAddress, autocap: false)
                    HStack(spacing: 12) {
                        Image(systemName: "lock.fill").foregroundColor(.secondary).frame(width: 20)
                        SecureField("Adgangskode", text: $password)
                            .textContentType(isLogin ? .password : .newPassword)
                    }
                    .padding(14)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                }
                .frame(maxWidth: sizeClass == .regular ? 400 : .infinity)

                if !errorMessage.isEmpty {
                    Text(errorMessage).font(.subheadline).foregroundColor(.red).multilineTextAlignment(.center)
                }

                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if isLogin { doLogin() } else { doRegister() }
                }) {
                    Group {
                        if isLoading { ProgressView().tint(.white) }
                        else { Text(isLogin ? "Log ind" : "Opret konto").font(.headline) }
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: sizeClass == .regular ? 400 : .infinity)
                    .padding(.vertical, 16)
                    .background((email.isEmpty || password.isEmpty) ? Color.gray : wrombleRed)
                    .cornerRadius(14)
                }
                .disabled(email.isEmpty || password.isEmpty || isLoading)

                HStack {
                    Rectangle().fill(Color(.separator)).frame(height: 1)
                    Text("eller").font(.caption).foregroundColor(.secondary)
                    Rectangle().fill(Color(.separator)).frame(height: 1)
                }
                .frame(maxWidth: sizeClass == .regular ? 400 : .infinity)

                SignInWithAppleButton(.signIn, onRequest: { request in
                    request.requestedScopes = [.fullName, .email]
                }, onCompletion: handleAppleSignIn)
                .signInWithAppleButtonStyle(.black)
                .frame(maxWidth: sizeClass == .regular ? 400 : .infinity, minHeight: 50)
                .cornerRadius(14)

                Button(action: {
                    onLogin(UserProfile(id: 0, name: "Gaest", email: "", phone: nil, type: "guest"))
                }) {
                    Text("Fortsaet uden login").font(.subheadline).foregroundColor(.secondary)
                }
                .padding(.top, 4)

                } // slut paa Privat-login

                Spacer(minLength: 40)
            }
            .padding(.horizontal, sizeClass == .regular ? 60 : 24)
        }
        .fullScreenCover(item: $staffSession) { session in
            StaffDashboardView(session: session)
        }
        .onChange(of: role) { _ in errorMessage = "" }
    }

    // Forretning/Chauffoer: rigtigt native login direkte i appen (ingen browser)
    var rolePortalView: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(wrombleRed.opacity(0.12)).frame(width: 80, height: 80)
                Image(systemName: role.portalIcon)
                    .font(.system(size: 36, weight: .semibold)).foregroundColor(wrombleRed)
            }
            .padding(.top, 8)

            Text(role.portalTitle).font(.title3.bold()).multilineTextAlignment(.center)
            Text(role.portalInfo)
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 14) {
                inputField("Email", text: $email, icon: "envelope.fill", keyboard: .emailAddress, autocap: false)
                HStack(spacing: 12) {
                    Image(systemName: "lock.fill").foregroundColor(.secondary).frame(width: 20)
                    SecureField("Adgangskode", text: $password)
                        .textContentType(.password)
                }
                .padding(14)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            }

            if !errorMessage.isEmpty {
                Text(errorMessage).font(.subheadline).foregroundColor(.red).multilineTextAlignment(.center)
            }

            Button(action: {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                doStaffLogin()
            }) {
                Group {
                    if isLoading { ProgressView().tint(.white) }
                    else { Text("Log ind").font(.headline) }
                }
                .foregroundColor(.white)
                .frame(maxWidth: sizeClass == .regular ? 400 : .infinity)
                .padding(.vertical, 16)
                .background((email.isEmpty || password.isEmpty) ? Color.gray : wrombleRed)
                .cornerRadius(14)
            }
            .disabled(email.isEmpty || password.isEmpty || isLoading)
        }
        .frame(maxWidth: sizeClass == .regular ? 400 : .infinity)
        .padding(.top, 8)
    }

    func doStaffLogin() {
        isLoading = true; errorMessage = ""
        guard let url = URL(string: "\(baseURL)/api/login.php") else { isLoading = false; return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email, "password": password, "mode": role.apiMode])

        URLSession.shared.dataTask(with: request) { data, _, _ in
            DispatchQueue.main.async {
                isLoading = false
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    errorMessage = "Netvaerksfejl. Proev igen."; return
                }
                if let error = json["error"] as? String { errorMessage = error; return }
                if let u = json["user"] as? [String: Any] {
                    let session = StaffSession(
                        id: u["id"] as? Int ?? 0,
                        name: u["name"] as? String ?? "",
                        email: u["email"] as? String ?? "",
                        companyId: u["company_id"] as? Int ?? 0,
                        role: u["role"] as? String ?? "",
                        type: u["type"] as? String ?? role.apiMode)
                    password = ""
                    // Registrer push-token, saa notifikationer kan naa den native app.
                    // Forretning: "Ny ordre". Chauffoer: "Ny levering".
                    if session.type == "company" && session.companyId > 0 {
                        registerStaffPushToken(companyId: session.companyId)
                    } else if session.type == "rider" && session.id > 0 {
                        registerRiderPushToken(riderId: session.id, companyId: session.companyId)
                    }
                    staffSession = session
                }
            }
        }.resume()
    }

    func registerStaffPushToken(companyId: Int) {
        // Husk hvilken forretning der er logget ind, saa token'et kan registreres
        // korrekt - baade nu og naar APNs-token'et ankommer (didRegisterForRemote).
        UserDefaults.standard.set(companyId, forKey: "companyPushId")
        UserDefaults.standard.set(0, forKey: "riderPushId")
        wrombleEnsurePushRegistered()   // beder om tilladelse + genhenter token om noedvendigt
        wrombleSyncPushToken()          // registrerer med det samme hvis token allerede findes
    }

    func registerRiderPushToken(riderId: Int, companyId: Int) {
        // Husk hvilken chauffoer der er logget ind, saa "Ny levering"-push kan naa den.
        UserDefaults.standard.set(riderId, forKey: "riderPushId")
        UserDefaults.standard.set(companyId, forKey: "companyPushId")
        wrombleEnsurePushRegistered()
        wrombleSyncPushToken()
    }

    func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                errorMessage = "Kunne ikke laese Apple-login"
                return
            }
            let fn = credential.fullName?.givenName ?? ""
            let ln = credential.fullName?.familyName ?? ""
            isLoading = true
            errorMessage = ""
            guard let url = URL(string: "\(baseURL)/api/apple-login.php") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "id_token": idToken, "firstname": fn, "lastname": ln
            ])
            URLSession.shared.dataTask(with: request) { data, _, _ in
                DispatchQueue.main.async {
                    isLoading = false
                    guard let data = data,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        errorMessage = "Netvaerksfejl. Proev igen."; return
                    }
                    if let error = json["error"] as? String { errorMessage = error; return }
                    if let u = json["user"] as? [String: Any] {
                        onLogin(UserProfile(
                            id: u["id"] as? Int ?? 0, name: u["name"] as? String ?? "",
                            email: u["email"] as? String ?? "", phone: u["phone"] as? String,
                            type: u["type"] as? String ?? "customer"))
                    }
                }
            }.resume()
        case .failure(let error):
            errorMessage = "Apple-login mislykkedes: \(error.localizedDescription)"
        }
    }

    func inputField(_ placeholder: String, text: Binding<String>, icon: String, keyboard: UIKeyboardType = .default, autocap: Bool = true) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundColor(.secondary).frame(width: 20)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .autocapitalization(autocap ? .words : .none)
                .disableAutocorrection(!autocap)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    func doLogin() {
        isLoading = true; errorMessage = ""
        guard let url = URL(string: "\(baseURL)/api/login.php") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email, "password": password, "mode": "customer"])

        URLSession.shared.dataTask(with: request) { data, _, _ in
            DispatchQueue.main.async {
                isLoading = false
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    errorMessage = "Netvaerksfejl. Proev igen."; return
                }
                if let error = json["error"] as? String { errorMessage = error; return }
                if let u = json["user"] as? [String: Any] {
                    onLogin(UserProfile(
                        id: u["id"] as? Int ?? 0, name: u["name"] as? String ?? "",
                        email: u["email"] as? String ?? "", phone: u["phone"] as? String,
                        type: u["type"] as? String ?? "customer"))
                }
            }
        }.resume()
    }

    func doRegister() {
        isLoading = true; errorMessage = ""
        guard !firstname.isEmpty else { errorMessage = "Fornavn er paakraevet"; isLoading = false; return }
        guard let url = URL(string: "\(baseURL)/api/register.php") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "firstname": firstname, "lastname": lastname, "email": email, "phone": phone, "password": password])

        URLSession.shared.dataTask(with: request) { data, _, _ in
            DispatchQueue.main.async {
                isLoading = false
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    errorMessage = "Netvaerksfejl. Proev igen."; return
                }
                if let error = json["error"] as? String { errorMessage = error; return }
                if let u = json["user"] as? [String: Any] {
                    onLogin(UserProfile(
                        id: u["id"] as? Int ?? 0, name: u["name"] as? String ?? "",
                        email: u["email"] as? String ?? "", phone: u["phone"] as? String,
                        type: u["type"] as? String ?? "customer"))
                }
            }
        }.resume()
    }
}

// MARK: - Personale-dashboards (chauffoer / forretning) - native

struct DriverOrder: Codable, Identifiable {
    let id: Int
    let customer: String
    let address: String
    let lat: Double
    let lng: Double
    let amount: Double
    let company: String
    let delivery: Bool
    let mine: Bool
    var orderTime: String = ""
    var deliverTime: String = ""
    var items: [CompanyOrderItem] = []
    enum CodingKeys: String, CodingKey {
        case id, customer, address, lat, lng, amount, company, delivery, mine, items
        case orderTime = "order_time"
        case deliverTime = "deliver_time"
    }
}

struct CompanyOrderItem: Codable, Identifiable {
    let name: String
    let qty: Int
    let price: Double
    var id: String { "\(name)-\(qty)-\(price)" }
}

struct CompanyOrder: Codable, Identifiable {
    let id: Int
    let customer: String
    let phone: String
    let address: String
    let amount: Double
    let delivery: Bool
    let payment: Int
    let table: Bool
    let isNew: Bool
    let delivered: Bool
    let status: String
    let items: [CompanyOrderItem]
    enum CodingKeys: String, CodingKey {
        case id, customer, phone, address, amount, delivery, payment, table, status, items, delivered
        case isNew = "is_new"
    }
}

// MARK: - Forretnings back-office modeller

struct CompanyProfile: Codable {
    var id: Int
    var companyname: String
    var email: String
    var companytype: Int
    var firstname_contact: String
    var lastname_contact: String
    var adress: String
    var zipcode: String
    var city: String
    var phone_mobile: String
    var specialities: String
    var website: String
    var description: String
    var briefdescription: String
    var shop_status: String
    var com_delivery: Int
    var com_delivery_price: Int
    var com_delivery_time: String
    var logo: String?
}

struct CompanyHourDay: Codable, Identifiable {
    var weekday: String
    var store_open: String
    var store_close: String
    var bring_open: String
    var bring_close: String
    var id: String { weekday }
}

// Aaben/lukket-beregning delt af kunde-menuen og kurven, saa der aldrig kan
// bestilles fra en lukket butik. Tager hoejde for baade aabningstider og
// forretningens manuelle "Lukket"-knap (shop_status).
struct ShopOpenState {
    let isOpen: Bool
    let nextOpenText: String?   // fx "i dag kl. 17:00", "i morgen kl. 10:00", "Fredag kl. 11:00"
    let manuallyClosed: Bool
}

func wrombleShopOpenState(_ days: [CompanyHourDay], shopStatus: String = "") -> ShopOpenState {
    let names = ["Søndag","Mandag","Tirsdag","Onsdag","Torsdag","Fredag","Lørdag"]
    let cal = Calendar.current
    let todayIdx = max(0, min(6, cal.component(.weekday, from: Date()) - 1))
    let df = DateFormatter(); df.dateFormat = "HH:mm"
    let now = df.string(from: Date())
    let today = days.first { $0.weekday == names[todayIdx] }
    let manualClosed = (shopStatus == "Lukket")

    var open = false
    if !manualClosed, let t = today, !t.store_open.isEmpty, !t.store_close.isEmpty {
        open = t.store_open <= now && now <= t.store_close
    }

    var next: String? = nil
    if !manualClosed {
        if let t = today, !t.store_open.isEmpty, now < t.store_open {
            next = "i dag kl. \(t.store_open)"
        } else {
            for offset in 1...7 {
                let idx = (todayIdx + offset) % 7
                if let d = days.first(where: { $0.weekday == names[idx] }), !d.store_open.isEmpty {
                    next = (offset == 1 ? "i morgen" : names[idx]) + " kl. \(d.store_open)"
                    break
                }
            }
        }
    }
    return ShopOpenState(isOpen: open, nextOpenText: next, manuallyClosed: manualClosed)
}

struct CustomerProfileData: Codable {
    var id: Int
    var firstname: String
    var lastname: String
    var email: String
    var adress: String
    var zipcode: String
    var city: String
    var phone: String
}

func paymentLabel(_ p: Int) -> String {
    switch p {
    case 1: return "Online / kort"
    case 2: return "Kontanter"
    default: return "Ukendt"
    }
}

struct StaffDashboardView: View {
    let session: StaffSession
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if session.type == "rider" {
                    DriverDashboardView(session: session)
                } else {
                    CompanyDashboardView(session: session)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                            Text("Log ud")
                        }
                    }
                }
            }
        }
    }
}

// Fielles lille "toast" nederst paa skaermen
struct StaffToast: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold)).foregroundColor(.white)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(Color.black.opacity(0.85)).cornerRadius(12)
            .padding(.bottom, 24)
            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
    }
}

struct DriverDashboardView: View {
    let session: StaffSession
    @State private var orders: [DriverOrder] = []
    @State private var isLoading = true
    @State private var actionId: Int?
    @State private var toast: String?
    @State private var refreshTimer: Timer?
    @State private var knownOrderIds: Set<Int> = []
    @State private var didInitialLoad = false
    @State private var mapsOrder: DriverOrder?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                headerCard
                if isLoading {
                    ProgressView().scaleEffect(1.2).padding(.top, 50)
                } else if orders.isEmpty {
                    emptyState
                } else {
                    ForEach(orders) { order in orderCard(order) }
                }
            }
            .padding(16)
        }
        .navigationTitle("Chauffoer")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .onAppear { startAutoRefresh() }
        .onDisappear { refreshTimer?.invalidate(); refreshTimer = nil }
        .overlay(alignment: .bottom) { if let t = toast { StaffToast(text: t) } }
        .confirmationDialog("Naviger til kunden", isPresented: Binding(get: { mapsOrder != nil }, set: { if !$0 { mapsOrder = nil } }), titleVisibility: .visible) {
            if let o = mapsOrder {
                Button("Apple Kort") { openAppleMaps(o); mapsOrder = nil }
                Button("Google Maps") { openGoogleMaps(o); mapsOrder = nil }
                Button("Annuller", role: .cancel) { mapsOrder = nil }
            }
        }
    }

    // Henter leverance-listen hvert 5. sekund, saa nye leverancer dukker op af sig selv.
    func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { await load(showSpinner: false) }
        }
    }

    // Lyd + vibration naar en ny leverance er kommet ind mens siden er aaben.
    func alertNewOrder() {
        AudioServicesPlaySystemSound(1007)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    var headerCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(wrombleRed.opacity(0.12)).frame(width: 52, height: 52)
                Image(systemName: "bicycle").font(.system(size: 24, weight: .semibold)).foregroundColor(wrombleRed)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name.isEmpty ? "Chauffoer" : session.name).font(.headline)
                Text("\(orders.count) aktive leverancer").font(.subheadline).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(Color(.secondarySystemBackground)).cornerRadius(16)
    }

    var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundColor(.green)
            Text("Ingen aktive leverancer").font(.headline)
            Text("Nye leverancer dukker op her, naar en forretning accepterer en ordre.")
                .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 50).padding(.horizontal, 20)
    }

    func orderCard(_ order: DriverOrder) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ordre #\(order.id)").font(.headline)
                Spacer()
                Text(String(format: "%.0f kr", order.amount)).font(.headline).foregroundColor(wrombleRed)
            }
            if !order.company.isEmpty {
                Label(order.company, systemImage: "building.2.fill").font(.subheadline).foregroundColor(.secondary)
            }
            if !order.customer.isEmpty {
                Label(order.customer, systemImage: "person.fill").font(.subheadline)
            }
            if !order.address.isEmpty {
                Label(order.address, systemImage: "mappin.circle.fill").font(.subheadline).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Hvornaar ordren skal leveres (og hvornaar den blev bestilt)
            if !order.deliverTime.isEmpty || !order.orderTime.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "clock.fill").font(.caption).foregroundColor(wrombleRed)
                    if !order.deliverTime.isEmpty {
                        Text("Leveres \(order.deliverTime)").font(.subheadline.weight(.semibold))
                    }
                    if !order.orderTime.isEmpty {
                        Text("(bestilt \(order.orderTime))").font(.caption).foregroundColor(.secondary)
                    }
                }
            }

            // Hvad der er bestilt - saa chaufføren kan se ordren med sig
            if !order.items.isEmpty {
                Divider()
                ForEach(order.items) { item in
                    HStack {
                        Text("\(item.qty)x").font(.subheadline.bold()).foregroundColor(wrombleRed)
                        Text(item.name).font(.subheadline)
                        Spacer()
                    }
                }
            }

            HStack(spacing: 10) {
                if order.lat != 0 || order.lng != 0 || !order.address.isEmpty {
                    Button(action: { mapsOrder = order }) {
                        Label("Rute", systemImage: "location.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .foregroundColor(wrombleRed)
                            .background(wrombleRed.opacity(0.10)).cornerRadius(10)
                    }
                }
                Button(action: { deliver(order) }) {
                    Group {
                        if actionId == order.id { ProgressView().tint(.white) }
                        else { Label("Marker leveret", systemImage: "checkmark") .font(.subheadline.weight(.bold)) }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .foregroundColor(.white).background(Color.green).cornerRadius(10)
                }
                .disabled(actionId != nil)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground)).cornerRadius(16)
    }

    // Destination-parameter: brug GPS-koordinater hvis vi har dem, ellers kundens adresse.
    private func mapsDestination(_ order: DriverOrder) -> String {
        if order.lat != 0 || order.lng != 0 { return "\(order.lat),\(order.lng)" }
        return order.address
    }

    func openAppleMaps(_ order: DriverOrder) {
        let dest = mapsDestination(order).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "http://maps.apple.com/?daddr=\(dest)&dirflg=d") { UIApplication.shared.open(url) }
    }

    func openGoogleMaps(_ order: DriverOrder) {
        let dest = mapsDestination(order).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        // Aabn Google Maps-appen hvis den er installeret, ellers Google Maps i browseren.
        if let app = URL(string: "comgooglemaps://?daddr=\(dest)&directionsmode=driving"),
           UIApplication.shared.canOpenURL(app) {
            UIApplication.shared.open(app)
        } else if let web = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(dest)&travelmode=driving") {
            UIApplication.shared.open(web)
        }
    }

    func load(showSpinner: Bool = true) async {
        guard let url = URL(string: "\(baseURL)/api/app-driver-orders.php?rider_id=\(session.id)&company_id=\(session.companyId)") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct Resp: Codable { let orders: [DriverOrder] }
            let r = try JSONDecoder().decode(Resp.self, from: data)
            await MainActor.run {
                let incoming = Set(r.orders.map { $0.id })
                let fresh = incoming.subtracting(knownOrderIds)
                if didInitialLoad && !fresh.isEmpty { alertNewOrder() }
                knownOrderIds = incoming
                didInitialLoad = true
                orders = r.orders
                isLoading = false
            }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }

    func deliver(_ order: DriverOrder) {
        actionId = order.id
        guard let url = URL(string: "\(baseURL)/api/app-driver-deliver.php") else { actionId = nil; return }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["rider_id": session.id, "company_id": session.companyId, "order_id": order.id])
        URLSession.shared.dataTask(with: req) { data, _, _ in
            DispatchQueue.main.async {
                actionId = nil
                if let data = data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], j["success"] as? Bool == true {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    orders.removeAll { $0.id == order.id }
                    showToast("Ordre #\(order.id) leveret")
                } else {
                    showToast("Kunne ikke opdatere ordren")
                }
            }
        }.resume()
    }

    func showToast(_ msg: String) {
        withAnimation { toast = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if toast == msg { withAnimation { toast = nil } }
        }
    }
}

struct CompanyOrdersView: View {
    let session: StaffSession
    @State private var orders: [CompanyOrder] = []
    @State private var isLoading = true
    @State private var actionId: Int?
    @State private var toast: String?
    @State private var tab = 0   // 0 = Aktive, 1 = Historik
    @State private var refreshTimer: Timer?
    @State private var knownOrderIds: Set<Int> = []
    @State private var didInitialLoad = false

    var newOrders: [CompanyOrder] { orders.filter { $0.isNew } }
    var activeOrders: [CompanyOrder] { orders.filter { !$0.isNew } }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Picker("", selection: $tab) {
                    Text("Aktive").tag(0)
                    Text("Historik").tag(1)
                }
                .pickerStyle(.segmented)
                .onChange(of: tab) { _ in Task { await load() } }

                if isLoading {
                    ProgressView().scaleEffect(1.2).padding(.top, 50)
                } else if orders.isEmpty {
                    emptyState
                } else if tab == 0 {
                    if !newOrders.isEmpty {
                        sectionHeader("Nye ordrer", count: newOrders.count)
                        ForEach(newOrders) { orderCard($0) }
                    }
                    if !activeOrders.isEmpty {
                        sectionHeader("I gang", count: activeOrders.count)
                        ForEach(activeOrders) { orderCard($0) }
                    }
                } else {
                    ForEach(orders) { orderCard($0) }
                }
            }
            .padding(16)
        }
        .navigationTitle("Ordrer")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .onAppear { startAutoRefresh() }
        .onDisappear { refreshTimer?.invalidate(); refreshTimer = nil }
        .overlay(alignment: .bottom) { if let t = toast { StaffToast(text: t) } }
    }

    // Henter ordrelisten hvert 15. sekund, saa nye bestillinger dukker op af sig
    // selv - uden at forretningen skal gaa ind og ud af siden.
    func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { await load(showSpinner: false) }
        }
    }

    // Giver lyd + vibration naar en helt ny ordre er kommet ind mens siden er aaben.
    func alertNewOrder() {
        AudioServicesPlaySystemSound(1007)   // kort notifikationslyd
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.title3.bold())
            Text("\(count)").font(.subheadline.bold()).foregroundColor(.white)
                .padding(.horizontal, 9).padding(.vertical, 2)
                .background(wrombleRed).clipShape(Capsule())
            Spacer()
        }
        .padding(.top, 4)
    }

    var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray").font(.system(size: 44)).foregroundColor(.secondary)
            Text("Ingen ordrer lige nu").font(.headline)
            Text("Nye bestillinger dukker op her med det samme.")
                .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 50).padding(.horizontal, 20)
    }

    func orderCard(_ order: CompanyOrder) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ordre #\(order.id)").font(.headline)
                Spacer()
                Text(String(format: "%.0f kr", order.amount)).font(.headline).foregroundColor(wrombleRed)
            }

            HStack(spacing: 8) {
                chipTag(order.delivery ? "Levering" : "Afhentning", icon: order.delivery ? "bicycle" : "bag.fill")
                chipTag(paymentLabel(order.payment), icon: "creditcard.fill")
                if order.table { chipTag("Bord", icon: "fork.knife") }
            }

            if !order.customer.isEmpty {
                Label(order.customer, systemImage: "person.fill").font(.subheadline)
            }
            if order.delivery && !order.address.isEmpty {
                Label(order.address, systemImage: "mappin.circle.fill").font(.subheadline).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !order.items.isEmpty {
                Divider()
                ForEach(order.items) { item in
                    HStack {
                        Text("\(item.qty)x").font(.subheadline.bold()).foregroundColor(wrombleRed)
                        Text(item.name).font(.subheadline)
                        Spacer()
                        Text(String(format: "%.0f kr", item.price)).font(.subheadline).foregroundColor(.secondary)
                    }
                }
            }

            if order.isNew {
                HStack(spacing: 10) {
                    Button(action: { act(order, "reject") }) {
                        Text("Afvis").font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .foregroundColor(wrombleRed)
                            .background(wrombleRed.opacity(0.10)).cornerRadius(10)
                    }
                    .disabled(actionId != nil)
                    Button(action: { act(order, "accept") }) {
                        Group {
                            if actionId == order.id { ProgressView().tint(.white) }
                            else { Label("Accepter", systemImage: "checkmark").font(.subheadline.weight(.bold)) }
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .foregroundColor(.white).background(Color.green).cornerRadius(10)
                    }
                    .disabled(actionId != nil)
                }
                .padding(.top, 2)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: order.delivered ? "checkmark.circle.fill" : "checkmark.seal.fill").foregroundColor(.green)
                    Text(order.delivered ? "Leveret" : "Accepteret").font(.subheadline.weight(.semibold)).foregroundColor(.green)
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground)).cornerRadius(16)
    }

    func chipTag(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Color(.tertiarySystemBackground)).cornerRadius(8)
    }

    func load(showSpinner: Bool = true) async {
        if showSpinner { await MainActor.run { isLoading = true } }
        let scope = tab == 1 ? "history" : "active"
        guard let url = URL(string: "\(baseURL)/api/app-company-orders.php?company_id=\(session.companyId)&scope=\(scope)") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct Resp: Codable { let orders: [CompanyOrder] }
            let r = try JSONDecoder().decode(Resp.self, from: data)
            await MainActor.run {
                // Opdag helt nye ordrer (kun paa Aktive-fanen) og giv lyd + vibration
                if tab == 0 {
                    let incomingNew = Set(r.orders.filter { $0.isNew }.map { $0.id })
                    let fresh = incomingNew.subtracting(knownOrderIds)
                    if didInitialLoad && !fresh.isEmpty { alertNewOrder() }
                    knownOrderIds = incomingNew
                }
                orders = r.orders
                isLoading = false
                didInitialLoad = true
            }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }

    func act(_ order: CompanyOrder, _ action: String) {
        actionId = order.id
        guard let url = URL(string: "\(baseURL)/api/app-company-order-action.php") else { actionId = nil; return }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["company_id": session.companyId, "order_id": order.id, "action": action])
        URLSession.shared.dataTask(with: req) { data, _, _ in
            DispatchQueue.main.async {
                actionId = nil
                if let data = data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], j["success"] as? Bool == true {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    if action == "reject" {
                        orders.removeAll { $0.id == order.id }
                        showToast("Ordre #\(order.id) afvist")
                    } else {
                        Task { await load() }
                        showToast("Ordre #\(order.id) accepteret")
                    }
                } else {
                    showToast("Handlingen mislykkedes")
                }
            }
        }.resume()
    }

    func showToast(_ msg: String) {
        withAnimation { toast = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if toast == msg { withAnimation { toast = nil } }
        }
    }
}

// MARK: - Forretnings back-office (native indstillinger som paa wromble.dk)

struct CompanyDashboardView: View {
    let session: StaffSession
    @State private var busy = false
    @State private var busyLoading = true
    @State private var autoAccept = true
    @State private var autoLoading = true

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(wrombleRed.opacity(0.12)).frame(width: 52, height: 52)
                        Image(systemName: "building.2.fill").font(.system(size: 22, weight: .semibold)).foregroundColor(wrombleRed)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.name.isEmpty ? "Forretning" : session.name).font(.headline)
                        Text(session.email).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                .padding(.vertical, 4)
            }
            Section(header: Text("Ordremodtagelse"), footer: Text(autoAccept ? "Alle nye ordrer bliver accepteret automatisk. Du behoever ikke trykke Accepter." : "Du godkender selv hver ordre manuelt under Ordrer.")) {
                Toggle(isOn: Binding(
                    get: { autoAccept },
                    set: { newVal in autoAccept = newVal; setAutoAccept(newVal) }
                )) {
                    Label("Accepter alle ordre", systemImage: "checkmark.circle.fill")
                        .foregroundColor(autoAccept ? wrombleRed : .primary)
                }
                .tint(wrombleRed)
                .disabled(autoLoading)
            }
            Section(header: Text("Status"), footer: Text(busy ? "Kunder kan IKKE bestille lige nu - de faar besked om at der er ekstraordinaert travlt." : "Butikken tager imod bestillinger som normalt.")) {
                Toggle(isOn: Binding(
                    get: { busy },
                    set: { newVal in busy = newVal; setBusy(newVal) }
                )) {
                    Label("Ekstraordinaert travlt", systemImage: "flame.fill")
                        .foregroundColor(busy ? wrombleRed : .primary)
                }
                .tint(wrombleRed)
                .disabled(busyLoading)
            }
            Section(header: Text("Administrer")) {
                NavigationLink { CompanyOrdersView(session: session) } label: {
                    Label("Ordrer", systemImage: "bag.fill").foregroundColor(.primary)
                }
                NavigationLink { CompanyMenuView(session: session) } label: {
                    Label("Menukort", systemImage: "list.bullet.rectangle").foregroundColor(.primary)
                }
                NavigationLink { CompanyHoursView(session: session) } label: {
                    Label("Aabningstider", systemImage: "clock.fill").foregroundColor(.primary)
                }
                NavigationLink { CompanyProfileView(session: session) } label: {
                    Label("Indstillinger", systemImage: "gearshape.fill").foregroundColor(.primary)
                }
            }
        }
        .navigationTitle(session.name.isEmpty ? "Forretning" : session.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadBusy(); loadAutoAccept() }
    }

    func loadAutoAccept() {
        guard let url = URL(string: "\(baseURL)/api/app-company-autoaccept.php?company_id=\(session.companyId)") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            var a = true
            if let data = data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                a = (j["auto_accept"] as? Int ?? 1) == 1
            }
            DispatchQueue.main.async { autoAccept = a; autoLoading = false }
        }.resume()
    }

    func setAutoAccept(_ value: Bool) {
        guard !autoLoading else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        guard let url = URL(string: "\(baseURL)/api/app-company-autoaccept.php") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["company_id": session.companyId, "auto_accept": value ? 1 : 0])
        URLSession.shared.dataTask(with: req).resume()
    }

    func loadBusy() {
        guard let url = URL(string: "\(baseURL)/api/app-company-busy.php?company_id=\(session.companyId)") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            var b = false
            if let data = data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                b = (j["busy"] as? Int ?? 0) == 1
            }
            DispatchQueue.main.async { busy = b; busyLoading = false }
        }.resume()
    }

    func setBusy(_ value: Bool) {
        guard !busyLoading else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        guard let url = URL(string: "\(baseURL)/api/app-company-busy.php") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["company_id": session.companyId, "busy": value ? 1 : 0])
        URLSession.shared.dataTask(with: req).resume()
    }
}

// Redigering af en enkelt ret
struct MenuItemEdit: Identifiable {
    let id: String
    var itemId: Int
    var catId: Int
    var headline: String
    var description: String
    var price: String
}

struct CompanyMenuView: View {
    let session: StaffSession
    @State private var categories: [MenuCategory] = []
    @State private var isLoading = true
    @State private var editing: MenuItemEdit?
    @State private var showAddCategory = false
    @State private var newCatName = ""
    @State private var toast: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isLoading {
                    ProgressView().scaleEffect(1.2).frame(maxWidth: .infinity).padding(.top, 50)
                } else {
                    if categories.isEmpty {
                        Text("Ingen kategorier endnu. Opret din foerste kategori nedenfor.")
                            .font(.subheadline).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center).padding(.top, 30)
                    }
                    ForEach(categories) { cat in categorySection(cat) }

                    Button(action: { newCatName = ""; showAddCategory = true }) {
                        Label("Ny kategori", systemImage: "folder.badge.plus")
                            .font(.subheadline.weight(.semibold)).foregroundColor(wrombleRed)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(wrombleRed.opacity(0.10)).cornerRadius(12)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Menukort")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .overlay(alignment: .bottom) { if let t = toast { StaffToast(text: t) } }
        .sheet(item: $editing) { e in
            MenuItemEditorView(session: session, edit: e, onDone: { msg in
                editing = nil
                if let m = msg { showToast(m) }
                let wasDelete = (msg == "Ret slettet")
                let catId = e.catId
                Task {
                    await load()
                    // Ryd op: hvis den sidste ret i en kategori slettes, fjern den tomme kategori
                    if wasDelete, let cat = categories.first(where: { $0.id == catId }), cat.products.isEmpty {
                        postJSON("app-menu-category.php", ["company_id": session.companyId, "action": "delete", "id": catId]) { ok, _ in
                            if ok { Task { await load() } }
                        }
                    }
                }
            })
        }
        .alert("Ny kategori", isPresented: $showAddCategory) {
            TextField("Navn", text: $newCatName)
            Button("Annuller", role: .cancel) {}
            Button("Opret") { saveCategory(name: newCatName) }
        }
    }

    func categorySection(_ cat: MenuCategory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(cat.name).font(.title3.bold())
                Spacer()
                Button(action: { deleteCategory(cat) }) {
                    Image(systemName: "trash").font(.subheadline).foregroundColor(.secondary)
                }
            }
            ForEach(cat.products) { item in
                Button(action: {
                    editing = MenuItemEdit(id: "\(item.id)", itemId: item.id, catId: cat.id,
                                           headline: item.name, description: item.description ?? "",
                                           price: String(format: "%.0f", item.price))
                }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.subheadline.weight(.semibold)).foregroundColor(.primary)
                            if let d = item.description, !d.isEmpty {
                                Text(d).font(.caption).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(String(format: "%.0f kr", item.price)).font(.subheadline).foregroundColor(.secondary)
                        Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                Divider()
            }
            Button(action: {
                editing = MenuItemEdit(id: "new-\(cat.id)", itemId: 0, catId: cat.id, headline: "", description: "", price: "")
            }) {
                Label("Tilfoej ret", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundColor(wrombleRed)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .background(Color(.secondarySystemBackground)).cornerRadius(16)
    }

    func load() async {
        await MainActor.run { isLoading = true }
        guard let url = URL(string: "\(baseURL)/api/menu.php?company_id=\(session.companyId)") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct Resp: Codable { let categories: [MenuCategory] }
            let r = try JSONDecoder().decode(Resp.self, from: data)
            await MainActor.run { categories = r.categories; isLoading = false }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }

    func saveCategory(name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        postJSON("app-menu-category.php", ["company_id": session.companyId, "action": "save", "name": n]) { ok, err in
            if ok { showToast("Kategori oprettet"); Task { await load() } } else { showToast(err ?? "Fejl") }
        }
    }

    func deleteCategory(_ cat: MenuCategory) {
        postJSON("app-menu-category.php", ["company_id": session.companyId, "action": "delete", "id": cat.id]) { ok, err in
            if ok { showToast("Kategori slettet"); Task { await load() } } else { showToast(err ?? "Fejl") }
        }
    }

    func showToast(_ msg: String) {
        withAnimation { toast = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { if toast == msg { withAnimation { toast = nil } } }
    }
}

struct MenuItemEditorView: View {
    let session: StaffSession
    let edit: MenuItemEdit
    var onDone: (String?) -> Void

    @State private var headline: String
    @State private var description: String
    @State private var price: String
    @State private var isSaving = false
    @State private var errorMessage = ""

    init(session: StaffSession, edit: MenuItemEdit, onDone: @escaping (String?) -> Void) {
        self.session = session
        self.edit = edit
        self.onDone = onDone
        _headline = State(initialValue: edit.headline)
        _description = State(initialValue: edit.description)
        _price = State(initialValue: edit.price)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Ret")) {
                    TextField("Navn", text: $headline)
                    TextField("Beskrivelse", text: $description, axis: .vertical).lineLimit(2...5)
                    HStack {
                        TextField("Pris", text: $price).keyboardType(.decimalPad)
                        Text("kr").foregroundColor(.secondary)
                    }
                }
                if !errorMessage.isEmpty {
                    Text(errorMessage).foregroundColor(.red).font(.subheadline)
                }
                Section {
                    Button(action: save) {
                        HStack { Spacer(); if isSaving { ProgressView() } else { Text("Gem").font(.headline) }; Spacer() }
                    }
                    .disabled(headline.isEmpty || isSaving)
                    .listRowBackground(wrombleRed.opacity(headline.isEmpty ? 0.4 : 1))
                    .foregroundColor(.white)
                }
                if edit.itemId > 0 {
                    Section {
                        Button(role: .destructive, action: delete) {
                            HStack { Spacer(); Text("Slet ret"); Spacer() }
                        }
                    }
                }
            }
            .navigationTitle(edit.itemId > 0 ? "Ret vare" : "Ny ret")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuller") { onDone(nil) } } }
        }
    }

    func save() {
        isSaving = true; errorMessage = ""
        var payload: [String: Any] = ["company_id": session.companyId, "action": "save",
                                      "cat_id": edit.catId, "headline": headline,
                                      "description": description, "price": Double(price.replacingOccurrences(of: ",", with: ".")) ?? 0]
        if edit.itemId > 0 { payload["id"] = edit.itemId }
        postJSON("app-menu-item.php", payload) { ok, err in
            isSaving = false
            if ok { onDone(edit.itemId > 0 ? "Ret opdateret" : "Ret tilfoejet") } else { errorMessage = err ?? "Kunne ikke gemme" }
        }
    }

    func delete() {
        isSaving = true
        postJSON("app-menu-item.php", ["company_id": session.companyId, "action": "delete", "id": edit.itemId]) { ok, err in
            isSaving = false
            if ok { onDone("Ret slettet") } else { errorMessage = err ?? "Kunne ikke slette" }
        }
    }
}

struct CompanyHoursView: View {
    let session: StaffSession
    @State private var days: [CompanyHourDay] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var toast: String?

    var body: some View {
        Form {
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else {
                Section {
                    Text("Lad felterne staa tomme paa de dage I holder lukket. Format: 10:00")
                        .font(.caption).foregroundColor(.secondary)
                }
                ForEach($days) { $day in
                    Section(header: Text(day.weekday)) {
                        timeRow(label: "Aabent", open: $day.store_open, close: $day.store_close)
                        timeRow(label: "Levering", open: $day.bring_open, close: $day.bring_close)
                    }
                }
            }
        }
        .navigationTitle("Aabningstider")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: save) { if isSaving { ProgressView() } else { Text("Gem") } }.disabled(isSaving || isLoading)
            }
        }
        .overlay(alignment: .bottom) { if let t = toast { StaffToast(text: t) } }
    }

    func timeRow(label: String, open: Binding<String>, close: Binding<String>) -> some View {
        HStack {
            Text(label).frame(width: 78, alignment: .leading).font(.subheadline)
            TextField("--:--", text: open).multilineTextAlignment(.center)
            Text("-").foregroundColor(.secondary)
            TextField("--:--", text: close).multilineTextAlignment(.center)
        }
    }

    func load() async {
        guard let url = URL(string: "\(baseURL)/api/app-company-hours.php?company_id=\(session.companyId)") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct Resp: Codable { let days: [CompanyHourDay] }
            let r = try JSONDecoder().decode(Resp.self, from: data)
            await MainActor.run { days = r.days; isLoading = false }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }

    func save() {
        isSaving = true
        let payloadDays = days.map { ["weekday": $0.weekday, "store_open": $0.store_open, "store_close": $0.store_close,
                                      "bring_open": $0.bring_open, "bring_close": $0.bring_close] }
        postJSON("app-company-hours.php", ["company_id": session.companyId, "days": payloadDays]) { ok, err in
            isSaving = false
            showToast(ok ? "Tider gemt" : (err ?? "Fejl"))
        }
    }

    func showToast(_ msg: String) {
        withAnimation { toast = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { if toast == msg { withAnimation { toast = nil } } }
    }
}

struct CompanyProfileView: View {
    let session: StaffSession
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var toast: String?

    @State private var companyname = ""
    @State private var adress = ""
    @State private var zipcode = ""
    @State private var city = ""
    @State private var phone = ""
    @State private var descriptionText = ""
    @State private var website = ""
    @State private var specialities = ""
    @State private var isOpen = true
    @State private var delivery = false
    @State private var deliveryPrice = ""
    @State private var deliveryTime = ""

    var body: some View {
        Form {
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else {
                Section(header: Text("Status")) {
                    Toggle(isOn: $isOpen) {
                        Label(isOpen ? "Aaben for bestillinger" : "Lukket", systemImage: isOpen ? "checkmark.circle.fill" : "xmark.circle.fill")
                    }.tint(.green)
                }
                Section(header: Text("Firma")) {
                    TextField("Firmanavn", text: $companyname)
                    TextField("Adresse", text: $adress)
                    HStack {
                        TextField("Postnr.", text: $zipcode).keyboardType(.numberPad).frame(width: 90)
                        TextField("By", text: $city)
                    }
                    TextField("Telefon", text: $phone).keyboardType(.phonePad)
                }
                Section(header: Text("Om forretningen")) {
                    TextField("Beskrivelse", text: $descriptionText, axis: .vertical).lineLimit(3...6)
                    TextField("Specialiteter", text: $specialities)
                    TextField("Hjemmeside", text: $website).keyboardType(.URL).autocapitalization(.none)
                }
                Section(header: Text("Levering")) {
                    Toggle(isOn: $delivery) { Label("Tilbyd levering", systemImage: "bicycle") }.tint(wrombleRed)
                    if delivery {
                        HStack {
                            TextField("Leveringspris", text: $deliveryPrice).keyboardType(.numberPad)
                            Text("kr").foregroundColor(.secondary)
                        }
                        TextField("Leveringstid (fx 30-45 min)", text: $deliveryTime)
                    }
                }
                if let t = toast {
                    Section { Text(t).foregroundColor(.green).font(.subheadline) }
                }
                Section {
                    Button(action: save) {
                        HStack { Spacer(); if isSaving { ProgressView() } else { Text("Gem aendringer").font(.headline) }; Spacer() }
                    }
                    .disabled(isSaving)
                    .listRowBackground(wrombleRed)
                    .foregroundColor(.white)
                }
            }
        }
        .navigationTitle("Indstillinger")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    func load() async {
        guard let url = URL(string: "\(baseURL)/api/app-company-profile.php?company_id=\(session.companyId)") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct Resp: Codable { let profile: CompanyProfile }
            let r = try JSONDecoder().decode(Resp.self, from: data)
            await MainActor.run {
                let p = r.profile
                companyname = p.companyname
                adress = p.adress
                zipcode = p.zipcode
                city = p.city
                phone = p.phone_mobile
                descriptionText = p.description
                website = p.website
                specialities = p.specialities
                isOpen = (p.shop_status != "Lukket")
                delivery = (p.com_delivery == 1)
                deliveryPrice = p.com_delivery_price > 0 ? String(p.com_delivery_price) : ""
                deliveryTime = p.com_delivery_time
                isLoading = false
            }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }

    func save() {
        isSaving = true
        let payload: [String: Any] = [
            "company_id": session.companyId,
            "companyname": companyname,
            "adress": adress,
            "zipcode": zipcode,
            "city": city,
            "phone_mobile": phone,
            "description": descriptionText,
            "specialities": specialities,
            "website": website,
            "shop_status": isOpen ? "Åben" : "Lukket",
            "com_delivery": delivery ? 1 : 0,
            "com_delivery_price": Int(deliveryPrice) ?? 0,
            "com_delivery_time": deliveryTime,
        ]
        postJSON("app-company-profile.php", payload) { ok, err in
            isSaving = false
            withAnimation { toast = ok ? "Gemt" : (err ?? "Fejl") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { withAnimation { toast = nil } }
        }
    }
}

// MARK: - Native Kontakt / Bliv partner / Job

// Fielles kvitterings-visning efter en formular er sendt
struct FormSuccessView: View {
    let title: String
    let message: String
    var onClose: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle().fill(Color.green.opacity(0.15)).frame(width: 96, height: 96)
                Image(systemName: "checkmark").font(.system(size: 44, weight: .bold)).foregroundColor(.green)
            }
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(message).font(.body).foregroundColor(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 20)
            Spacer()
            Button(action: onClose) {
                Text("Luk").font(.headline).foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(wrombleRed).cornerRadius(14)
            }
            .padding(.horizontal, 24).padding(.bottom, 20)
        }
    }
}

func postJSON(_ path: String, _ payload: [String: Any], completion: @escaping (Bool, String?) -> Void) {
    guard let url = URL(string: "\(baseURL)/api/\(path)") else { completion(false, "Ugyldig adresse"); return }
    var req = URLRequest(url: url); req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
    URLSession.shared.dataTask(with: req) { data, _, _ in
        DispatchQueue.main.async {
            guard let data = data,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(false, "Netvaerksfejl. Proev igen."); return
            }
            if let err = j["error"] as? String { completion(false, err); return }
            completion(j["success"] as? Bool == true, nil)
        }
    }.resume()
}

struct ContactFormView: View {
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var subject = ""
    @State private var message = ""
    @State private var isLoading = false
    @State private var sent = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            if sent {
                FormSuccessView(title: "Tak for din besked!",
                                message: "Vi har modtaget din besked og vender tilbage hurtigst muligt.",
                                onClose: { dismiss() })
            } else {
                Form {
                    Section(header: Text("Dine oplysninger")) {
                        TextField("Navn", text: $name).textContentType(.name)
                        TextField("Email", text: $email).keyboardType(.emailAddress).autocapitalization(.none).textContentType(.emailAddress)
                        TextField("Telefon (valgfrit)", text: $phone).keyboardType(.phonePad)
                    }
                    Section(header: Text("Besked")) {
                        TextField("Emne (valgfrit)", text: $subject)
                        TextField("Skriv din besked...", text: $message, axis: .vertical).lineLimit(4...8)
                    }
                    if !errorMessage.isEmpty {
                        Text(errorMessage).foregroundColor(.red).font(.subheadline)
                    }
                    Section {
                        Button(action: submit) {
                            HStack {
                                Spacer()
                                if isLoading { ProgressView() } else { Text("Send besked").font(.headline) }
                                Spacer()
                            }
                        }
                        .disabled(name.isEmpty || email.isEmpty || message.isEmpty || isLoading)
                        .listRowBackground(wrombleRed.opacity(name.isEmpty || email.isEmpty || message.isEmpty ? 0.4 : 1))
                        .foregroundColor(.white)
                    }
                }
                .navigationTitle("Kontakt os")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } } }
            }
        }
    }

    func submit() {
        isLoading = true; errorMessage = ""
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        postJSON("app-contact.php", ["name": name, "email": email, "phone": phone, "subject": subject, "message": message]) { ok, err in
            isLoading = false
            if ok { withAnimation { sent = true } } else { errorMessage = err ?? "Noget gik galt" }
        }
    }
}

struct PartnerFormView: View {
    @Environment(\.dismiss) var dismiss
    @State private var company = ""
    @State private var contact = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var city = ""
    @State private var message = ""
    @State private var isLoading = false
    @State private var sent = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            if sent {
                FormSuccessView(title: "Tak for din interesse!",
                                message: "Vi har modtaget din ansoegning og kontakter dig snarest for at komme i gang.",
                                onClose: { dismiss() })
            } else {
                Form {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Bliv partner hos Wromble").font(.headline)
                            Text("Faa din restaurant eller butik paa Wromble og naa flere kunder.")
                                .font(.subheadline).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }
                    Section(header: Text("Firma")) {
                        TextField("Firmanavn", text: $company)
                        TextField("By", text: $city)
                    }
                    Section(header: Text("Kontaktperson")) {
                        TextField("Navn", text: $contact).textContentType(.name)
                        TextField("Email", text: $email).keyboardType(.emailAddress).autocapitalization(.none).textContentType(.emailAddress)
                        TextField("Telefon", text: $phone).keyboardType(.phonePad)
                    }
                    Section(header: Text("Besked (valgfrit)")) {
                        TextField("Fortael os om din forretning...", text: $message, axis: .vertical).lineLimit(3...6)
                    }
                    if !errorMessage.isEmpty {
                        Text(errorMessage).foregroundColor(.red).font(.subheadline)
                    }
                    Section {
                        Button(action: submit) {
                            HStack {
                                Spacer()
                                if isLoading { ProgressView() } else { Text("Send ansoegning").font(.headline) }
                                Spacer()
                            }
                        }
                        .disabled(company.isEmpty || email.isEmpty || phone.isEmpty || isLoading)
                        .listRowBackground(wrombleRed.opacity(company.isEmpty || email.isEmpty || phone.isEmpty ? 0.4 : 1))
                        .foregroundColor(.white)
                    }
                }
                .navigationTitle("Bliv partner")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } } }
            }
        }
    }

    func submit() {
        isLoading = true; errorMessage = ""
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        postJSON("app-partner.php", ["company": company, "contact": contact, "email": email, "phone": phone, "city": city, "message": message]) { ok, err in
            isLoading = false
            if ok { withAnimation { sent = true } } else { errorMessage = err ?? "Noget gik galt" }
        }
    }
}

struct JobPost: Codable, Identifiable {
    let id: Int
    let title: String
    let hours: String
    let body: String
    let location: String
    let deadline: String
}

struct JobsView: View {
    @Environment(\.dismiss) var dismiss
    @State private var jobs: [JobPost] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView().scaleEffect(1.2)
                } else if jobs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "briefcase").font(.system(size: 44)).foregroundColor(.secondary)
                        Text("Ingen ledige stillinger").font(.headline)
                        Text("Der er ingen aabne jobopslag lige nu. Kig forbi igen senere.")
                            .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                } else {
                    List(jobs) { job in
                        NavigationLink(destination: JobApplyView(job: job)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(job.title).font(.headline)
                                HStack(spacing: 12) {
                                    if !job.location.isEmpty {
                                        Label(job.location, systemImage: "mappin.circle.fill").font(.caption).foregroundColor(.secondary)
                                    }
                                    if !job.hours.isEmpty {
                                        Label("\(job.hours) t/uge", systemImage: "clock.fill").font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Job hos Wromble")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } } }
            .task { await load() }
        }
    }

    func load() async {
        guard let url = URL(string: "\(baseURL)/api/app-jobs.php") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct Resp: Codable { let jobs: [JobPost] }
            let r = try JSONDecoder().decode(Resp.self, from: data)
            await MainActor.run { jobs = r.jobs; isLoading = false }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }
}

struct JobApplyView: View {
    let job: JobPost
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var message = ""
    @State private var isLoading = false
    @State private var sent = false
    @State private var errorMessage = ""

    var body: some View {
        if sent {
            FormSuccessView(title: "Ansoegning sendt!",
                            message: "Tak fordi du soegte stillingen som \(job.title). Vi kigger den igennem og vender tilbage.",
                            onClose: { dismiss() })
        } else {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(job.title).font(.title3.bold())
                        HStack(spacing: 12) {
                            if !job.location.isEmpty { Label(job.location, systemImage: "mappin.circle.fill").font(.caption).foregroundColor(.secondary) }
                            if !job.hours.isEmpty { Label("\(job.hours) t/uge", systemImage: "clock.fill").font(.caption).foregroundColor(.secondary) }
                        }
                        if !job.body.isEmpty {
                            Text(job.body).font(.subheadline).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section(header: Text("Din ansoegning")) {
                    TextField("Navn", text: $name).textContentType(.name)
                    TextField("Email", text: $email).keyboardType(.emailAddress).autocapitalization(.none).textContentType(.emailAddress)
                    TextField("Telefon", text: $phone).keyboardType(.phonePad)
                    TextField("Kort besked (valgfrit)", text: $message, axis: .vertical).lineLimit(3...6)
                }
                if !errorMessage.isEmpty {
                    Text(errorMessage).foregroundColor(.red).font(.subheadline)
                }
                Section {
                    Button(action: submit) {
                        HStack {
                            Spacer()
                            if isLoading { ProgressView() } else { Text("Send ansoegning").font(.headline) }
                            Spacer()
                        }
                    }
                    .disabled(name.isEmpty || email.isEmpty || phone.isEmpty || isLoading)
                    .listRowBackground(wrombleRed.opacity(name.isEmpty || email.isEmpty || phone.isEmpty ? 0.4 : 1))
                    .foregroundColor(.white)
                }
            }
            .navigationTitle("Soeg stilling")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    func submit() {
        isLoading = true; errorMessage = ""
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        postJSON("app-job-apply.php", ["job_id": job.id, "job_title": job.title, "name": name, "email": email, "phone": phone, "message": message]) { ok, err in
            isLoading = false
            if ok { withAnimation { sent = true } } else { errorMessage = err ?? "Noget gik galt" }
        }
    }
}

// MARK: - Kunde-profil (rediger egne oplysninger)

struct CustomerProfileView: View {
    let userId: Int
    @Environment(\.dismiss) var dismiss
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var toast: String?
    @State private var firstname = ""
    @State private var lastname = ""
    @State private var email = ""
    @State private var adress = ""
    @State private var zipcode = ""
    @State private var city = ""
    @State private var phone = ""

    var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else {
                    Section(header: Text("Navn")) {
                        TextField("Fornavn", text: $firstname)
                        TextField("Efternavn", text: $lastname)
                    }
                    Section(header: Text("Leveringsadresse")) {
                        TextField("Adresse", text: $adress)
                        HStack {
                            TextField("Postnr.", text: $zipcode).keyboardType(.numberPad).frame(width: 90)
                            TextField("By", text: $city)
                        }
                    }
                    Section(header: Text("Kontakt")) {
                        TextField("Telefon", text: $phone).keyboardType(.phonePad)
                        if !email.isEmpty {
                            HStack { Text("Email").foregroundColor(.secondary); Spacer(); Text(email).foregroundColor(.secondary) }
                        }
                    }
                    if let t = toast {
                        Section { Text(t).foregroundColor(.green).font(.subheadline) }
                    }
                    Section {
                        Button(action: save) {
                            HStack { Spacer(); if isSaving { ProgressView() } else { Text("Gem").font(.headline) }; Spacer() }
                        }
                        .disabled(isSaving)
                        .listRowBackground(wrombleRed)
                        .foregroundColor(.white)
                    }
                }
            }
            .navigationTitle("Mine oplysninger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } } }
            .task { await load() }
        }
    }

    func load() async {
        guard let url = URL(string: "\(baseURL)/api/app-user-profile.php?user_id=\(userId)") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct Resp: Codable { let profile: CustomerProfileData }
            let r = try JSONDecoder().decode(Resp.self, from: data)
            await MainActor.run {
                let p = r.profile
                firstname = p.firstname; lastname = p.lastname; email = p.email
                adress = p.adress; zipcode = p.zipcode; city = p.city; phone = p.phone
                isLoading = false
            }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }

    func save() {
        isSaving = true
        let payload: [String: Any] = [
            "user_id": userId, "firstname": firstname, "lastname": lastname,
            "adress": adress, "zipcode": zipcode, "city": city, "phone": phone,
        ]
        postJSON("app-user-profile.php", payload) { ok, err in
            isSaving = false
            withAnimation { toast = ok ? "Gemt" : (err ?? "Fejl") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { withAnimation { toast = nil } }
        }
    }
}

// MARK: - Home View

struct HomeView: View {
    @ObservedObject var locationManager: LocationManager
    @ObservedObject var favorites: FavoritesManager = .shared
    @ObservedObject var cart: CartManager = .shared
    @EnvironmentObject var appState: AppState
    @Environment(\.horizontalSizeClass) var sizeClass
    @State private var restaurants: [Restaurant] = []
    @State private var productCats: [ProductCat] = []
    @State private var searchText = ""
    @State private var selectedCatKey: String = "all"
    @State private var isLoading = true
    @State private var showCart = false
    @State private var showScanner = false
    @State private var showWromblePlus = false
    @State private var scannedRestaurant: Restaurant?
    @State private var scannedTable: Int?
    @State private var scanError: String?
    @State private var scanTitle = "Scan bordets QR-kode"
    @State private var scanSubtitle = "Hold kameraet over QR-koden paa bordet"

    var selectedCat: ProductCat? { productCats.first(where: { $0.key == selectedCatKey }) }

    // Firma-id -> eksempelprodukt for den valgte kategori (vises som chip paa kortet)
    var productByCompany: [Int: String] {
        guard let cat = selectedCat else { return [:] }
        var m = [Int: String]()
        for c in cat.companies { if let p = c.product, !p.isEmpty { m[c.id] = p } }
        return m
    }

    var filteredRestaurants: [Restaurant] {
        var list = restaurants
        if let cat = selectedCat {
            let ids = Set(cat.companies.map { $0.id })
            list = list.filter { ids.contains($0.id) }
        }
        if !searchText.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.address.localizedCaseInsensitiveContains(searchText) }
        }
        if let loc = locationManager.location {
            list.sort { r1, r2 in
                CLLocation(latitude: r1.lat, longitude: r1.lng).distance(from: loc) <
                CLLocation(latitude: r2.lat, longitude: r2.lng).distance(from: loc)
            }
        }
        return list
    }

    var favoriteRestaurants: [Restaurant] {
        restaurants.filter { favorites.isFavorite($0.id) }
    }

    // Firma-id -> Restaurant (til at aabne firmaet fra et produkt-kort)
    var restaurantById: [Int: Restaurant] {
        Dictionary(restaurants.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // Produkter i den valgte kategori (respekterer soegning) - vises som Wolt-agtige produkt-kort
    var selectedProducts: [CatProduct] {
        guard selectedCatKey != "all", let cat = selectedCat, let prods = cat.products else { return [] }
        if searchText.isEmpty { return prods }
        return prods.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            ($0.companyName?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var showingProducts: Bool { selectedCatKey != "all" && !(selectedCat?.products?.isEmpty ?? true) }

    var gridColumns: [GridItem] {
        sizeClass == .regular ? [GridItem(.adaptive(minimum: 300), spacing: 16)] : [GridItem(.flexible())]
    }

    var productColumns: [GridItem] {
        sizeClass == .regular
            ? [GridItem(.adaptive(minimum: 180), spacing: 14)]
            : [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Wromble")
                                .font(.system(size: sizeClass == .regular ? 38 : 28, weight: .heavy))
                                .foregroundColor(wrombleRed)
                            if locationManager.location != nil {
                                HStack(spacing: 4) {
                                    Image(systemName: "location.fill").font(.caption).foregroundColor(wrombleRed)
                                    Text("Naerliggende steder").font(.subheadline).foregroundColor(.secondary)
                                }
                            } else {
                                Text("Hvad har du lyst til i dag?").font(.subheadline).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        // Scan bordets QR-kode
                        Button(action: { startScan(store: false) }) {
                            VStack(spacing: 2) {
                                Image(systemName: "qrcode.viewfinder")
                                    .font(.system(size: sizeClass == .regular ? 30 : 26, weight: .semibold))
                                Text("Scan").font(.system(size: 10, weight: .bold))
                            }
                            .foregroundColor(wrombleRed)
                            .frame(width: 54, height: 54)
                            .background(wrombleRed.opacity(0.10))
                            .cornerRadius(14)
                        }
                    }
                    .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                    .padding(.top, 8).padding(.bottom, 16)

                    // Search
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                        TextField("Soeg restauranter, butikker...", text: $searchText)
                            .font(sizeClass == .regular ? .body : .subheadline)
                    }
                    .padding(sizeClass == .regular ? 14 : 12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                    .padding(.bottom, 16)

                    // Kategorier (Wolt-inspireret raekke med rigtige produktbilleder)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            // "Alle"-fliser foerst
                            categoryTileButton(key: "all", name: "Alle", image: nil)
                            ForEach(productCats) { cat in
                                categoryTileButton(key: cat.key, name: cat.name, image: cat.image)
                            }
                        }
                        .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                    }
                    .padding(.bottom, 20)

                    // Wromble+ band (som Wolt+)
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        showWromblePlus = true
                    }) {
                        WromblePlusBand()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                    .padding(.bottom, 22)

                    // Reklame: scan bordets QR-kode (som paa wromble.dk)
                    Button(action: { startScan(store: false) }) {
                        ScanBordBanner()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                    .padding(.bottom, 14)

                    // Reklame: scan i butikken og spring koeen over
                    Button(action: { startScan(store: true) }) {
                        StoreScanBanner()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                    .padding(.bottom, 22)

                    // Favorites section
                    if !favoriteRestaurants.isEmpty && searchText.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "heart.fill").foregroundColor(wrombleRed)
                                Text("Dine favoritter").font(.title3.bold())
                            }
                            .padding(.horizontal, sizeClass == .regular ? 24 : 16)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 14) {
                                    ForEach(favoriteRestaurants) { restaurant in
                                        NavigationLink(destination: RestaurantDetailView(restaurant: restaurant)) {
                                            FavoriteCard(restaurant: restaurant, userLocation: locationManager.location)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                            }
                        }
                        .padding(.bottom, 24)
                    }

                    // Restaurant-liste ELLER produkt-liste (naar en kategori er valgt)
                    if isLoading {
                        VStack(spacing: 16) {
                            ProgressView().scaleEffect(1.2)
                            Text("Henter restauranter...").font(.subheadline).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 60)
                    } else if showingProducts {
                        // Overskrift for den valgte kategori
                        HStack {
                            Text(selectedCat?.name ?? "Produkter").font(.title3.bold())
                            Spacer()
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                withAnimation(.easeOut(duration: 0.2)) { selectedCatKey = "all" }
                            }) {
                                Text("Vis alle").font(.subheadline.weight(.semibold)).foregroundColor(wrombleRed)
                            }
                        }
                        .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                        .padding(.bottom, 12)

                        if selectedProducts.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "magnifyingglass").font(.system(size: 40)).foregroundColor(.secondary)
                                Text("Ingen produkter").font(.headline)
                                Text("Proev en anden kategori").font(.subheadline).foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity).padding(.top, 40)
                        } else {
                            LazyVGrid(columns: productColumns, spacing: 14) {
                                ForEach(selectedProducts) { product in
                                    if let r = restaurantById[product.companyId] {
                                        NavigationLink(destination: RestaurantDetailView(restaurant: r)) {
                                            ProductTileCard(product: product)
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        ProductTileCard(product: product).opacity(0.6)
                                    }
                                }
                            }
                            .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                        }
                    } else if filteredRestaurants.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass").font(.system(size: 40)).foregroundColor(.secondary)
                            Text("Ingen resultater").font(.headline)
                            Text("Proev et andet soegeord").font(.subheadline).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        LazyVGrid(columns: gridColumns, spacing: sizeClass == .regular ? 16 : 12) {
                            ForEach(filteredRestaurants) { restaurant in
                                ZStack(alignment: .topLeading) {
                                    NavigationLink(destination: RestaurantDetailView(restaurant: restaurant)) {
                                        RestaurantCard(restaurant: restaurant,
                                                       userLocation: locationManager.location,
                                                       highlightProduct: productByCompany[restaurant.id],
                                                       showHeart: false)
                                    }
                                    .buttonStyle(.plain)
                                    // Hjerte i nederste hoejre hjoerne AF BILLEDET, saa det ikke daekker firmatype-badgen
                                    FavoriteHeartButton(id: restaurant.id)
                                        .padding(10)
                                        .frame(maxWidth: .infinity,
                                               maxHeight: sizeClass == .regular ? 180 : 140,
                                               alignment: .bottomTrailing)
                                }
                            }
                        }
                        .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                    }

                    Spacer(minLength: cart.itemCount > 0 ? 80 : 40)
                }
            }
            .navigationBarHidden(true)
            .refreshable { await loadRestaurants(); await loadCategories() }
            .task { await loadRestaurants(); await loadCategories() }
            .onAppear {
                if appState.locationEnabled { locationManager.requestLocation() }
            }

            // Floating cart bar
            if cart.itemCount > 0 {
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    showCart = true
                }) {
                    HStack {
                        Image(systemName: "cart.fill")
                        Text("\(cart.itemCount) varer").font(.headline)
                        Spacer()
                        Text(String(format: "%.2f kr", cart.total)).font(.headline)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .background(wrombleRed)
                    .cornerRadius(14)
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
                .shadow(color: .black.opacity(0.2), radius: 8, y: -2)
            }
        }
        .sheet(isPresented: $showCart) { CartView() }
        .fullScreenCover(isPresented: $showScanner) {
            QRScannerView(onScan: handleScan, onCancel: { showScanner = false },
                          promptTitle: scanTitle, promptSubtitle: scanSubtitle)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showWromblePlus) { WromblePlusView() }
        .sheet(item: $scannedRestaurant) { r in
            NavigationStack {
                RestaurantDetailView(restaurant: r, scannedTable: scannedTable)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Luk") { scannedRestaurant = nil }
                        }
                    }
            }
        }
        .alert("QR-kode", isPresented: Binding(get: { scanError != nil }, set: { if !$0 { scanError = nil } })) {
            Button("OK") { scanError = nil }
        } message: { Text(scanError ?? "") }
    }

    func startScan(store: Bool) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if store {
            scanTitle = "Scan i butikken"
            scanSubtitle = "Scan butikkens QR-kode og spring koeen over"
        } else {
            scanTitle = "Scan bordets QR-kode"
            scanSubtitle = "Hold kameraet over QR-koden paa bordet"
        }
        showScanner = true
    }

    func handleScan(_ code: String) {
        showScanner = false
        guard let comps = URLComponents(string: code) else {
            scanError = "QR-koden kunne ikke genkendes. Proev igen."
            return
        }
        let host = comps.host ?? ""
        guard host.contains("wromble.dk") else {
            scanError = "Denne QR-kode er ikke en Wromble-kode."
            return
        }

        // Bordnummer + evt. firma-id fra query (understoetter baade alias- og id-baserede koder)
        var table: Int? = nil
        var companyId: Int? = nil
        for it in comps.queryItems ?? [] {
            let name = it.name.lowercased()
            if name == "title", let v = it.value?.lowercased(), v.hasPrefix("bord") {
                table = Int(v.dropFirst(4))
            } else if name == "bord", let v = it.value {
                table = Int(v)
            } else if (name == "company" || name == "company_id" || name == "id"), let v = it.value {
                companyId = Int(v)
            }
        }

        // Find alias = foerste sti-segment der ikke er et kendt system-segment
        let skip: Set<String> = ["", "api", "r", "category", "login", "rider", "company", "track", "wromble-plus", "show-table-menu.php", "qr"]
        let segments = comps.path.split(separator: "/").map(String.init)
        let alias = segments.first(where: { !skip.contains($0.lowercased()) })

        // 1) match paa firma-id, 2) match paa alias
        var match: Restaurant? = nil
        if let cid = companyId { match = restaurants.first(where: { $0.id == cid }) }
        if match == nil, let alias = alias {
            match = restaurants.first(where: { $0.alias.lowercased() == alias.lowercased() })
        }

        if let match = match {
            scannedTable = table
            // Lille forsinkelse saa scanneren naar at lukke foer detaljen aabner
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                scannedRestaurant = match
            }
        } else {
            scanError = "Vi kunne ikke finde stedet i appen. Tjek at butikken er aktiv paa Wromble."
        }
    }

    // En kategori-flise (Wolt-stil): rigtigt produktbillede hvis muligt, ellers emoji+gradient
    func categoryTileButton(key: String, name: String, image: String?) -> some View {
        let isSel = selectedCatKey == key
        return Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeOut(duration: 0.2)) { selectedCatKey = key }
        }) {
            let style = catStyle(key)
            VStack(spacing: 7) {
                ZStack {
                    if let img = image, !img.isEmpty {
                        CachedAsyncImage(url: wrombleImageURL(img)) { phase in
                            switch phase {
                            case .success(let image): image.resizable().scaledToFill()
                            default: LinearGradient(colors: style.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                            }
                        }
                    } else {
                        ZStack {
                            LinearGradient(colors: style.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                            Text(style.emoji).font(.system(size: 32))
                                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        }
                    }
                }
                .frame(width: 72, height: 72)
                .clipped()
                .cornerRadius(18)
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(wrombleRed, lineWidth: isSel ? 3 : 0))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)

                Text(name)
                    .font(.caption2.weight(isSel ? .bold : .semibold))
                    .foregroundColor(isSel ? wrombleRed : .primary)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .frame(width: 82)
            }
        }
        .buttonStyle(.plain)
    }

    func loadRestaurants() async {
        guard let url = URL(string: "\(baseURL)/api/restaurants.php") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct Response: Codable { let restaurants: [Restaurant] }
            let response = try JSONDecoder().decode(Response.self, from: data)
            await MainActor.run { restaurants = response.restaurants; isLoading = false }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }

    func loadCategories() async {
        guard let url = URL(string: "\(baseURL)/api/home-categories.php") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct Response: Codable { let categories: [ProductCat] }
            let response = try JSONDecoder().decode(Response.self, from: data)
            await MainActor.run { productCats = response.categories }
        } catch {
            // Kategorier er ekstra - fejler stille hvis endpoint ikke svarer
        }
    }
}

// MARK: - Favorite Card (horizontal scroll)

struct FavoriteCard: View {
    let restaurant: Restaurant
    let userLocation: CLLocation?
    @Environment(\.horizontalSizeClass) var sizeClass

    var distance: String? {
        guard let loc = userLocation, restaurant.lat != 0 || restaurant.lng != 0 else { return nil }
        let d = CLLocation(latitude: restaurant.lat, longitude: restaurant.lng).distance(from: loc)
        return d < 1000 ? String(format: "%.0f m", d) : String(format: "%.1f km", d / 1000)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                if let img = restaurant.image, !img.isEmpty {
                    CachedAsyncImage(url: wrombleImageURL(img)) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFill()
                        default: placeholder
                        }
                    }
                    .frame(width: 160, height: 100).clipped()
                } else {
                    placeholder.frame(width: 160, height: 100)
                }

                if let dist = distance {
                    Text(dist)
                        .font(.caption2.bold()).foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.6)).cornerRadius(6)
                        .padding(6)
                }
            }
            .cornerRadius(10)

            Text(restaurant.name)
                .font(.caption.bold()).lineLimit(1)
                .frame(width: 160, alignment: .leading)
        }
    }

    var placeholder: some View {
        ZStack {
            Color(.tertiarySystemBackground)
            Image(systemName: restaurant.type == 2 ? "fork.knife" : "bag.fill")
                .font(.title2).foregroundColor(.secondary.opacity(0.4))
        }
    }
}

// MARK: - Restaurant Card

// Favorit-hjerte som ligger OVENPAA kortet (uden for NavigationLink) saa et tryk
// gemmer favoritten i stedet for at aabne restauranten.
struct FavoriteHeartButton: View {
    let id: Int
    @ObservedObject var favorites: FavoritesManager = .shared
    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            favorites.toggle(id)
        }) {
            Image(systemName: favorites.isFavorite(id) ? "heart.fill" : "heart")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(wrombleRed)
                .padding(9)
                .background(.ultraThinMaterial, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
    }
}

struct RestaurantCard: View {
    let restaurant: Restaurant
    let userLocation: CLLocation?
    var highlightProduct: String? = nil
    var showHeart: Bool = true
    @ObservedObject var favorites: FavoritesManager = .shared
    @Environment(\.horizontalSizeClass) var sizeClass

    var distance: String? {
        guard let loc = userLocation, restaurant.lat != 0 || restaurant.lng != 0 else { return nil }
        let d = CLLocation(latitude: restaurant.lat, longitude: restaurant.lng).distance(from: loc)
        return d < 1000 ? String(format: "%.0f m", d) : String(format: "%.1f km", d / 1000)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                if let img = restaurant.image, !img.isEmpty {
                    CachedAsyncImage(url: wrombleImageURL(img)) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFill()
                        default: restaurantPlaceholder
                        }
                    }
                    .frame(height: sizeClass == .regular ? 180 : 140).clipped()
                } else {
                    restaurantPlaceholder.frame(height: sizeClass == .regular ? 180 : 140)
                }

                HStack(spacing: 8) {
                    if let dist = distance {
                        HStack(spacing: 4) {
                            Image(systemName: "location.fill").font(.caption2)
                            Text(dist).font(.caption2.bold())
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.black.opacity(0.6)).cornerRadius(8)
                    }

                    Text(restaurant.type_label)
                        .font(.caption.weight(.bold)).foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(wrombleRed).cornerRadius(8)
                }
                .padding(10)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 10) {
                    // Firma-logo (firma-profil) ved siden af navnet
                    logoAvatar
                    Text(restaurant.name)
                        .font(sizeClass == .regular ? .title3.weight(.bold) : .headline)
                        .foregroundColor(.primary).lineLimit(1)
                    Spacer()
                    if showHeart {
                        Button(action: {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            favorites.toggle(restaurant.id)
                        }) {
                            Image(systemName: favorites.isFavorite(restaurant.id) ? "heart.fill" : "heart")
                                .foregroundColor(wrombleRed).font(.title3)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: "mappin.circle.fill").foregroundColor(wrombleRed).font(.caption)
                    Text(restaurant.address).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }

                if let hp = highlightProduct {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.seal.fill").font(.caption2)
                        Text(hp).font(.caption2.weight(.semibold)).lineLimit(1)
                    }
                    .foregroundColor(wrombleRed)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(wrombleRed.opacity(0.10)).cornerRadius(8)
                }

                HStack(spacing: 12) {
                    Label("\(restaurant.categories) kategorier", systemImage: "list.bullet")
                        .font(.caption2).foregroundColor(.secondary)
                    Label("\(restaurant.items) varer", systemImage: "cart")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .padding(sizeClass == .regular ? 14 : 12)
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    @ViewBuilder var logoAvatar: some View {
        if let logo = restaurant.logo, !logo.isEmpty {
            CachedAsyncImage(url: wrombleImageURL(logo)) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default: logoPlaceholder
                }
            }
            .frame(width: 44, height: 44).clipShape(Circle())
            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
            .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
        } else {
            logoPlaceholder
        }
    }

    var companyInitials: String {
        let parts = restaurant.name.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "W" : letters.uppercased()
    }

    var logoPlaceholder: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [wrombleRed, Color(red: 0.72, green: 0.05, blue: 0.09)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(companyInitials)
                .font(.system(size: 15, weight: .bold)).foregroundColor(.white)
        }
        .frame(width: 44, height: 44)
        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
    }

    var restaurantPlaceholder: some View {
        ZStack {
            Color(.tertiarySystemBackground)
            Image(systemName: restaurant.type == 2 ? "fork.knife" : "bag.fill")
                .font(.system(size: 36)).foregroundColor(.secondary.opacity(0.4))
        }
    }
}

// MARK: - Product Tile (kategori-produkt der linker til firmaet)

struct ProductTileCard: View {
    let product: CatProduct

    var priceText: String {
        guard let p = product.price, p > 0 else { return "" }
        return String(format: "%.0f kr", p)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if let img = product.image, !img.isEmpty {
                    CachedAsyncImage(url: wrombleImageURL(img)) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFill()
                        default: placeholder
                        }
                    }
                    .frame(height: 120).frame(maxWidth: .infinity).clipped()
                } else {
                    placeholder.frame(height: 120).frame(maxWidth: .infinity)
                }
            }
            .cornerRadius(14)

            VStack(alignment: .leading, spacing: 3) {
                Text(product.name)
                    .font(.subheadline.weight(.bold)).foregroundColor(.primary)
                    .lineLimit(1)
                if let cname = product.companyName, !cname.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "bag.circle.fill").font(.caption2).foregroundColor(wrombleRed)
                        Text(cname).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                if !priceText.isEmpty {
                    Text(priceText)
                        .font(.caption.weight(.bold)).foregroundColor(wrombleRed)
                        .padding(.top, 1)
                }
            }
            .padding(.top, 8).padding(.horizontal, 2)
        }
        .padding(8)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
    }

    var placeholder: some View {
        ZStack {
            LinearGradient(colors: [wrombleRed.opacity(0.18), wrombleRed.opacity(0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "fork.knife").font(.title).foregroundColor(wrombleRed.opacity(0.5))
        }
    }
}

// MARK: - Scan bordet reklame-banner (som paa wromble.dk)

struct ScanBordBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(wrombleRed.opacity(0.12))
                        .frame(width: 56, height: 56)
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(wrombleRed)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Scan bordets QR-kode")
                        .font(.headline).foregroundColor(.primary)
                    Text("Saet dig ved bordet, scan koden og bestil med det samme")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                scanStep(number: "1", icon: "person.fill", text: "Saet dig")
                stepArrow
                scanStep(number: "2", icon: "qrcode.viewfinder", text: "Scan QR")
                stepArrow
                scanStep(number: "3", icon: "bag.fill", text: "Bestil")
            }

            HStack {
                Text("Scan nu")
                    .font(.subheadline.weight(.bold)).foregroundColor(.white)
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.bold)).foregroundColor(.white)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(wrombleRed).cornerRadius(12)
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(20)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(wrombleRed.opacity(0.15), lineWidth: 1))
    }

    func scanStep(number: String, icon: String, text: String) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(wrombleRed.opacity(0.10)).frame(width: 40, height: 40)
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundColor(wrombleRed)
            }
            Text(text).font(.caption2.weight(.medium)).foregroundColor(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    var stepArrow: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.bold)).foregroundColor(.secondary.opacity(0.5))
    }
}

// Scan i butikken - spring koeen over (som paa wromble.dk)
struct StoreScanBanner: View {
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(wrombleRed.opacity(0.12))
                    .frame(width: 56, height: 56)
                Image(systemName: "cart.badge.plus")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(wrombleRed)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Scan i butikken")
                    .font(.headline).foregroundColor(.primary)
                Text("Scan butikkens QR-kode, bestil i appen og spring koeen over")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(wrombleRed)
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(20)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(wrombleRed.opacity(0.15), lineWidth: 1))
    }
}

// MARK: - Wromble+ Band + Sheet

struct WromblePlusBand: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(colors: [Color(red: 0.89, green: 0.06, blue: 0.12),
                                              Color(red: 0.69, green: 0.05, blue: 0.09)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.18)).frame(width: 50, height: 50)
                    Image(systemName: "star.circle.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Wromble+")
                            .font(.title3.weight(.heavy)).foregroundColor(.white)
                            .fixedSize()
                        Text("NYT")
                            .font(.system(size: 10, weight: .heavy)).foregroundColor(wrombleRed)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.white).cornerRadius(5)
                    }
                    Text("Gratis levering – hver gang")
                        .font(.subheadline.weight(.semibold)).foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Kun 59,- pr. måned")
                        .font(.caption).foregroundColor(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)

                Spacer(minLength: 6)

                Text("Kom i gang")
                    .font(.caption.weight(.bold)).foregroundColor(wrombleRed)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(Color.white).cornerRadius(12)
                    .fixedSize()
            }
            .padding(.horizontal, 16).padding(.vertical, 16)
        }
        .fixedSize(horizontal: false, vertical: true)
        .shadow(color: wrombleRed.opacity(0.25), radius: 8, y: 4)
    }
}

struct WromblePlusView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.horizontalSizeClass) var sizeClass
    @Environment(\.openURL) var openURL

    let benefits: [(String, String, String)] = [
        ("bicycle", "Gratis levering", "Ingen leveringsgebyr på dine ordrer – hver gang du bestiller."),
        ("tag.fill", "Faste lave priser", "Adgang til Wromble+ tilbud og priser hos dine favoritter."),
        ("bolt.fill", "Nemt & enkelt", "Ingen binding. Opsig når som helst – helt uden bøvl."),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 24)
                            .fill(LinearGradient(colors: [Color(red: 0.89, green: 0.06, blue: 0.12),
                                                          Color(red: 0.69, green: 0.05, blue: 0.09)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                        VStack(spacing: 8) {
                            Image(systemName: "star.circle.fill")
                                .font(.system(size: 56)).foregroundColor(.white)
                            Text("Wromble+").font(.largeTitle.weight(.heavy)).foregroundColor(.white)
                            Text("Gratis levering hver gang")
                                .font(.headline).foregroundColor(.white.opacity(0.9))
                        }
                        .padding(.vertical, 30)
                    }
                    .padding(.horizontal, 20)

                    VStack(spacing: 16) {
                        ForEach(benefits, id: \.0) { b in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: b.0)
                                    .font(.title2).foregroundColor(wrombleRed)
                                    .frame(width: 40, height: 40)
                                    .background(wrombleRed.opacity(0.10)).cornerRadius(10)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(b.1).font(.headline)
                                    Text(b.2).font(.subheadline).foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding(.horizontal, 24)

                    VStack(spacing: 4) {
                        Text("Kun 59,- pr. måned").font(.title2.bold())
                        Text("Ingen binding · opsig når som helst")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.top, 4)

                    Button(action: {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        if let u = URL(string: "\(baseURL)/wromble-plus/") { openURL(u) }
                    }) {
                        Text("Kom i gang")
                            .font(.headline).foregroundColor(.white)
                            .frame(maxWidth: sizeClass == .regular ? 400 : .infinity)
                            .padding(.vertical, 16)
                            .background(wrombleRed).cornerRadius(14)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 30)
                }
                .padding(.top, 10)
            }
            .navigationTitle("Wromble+")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } }
            }
        }
    }
}

// MARK: - QR Scanner (AVFoundation)

struct QRScannerView: UIViewControllerRepresentable {
    var onScan: (String) -> Void
    var onCancel: () -> Void
    var promptTitle: String = "Scan QR-koden"
    var promptSubtitle: String = "Hold kameraet over QR-koden"

    func makeUIViewController(context: Context) -> QRScannerController {
        let vc = QRScannerController()
        vc.onScan = onScan
        vc.onCancel = onCancel
        vc.promptTitle = promptTitle
        vc.promptSubtitle = promptSubtitle
        return vc
    }
    func updateUIViewController(_ uiViewController: QRScannerController, context: Context) {}
}

class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var promptTitle: String = "Scan QR-koden"
    var promptSubtitle: String = "Hold kameraet over QR-koden"
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var didScan = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupSession()
        setupOverlay()
    }

    private func setupSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        let pl = AVCaptureVideoPreviewLayer(session: session)
        pl.videoGravity = .resizeAspectFill
        pl.frame = view.layer.bounds
        view.layer.addSublayer(pl)
        preview = pl

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    private func setupOverlay() {
        // Halvgennemsigtig maske med et klart scan-vindue i midten
        let overlay = UIView(frame: view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        let side: CGFloat = min(view.bounds.width, view.bounds.height) * 0.66
        let box = CGRect(x: (view.bounds.width - side) / 2, y: (view.bounds.height - side) / 2, width: side, height: side)
        let path = UIBezierPath(rect: overlay.bounds)
        path.append(UIBezierPath(roundedRect: box, cornerRadius: 20).reversing())
        let mask = CAShapeLayer(); mask.path = path.cgPath
        overlay.layer.mask = mask
        view.addSubview(overlay)

        let frameView = UIView(frame: box)
        frameView.layer.borderColor = UIColor.white.cgColor
        frameView.layer.borderWidth = 3
        frameView.layer.cornerRadius = 20
        view.addSubview(frameView)

        let label = UILabel()
        label.text = promptTitle
        label.textColor = .white
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.textAlignment = .center
        label.frame = CGRect(x: 0, y: box.minY - 54, width: view.bounds.width, height: 30)
        label.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]
        view.addSubview(label)

        let sub = UILabel()
        sub.text = promptSubtitle
        sub.textColor = UIColor.white.withAlphaComponent(0.85)
        sub.font = .systemFont(ofSize: 14)
        sub.textAlignment = .center
        sub.frame = CGRect(x: 0, y: box.maxY + 18, width: view.bounds.width, height: 22)
        sub.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        view.addSubview(sub)

        let cancel = UIButton(type: .system)
        cancel.setTitle("Annuller", for: .normal)
        cancel.setTitleColor(.white, for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        cancel.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        cancel.layer.cornerRadius = 12
        cancel.frame = CGRect(x: (view.bounds.width - 140) / 2, y: view.bounds.height - 90, width: 140, height: 46)
        cancel.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin]
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        view.addSubview(cancel)
    }

    @objc private func cancelTapped() {
        session.stopRunning()
        onCancel?()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.layer.bounds
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !didScan,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              obj.type == .qr,
              let value = obj.stringValue else { return }
        didScan = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        session.stopRunning()
        onScan?(value)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }
}

// MARK: - Map Tab (MapKit)

struct MapTabView: View {
    @ObservedObject var locationManager: LocationManager
    @EnvironmentObject var appState: AppState
    @Environment(\.horizontalSizeClass) var sizeClass
    @State private var restaurants: [Restaurant] = []
    @State private var isLoading = true
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 55.676, longitude: 12.568),
        span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15)
    )
    @State private var selectedRestaurant: Restaurant?
    @State private var highlightedId: Int?
    @State private var pendingCenter = false

    var mappableRestaurants: [Restaurant] {
        restaurants.filter { $0.lat != 0 || $0.lng != 0 }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(coordinateRegion: $region, showsUserLocation: true, annotationItems: mappableRestaurants) { restaurant in
                MapAnnotation(coordinate: CLLocationCoordinate2D(latitude: restaurant.lat, longitude: restaurant.lng)) {
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            highlightedId = restaurant.id
                        }
                    }) {
                        let isHighlighted = highlightedId == restaurant.id
                        VStack(spacing: 3) {
                            ZStack {
                                Circle()
                                    .fill(wrombleRed)
                                    .frame(width: isHighlighted ? 44 : 36, height: isHighlighted ? 44 : 36)
                                Image(systemName: restaurant.type == 2 ? "fork.knife" : "bag.fill")
                                    .font(.system(size: isHighlighted ? 19 : 16, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            .overlay(Circle().stroke(.white, lineWidth: 2.5))
                            .shadow(color: .black.opacity(0.25), radius: isHighlighted ? 6 : 3, y: 2)

                            if isHighlighted {
                                Text(restaurant.name)
                                    .font(.caption2.bold())
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isHighlighted)
                    }
                }
            }
            .edgesIgnoringSafeArea(.bottom)
            .overlay(alignment: .top) {
                if isLoading {
                    ProgressView()
                        .padding(14)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.top, 12)
                }
            }
            // Flydende "Min placering"-knap (som i Apple/Google Maps)
            .overlay(alignment: .bottomTrailing) {
                Button(action: centerOnUser) {
                    ZStack {
                        Circle().fill(Color(.systemBackground))
                            .frame(width: 50, height: 50)
                            .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
                        Image(systemName: "location.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(wrombleRed)
                    }
                }
                .accessibilityLabel("Min placering")
                .padding(.trailing, 16)
                .padding(.bottom, mappableRestaurants.isEmpty ? 30 : 130)
            }

            if !mappableRestaurants.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(mappableRestaurants) { restaurant in
                                MapRestaurantCard(
                                    restaurant: restaurant,
                                    isHighlighted: highlightedId == restaurant.id
                                )
                                .id(restaurant.id)
                                .onTapGesture {
                                    selectedRestaurant = restaurant
                                }
                                .onAppear {
                                    // Keep the map pin in sync as the person scrolls the carousel.
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                    .background(.ultraThinMaterial)
                    .onChange(of: highlightedId) { id in
                        guard let id = id else { return }
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                        if let r = mappableRestaurants.first(where: { $0.id == id }) {
                            withAnimation {
                                region.center = CLLocationCoordinate2D(latitude: r.lat, longitude: r.lng)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Kort")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: centerOnUser) {
                    Image(systemName: "location.fill")
                        .foregroundColor(wrombleRed)
                }
            }
        }
        .sheet(item: $selectedRestaurant) { restaurant in
            NavigationStack {
                RestaurantDetailView(restaurant: restaurant)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Luk") { selectedRestaurant = nil }
                        }
                    }
            }
        }
        .task { await loadRestaurants() }
        .onAppear {
            if appState.locationEnabled { locationManager.requestLocation() }
        }
        .onChange(of: locationManager.location) { newLoc in
            guard pendingCenter, let loc = newLoc else { return }
            pendingCenter = false
            withAnimation {
                region.center = loc.coordinate
                region.span = MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
            }
        }
    }

    func centerOnUser() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if let loc = locationManager.location {
            withAnimation {
                region.center = loc.coordinate
                region.span = MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
            }
        } else {
            // Ingen placering endnu - bed om tilladelse/opdatering og centrér naar den kommer
            pendingCenter = true
            locationManager.requestLocation()
        }
    }

    func loadRestaurants() async {
        guard let url = URL(string: "\(baseURL)/api/restaurants.php") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct Response: Codable { let restaurants: [Restaurant] }
            let response = try JSONDecoder().decode(Response.self, from: data)
            await MainActor.run {
                restaurants = response.restaurants
                isLoading = false
                if let first = mappableRestaurants.first, locationManager.location == nil {
                    region.center = CLLocationCoordinate2D(latitude: first.lat, longitude: first.lng)
                    highlightedId = first.id
                } else if let loc = locationManager.location {
                    region.center = loc.coordinate
                }
            }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }
}

struct MapRestaurantCard: View {
    let restaurant: Restaurant
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.secondarySystemBackground))
                    .frame(width: 46, height: 46)
                Image(systemName: restaurant.type == 2 ? "fork.knife" : "bag.fill")
                    .foregroundColor(wrombleRed)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(restaurant.name)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(restaurant.address)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(width: 230)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(isHighlighted ? 0.15 : 0.06), radius: isHighlighted ? 8 : 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isHighlighted ? wrombleRed : .clear, lineWidth: 2)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isHighlighted)
    }
}

// MARK: - Restaurant Detail

struct RestaurantDetailView: View {
    let restaurant: Restaurant
    var scannedTable: Int? = nil
    @ObservedObject var cart: CartManager = .shared
    @ObservedObject var favorites: FavoritesManager = .shared
    @Environment(\.horizontalSizeClass) var sizeClass
    @State private var categories: [MenuCategory] = []
    @State private var isLoading = true
    @State private var showCart = false
    @State private var showClearCartAlert = false
    @State private var pendingItem: MenuItem?
    @State private var hoursDays: [CompanyHourDay] = []
    @State private var shopStatus: String = ""
    @State private var showClosedAlert = false
    var visibleCategories: [MenuCategory] { categories.filter { !$0.products.isEmpty } }

    // Dagens aabningstid (butik) + aaben/lukket-status, synkroniseret med wromble.dk
    var todayHours: CompanyHourDay? {
        let idx = Calendar.current.component(.weekday, from: Date()) // 1=Soendag
        let names = ["Søndag","Mandag","Tirsdag","Onsdag","Torsdag","Fredag","Lørdag"]
        guard idx >= 1 && idx <= 7 else { return nil }
        return hoursDays.first { $0.weekday == names[idx - 1] }
    }
    var openState: ShopOpenState { wrombleShopOpenState(hoursDays, shopStatus: shopStatus) }
    var isOpenNow: Bool { openState.isOpen }
    var closedMessage: String {
        if openState.manuallyClosed { return "Butikken er lukket lige nu. Du kan bestille, naar den aabner igen." }
        if let n = openState.nextOpenText { return "Butikken er lukket lige nu – aabner \(n)." }
        return "Butikken er lukket lige nu."
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            menuContent

            if cart.itemCount > 0 && cart.restaurantId == restaurant.id {
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    showCart = true
                }) {
                    HStack {
                        Image(systemName: "cart.fill")
                        Text("Se kurv (\(cart.itemCount))").font(.headline)
                        Spacer()
                        Text(String(format: "%.2f kr", cart.total)).font(.headline)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .background(wrombleRed).cornerRadius(14)
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
                .shadow(color: .black.opacity(0.2), radius: 8, y: -2)
            }
        }
        .navigationTitle(restaurant.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        favorites.toggle(restaurant.id)
                    }) {
                        Image(systemName: favorites.isFavorite(restaurant.id) ? "heart.fill" : "heart")
                            .foregroundColor(wrombleRed)
                    }
                    if restaurant.lat != 0 || restaurant.lng != 0 {
                        Button(action: openInMaps) {
                            Image(systemName: "map").foregroundColor(wrombleRed)
                        }
                    }
                    ShareLink(item: "\(restaurant.name) paa Wromble: \(baseURL)/\(restaurant.alias)/") {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(isPresented: $showCart) { CartView() }
        .alert("Ryd kurv?", isPresented: $showClearCartAlert) {
            Button("Ja, ryd kurven", role: .destructive) {
                if let item = pendingItem {
                    cart.addItem(item, forRestaurant: restaurant.id, name: restaurant.name)
                    pendingItem = nil
                }
            }
            Button("Annuller", role: .cancel) { pendingItem = nil }
        } message: {
            Text("Du har varer fra \(cart.restaurantName) i kurven. Vil du rydde den og tilfoeje fra \(restaurant.name)?")
        }
        .alert("Butikken er lukket", isPresented: $showClosedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(closedMessage)
        }
        .task { await loadHours(); await loadMenu() }
    }

    var menuContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Restaurant header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(restaurant.type_label)
                                .font(.caption.weight(.bold)).foregroundColor(.white)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(wrombleRed).cornerRadius(6)
                            Text(restaurant.name)
                                .font(sizeClass == .regular ? .title.bold() : .title2.bold())
                        }
                        Spacer()
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.circle.fill").foregroundColor(wrombleRed)
                        Text(restaurant.address).font(.subheadline).foregroundColor(.secondary)
                    }

                    // Aaben/lukket-status. Ved lukket vises hvornaar butikken aabner igen.
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Circle().fill(isOpenNow ? Color.green : wrombleRed).frame(width: 9, height: 9)
                            Text(isOpenNow ? "Aabent nu" : "Lukket")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(isOpenNow ? .green : wrombleRed)
                            if isOpenNow, let h = todayHours, !h.store_open.isEmpty, !h.store_close.isEmpty {
                                Text("· I dag \(h.store_open)–\(h.store_close)")
                                    .font(.subheadline).foregroundColor(.secondary)
                            }
                        }
                        if !isOpenNow {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "clock.badge.exclamationmark").foregroundColor(wrombleRed)
                                Text(closedMessage)
                                    .font(.subheadline).foregroundColor(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(wrombleRed.opacity(0.08))
                            .cornerRadius(10)
                        }
                    }

                    if let table = scannedTable {
                        HStack(spacing: 10) {
                            Image(systemName: "qrcode")
                                .font(.title3).foregroundColor(.white)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Bord \(table)").font(.subheadline.weight(.bold)).foregroundColor(.white)
                                Text("Bestil her – så serverer vi ved dit bord")
                                    .font(.caption).foregroundColor(.white.opacity(0.9))
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(wrombleRed)
                        .cornerRadius(12)
                        .padding(.top, 6)
                    }
                }
                .padding(sizeClass == .regular ? 24 : 16)

                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if visibleCategories.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "menucard").font(.system(size: 40)).foregroundColor(.secondary)
                        Text("Ingen menukort endnu").font(.headline).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    ForEach(visibleCategories) { category in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(category.name)
                                .font(sizeClass == .regular ? .title2.bold() : .title3.bold())
                                .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                                .padding(.top, 12)

                            ForEach(category.products) { item in
                                MenuItemRow(item: item, onAdd: { addToCart(item) })
                                    .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                            }
                        }
                        if category.id != visibleCategories.last?.id {
                            Divider()
                                .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                                .padding(.vertical, 8)
                        }
                    }
                }

                Spacer(minLength: cart.itemCount > 0 ? 80 : 40)
            }
        }
    }

    func addToCart(_ item: MenuItem) {
        // Bloker bestilling naar butikken er lukket (aabningstider eller manuel lukning)
        guard isOpenNow else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            showClosedAlert = true
            return
        }
        if cart.restaurantId != 0 && cart.restaurantId != restaurant.id && !cart.items.isEmpty {
            pendingItem = item
            showClearCartAlert = true
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            cart.addItem(item, forRestaurant: restaurant.id, name: restaurant.name)
        }
    }

    func openInMaps() {
        let coordinate = CLLocationCoordinate2D(latitude: restaurant.lat, longitude: restaurant.lng)
        let placemark = MKPlacemark(coordinate: coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = restaurant.name
        mapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    func loadMenu() async {
        guard let url = URL(string: "\(baseURL)/api/menu.php?company_id=\(restaurant.id)") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct CompanyInfo: Codable { let id: Int; let name: String }
            struct Response: Codable { let company: CompanyInfo?; let categories: [MenuCategory] }
            let response = try JSONDecoder().decode(Response.self, from: data)
            await MainActor.run { categories = response.categories; isLoading = false }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }

    func loadHours() async {
        guard let url = URL(string: "\(baseURL)/api/app-company-hours.php?company_id=\(restaurant.id)") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct Resp: Codable { let days: [CompanyHourDay]; let shop_status: String? }
            let r = try JSONDecoder().decode(Resp.self, from: data)
            await MainActor.run { hoursDays = r.days; shopStatus = r.shop_status ?? "" }
        } catch { }
    }
}

// MARK: - Menu Item Row

struct MenuItemRow: View {
    let item: MenuItem
    var onAdd: () -> Void
    @ObservedObject var cart: CartManager = .shared
    @Environment(\.horizontalSizeClass) var sizeClass

    var quantityInCart: Int {
        cart.items.first(where: { $0.id == item.id })?.quantity ?? 0
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(sizeClass == .regular ? .body.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                if let desc = item.description, !desc.isEmpty {
                    Text(desc).font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
                Text(String(format: "%.2f kr", item.price))
                    .font(.subheadline.weight(.bold)).foregroundColor(wrombleRed)
            }

            Spacer()

            if let img = item.image, !img.isEmpty {
                CachedAsyncImage(url: wrombleImageURL(img)) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default: Color(.tertiarySystemBackground)
                    }
                }
                .frame(width: sizeClass == .regular ? 80 : 64, height: sizeClass == .regular ? 80 : 64)
                .cornerRadius(10).clipped()
            }

            Button(action: onAdd) {
                if quantityInCart > 0 {
                    HStack(spacing: 6) {
                        Button(action: { cart.removeItem(item.id) }) {
                            Image(systemName: "minus.circle.fill").font(.title3).foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)

                        Text("\(quantityInCart)")
                            .font(.subheadline.bold()).frame(minWidth: 20)

                        Image(systemName: "plus.circle.fill").font(.title3).foregroundColor(wrombleRed)
                    }
                } else {
                    Image(systemName: "plus.circle.fill").font(.title2).foregroundColor(wrombleRed)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Cart View

struct CartView: View {
    @ObservedObject var cart: CartManager = .shared
    @Environment(\.dismiss) var dismiss
    @Environment(\.horizontalSizeClass) var sizeClass
    @State private var orderNote = ""
    @State private var isOrdering = false
    @State private var showOrderConfirmation = false
    @State private var orderId: Int = 0
    @State private var showLoginSheet = false
    @State private var loggedInUser: UserProfile?
    @State private var errorMessage = ""
    // Levering/afhentning + betaling (samme flow som wromble.dk)
    @State private var isDelivery = false            // false = Afhentning, true = Levering
    @State private var deliveryAddress = ""
    @State private var paymentMethod = 2             // 1 = Online betaling, 2 = Kontanter
    // Aabningstider for butikken i kurven - saa der ikke kan bestilles naar lukket
    @State private var hoursDays: [CompanyHourDay] = []
    @State private var shopStatus = ""
    var cartOpenState: ShopOpenState { wrombleShopOpenState(hoursDays, shopStatus: shopStatus) }
    var cartClosedMessage: String {
        if cartOpenState.manuallyClosed { return "\(cart.restaurantName) er lukket lige nu. Du kan bestille, naar butikken aabner igen." }
        if let n = cartOpenState.nextOpenText { return "\(cart.restaurantName) er lukket lige nu – aabner \(n)." }
        return "\(cart.restaurantName) er lukket lige nu."
    }

    var body: some View {
        NavigationStack {
            if showOrderConfirmation {
                orderConfirmation
            } else if cart.items.isEmpty {
                emptyCart
            } else {
                cartContent
            }
        }
    }

    var emptyCart: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "cart").font(.system(size: 60)).foregroundColor(.secondary)
            Text("Din kurv er tom").font(.title2.bold())
            Text("Tilfoej varer fra en restaurant").foregroundColor(.secondary)
            Button("Luk") { dismiss() }.font(.headline).foregroundColor(wrombleRed)
            Spacer()
        }
        .navigationTitle("Kurv")
    }

    var cartContent: some View {
        List {
            Section(header: Text(cart.restaurantName)) {
                ForEach(cart.items) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.headline)
                            Text(String(format: "%.2f kr", item.price)).font(.subheadline).foregroundColor(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 14) {
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                cart.removeItem(item.id)
                            }) {
                                Image(systemName: "minus.circle.fill").font(.title3).foregroundColor(.red)
                            }
                            .buttonStyle(.borderless)

                            Text("\(item.quantity)").font(.headline).frame(minWidth: 24)

                            Button(action: {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                if let idx = cart.items.firstIndex(where: { $0.id == item.id }) {
                                    cart.items[idx].quantity += 1
                                }
                            }) {
                                Image(systemName: "plus.circle.fill").font(.title3).foregroundColor(wrombleRed)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            // Levering eller afhentning (som paa wromble.dk)
            Section(header: Text("Levering eller afhentning")) {
                Picker("", selection: $isDelivery) {
                    Text("Afhentning").tag(false)
                    Text("Levering").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                if isDelivery {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.and.ellipse").foregroundColor(wrombleRed)
                        TextField("Leveringsadresse", text: $deliveryAddress)
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "bag.fill").foregroundColor(wrombleRed)
                        Text("Du henter selv hos restauranten").font(.subheadline).foregroundColor(.secondary)
                    }
                }
            }

            // Betalingsmetode (som paa wromble.dk)
            Section(header: Text("Betalingsmetode")) {
                Button(action: { paymentMethod = 2 }) {
                    HStack {
                        Image(systemName: "banknote").foregroundColor(wrombleRed)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Kontanter").foregroundColor(.primary)
                            Text("Betal ved afhentning/levering").font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        if paymentMethod == 2 { Image(systemName: "checkmark.circle.fill").foregroundColor(wrombleRed) }
                    }
                }
                Button(action: { paymentMethod = 1 }) {
                    HStack {
                        Image(systemName: "creditcard").foregroundColor(wrombleRed)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Online betaling").foregroundColor(.primary)
                            Text("Kort · MobilePay · Apple Pay").font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        if paymentMethod == 1 { Image(systemName: "checkmark.circle.fill").foregroundColor(wrombleRed) }
                    }
                }
            }

            Section(header: Text("Note til restaurant")) {
                TextField("Allergier, leveringsinstruktioner...", text: $orderNote)
            }

            Section {
                HStack {
                    Text("Total").font(.title3.bold())
                    Spacer()
                    Text(String(format: "%.2f kr", cart.total)).font(.title3.bold()).foregroundColor(wrombleRed)
                }
            }

            if !errorMessage.isEmpty {
                Section {
                    Text(errorMessage).foregroundColor(.red).font(.subheadline)
                }
            }

            if !cartOpenState.isOpen && !hoursDays.isEmpty {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "clock.badge.exclamationmark").foregroundColor(wrombleRed)
                        Text(cartClosedMessage).font(.subheadline).foregroundColor(.primary)
                    }
                }
            }

            Section {
                Button(action: placeOrder) {
                    HStack {
                        Spacer()
                        if isOrdering {
                            ProgressView().tint(.white)
                        } else {
                            Text(cartOpenState.isOpen || hoursDays.isEmpty ? "Bestil nu" : "Butikken er lukket").font(.headline)
                        }
                        Spacer()
                    }
                    .foregroundColor(.white)
                    .padding(.vertical, 6)
                }
                .listRowBackground((cartOpenState.isOpen || hoursDays.isEmpty) ? wrombleRed : Color.gray)
                .disabled(isOrdering || (!cartOpenState.isOpen && !hoursDays.isEmpty))
            }
        }
        .navigationTitle("Din kurv")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } }
            ToolbarItem(placement: .destructiveAction) {
                Button("Ryd") {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    cart.clear()
                }.foregroundColor(.red)
            }
        }
        .sheet(isPresented: $showLoginSheet) {
            NavigationStack {
                LoginView(onLogin: { user in
                    loggedInUser = user
                    if user.id > 0 {
                        UserDefaults.standard.set(user.id, forKey: "loggedInUserId")
                        UserDefaults.standard.set("\(user.id)", forKey: "userId")
                        UserDefaults.standard.set(user.name, forKey: "loggedInUserName")
                        UserDefaults.standard.set(user.email, forKey: "loggedInUserEmail")
                        registerPushToken(userId: user.id)
                        showLoginSheet = false
                        submitOrder(userId: user.id)
                    }
                })
                .navigationTitle("Log ind for at bestille")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Luk") { showLoginSheet = false } }
                }
            }
        }
        .onAppear { loadUser() }
        .task { await loadCartHours() }
    }

    var orderConfirmation: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80)).foregroundColor(.green)
            Text("Ordre modtaget!").font(.title.bold())
            Text("Ordrenummer: #\(orderId)")
                .font(.title3).foregroundColor(.secondary)
            Text("Din ordre er sendt til restauranten og afventer nu deres bekraeftelse. Du faar besked, saa snart den er accepteret.")
                .font(.body).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            VStack(spacing: 12) {
                NavigationLink(destination: OrderTrackingView(orderId: orderId, initialCompany: cart.restaurantName)) {
                    HStack {
                        Image(systemName: "map.fill")
                        Text("Følg din ordre").font(.headline)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: sizeClass == .regular ? 300 : .infinity)
                    .padding(.vertical, 16)
                    .background(wrombleRed).cornerRadius(14)
                }
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    cart.clear()
                    dismiss()
                }) {
                    Text("Faerdig")
                        .font(.headline).foregroundColor(.secondary)
                        .frame(maxWidth: sizeClass == .regular ? 300 : .infinity)
                        .padding(.vertical, 14)
                }
            }
            .padding(.horizontal, 30)
            Spacer()
        }
        .navigationTitle("Bekraeftelse")
    }

    func loadUser() {
        if let savedId = UserDefaults.standard.value(forKey: "loggedInUserId") as? Int, savedId > 0 {
            let savedName = UserDefaults.standard.string(forKey: "loggedInUserName") ?? ""
            let savedEmail = UserDefaults.standard.string(forKey: "loggedInUserEmail") ?? ""
            loggedInUser = UserProfile(id: savedId, name: savedName, email: savedEmail, phone: nil, type: "customer")
        }
    }

    func placeOrder() {
        // Sikkerhed: bloker ordre hvis butikken er lukket (aabningstider eller manuel lukning)
        if !cartOpenState.isOpen && !hoursDays.isEmpty {
            errorMessage = cartClosedMessage
            return
        }
        if isDelivery && deliveryAddress.trimmingCharacters(in: .whitespaces).isEmpty {
            errorMessage = "Indtast en leveringsadresse, eller vaelg afhentning."
            return
        }
        guard let user = loggedInUser, user.id > 0 else {
            showLoginSheet = true
            return
        }
        submitOrder(userId: user.id)
    }

    func loadCartHours() async {
        guard cart.restaurantId > 0,
              let url = URL(string: "\(baseURL)/api/app-company-hours.php?company_id=\(cart.restaurantId)") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct Resp: Codable { let days: [CompanyHourDay]; let shop_status: String? }
            let r = try JSONDecoder().decode(Resp.self, from: data)
            await MainActor.run { hoursDays = r.days; shopStatus = r.shop_status ?? "" }
        } catch { }
    }

    func registerPushToken(userId: Int) {
        // userId er allerede gemt i UserDefaults ("userId") ved login.
        UserDefaults.standard.set("\(userId)", forKey: "userId")
        wrombleEnsurePushRegistered()   // tilladelse + genhent token om noedvendigt
        wrombleSyncPushToken()          // registrerer med det samme hvis token findes
    }

    func submitOrder(userId: Int) {
        isOrdering = true
        errorMessage = ""
        guard let url = URL(string: "\(baseURL)/api/place-order.php") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "user_id": userId,
            "company_id": cart.restaurantId,
            "total": cart.total,
            "note": orderNote,
            "delivery_check": isDelivery ? 1 : 0,
            "payment_method": paymentMethod,
            "delivery_address": deliveryAddress,
            "items": cart.items.map { ["id": $0.id, "quantity": $0.quantity] as [String: Any] }
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, _ in
            DispatchQueue.main.async {
                isOrdering = false
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    errorMessage = "Netvaerksfejl. Proev igen."
                    return
                }
                if let error = json["error"] as? String {
                    errorMessage = error
                    return
                }
                if let oid = json["order_id"] as? Int {
                    orderId = oid
                    showOrderConfirmation = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    scheduleOrderNotification(orderId: oid)
                }
            }
        }.resume()
    }

    func scheduleOrderNotification(orderId: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Ordrestatus"
        content.body = "Din ordre #\(orderId) fra \(cart.restaurantName) er under behandling"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1800, repeats: false)
        let request = UNNotificationRequest(identifier: "order-\(orderId)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Orders View

struct OrdersView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.horizontalSizeClass) var sizeClass
    @State private var orders: [Order] = []
    @State private var isLoading = true
    @State private var showLogin = false
    @State private var loggedInUser: UserProfile?

    var body: some View {
        Group {
            if let user = loggedInUser, user.id > 0 {
                ordersList(user: user)
            } else if showLogin {
                LoginView(onLogin: { user in
                    loggedInUser = user
                    if user.id > 0 { showLogin = false; loadOrders(userId: user.id) }
                })
            } else {
                loginPrompt
            }
        }
        .navigationTitle("Ordrer")
        .onAppear {
            if let savedId = UserDefaults.standard.value(forKey: "loggedInUserId") as? Int, savedId > 0 {
                let n = UserDefaults.standard.string(forKey: "loggedInUserName") ?? ""
                let e = UserDefaults.standard.string(forKey: "loggedInUserEmail") ?? ""
                loggedInUser = UserProfile(id: savedId, name: n, email: e, phone: nil, type: "customer")
                loadOrders(userId: savedId)
            }
        }
    }

    var loginPrompt: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bag.circle.fill")
                .font(.system(size: sizeClass == .regular ? 70 : 50)).foregroundColor(wrombleRed)
            Text("Se dine ordrer").font(sizeClass == .regular ? .title.bold() : .title2.bold())
            Text("Log ind for at se din ordrehistorik").font(.subheadline).foregroundColor(.secondary)
            Button(action: {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showLogin = true
            }) {
                Text("Log ind")
                    .font(.headline).foregroundColor(.white)
                    .frame(maxWidth: sizeClass == .regular ? 300 : .infinity)
                    .padding(.vertical, 14).background(wrombleRed).cornerRadius(12)
            }
            .padding(.horizontal, 40)
            Spacer()
        }
    }

    func ordersList(user: UserProfile) -> some View {
        Group {
            if isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                    Text("Henter ordrer...").font(.subheadline).foregroundColor(.secondary).padding(.top, 8)
                    Spacer()
                }
            } else if orders.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "bag").font(.system(size: 50)).foregroundColor(.secondary)
                    Text("Ingen ordrer endnu").font(.title3.bold())
                    Text("Dine ordrer vises her naar du bestiller").font(.subheadline).foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List(orders) { order in
                    NavigationLink(destination: OrderTrackingView(orderId: order.id, initialCompany: order.companyName)) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(order.companyName).font(.headline)
                                Spacer()
                                orderStatusBadge(order.status)
                            }
                            if !order.date.isEmpty {
                                Text(order.date).font(.caption).foregroundColor(.secondary)
                            }
                            ForEach(order.items, id: \.name) { item in
                                HStack {
                                    Text("\(item.quantity)x \(item.name)").font(.subheadline).foregroundColor(.secondary)
                                    Spacer()
                                    Text(String(format: "%.2f kr", item.price * Double(item.quantity)))
                                        .font(.subheadline).foregroundColor(.secondary)
                                }
                            }
                            HStack {
                                Spacer()
                                Text(String(format: "Total: %.2f kr", order.total))
                                    .font(.subheadline.weight(.bold)).foregroundColor(wrombleRed)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .refreshable { loadOrders(userId: user.id) }
            }
        }
    }

    func orderStatusBadge(_ status: String) -> some View {
        let (label, color): (String, Color) = {
            switch status.lowercased() {
            case "completed", "delivered": return ("Leveret", .green)
            case "processing", "preparing": return ("Tilberedes", .orange)
            case "cancelled": return ("Annulleret", .red)
            default: return ("Afventer", .blue)
            }
        }()
        return Text(label)
            .font(.caption.weight(.bold)).foregroundColor(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color).cornerRadius(6)
    }

    func loadOrders(userId: Int) {
        isLoading = true
        UserDefaults.standard.set(userId, forKey: "loggedInUserId")
        guard let url = URL(string: "\(baseURL)/api/orders.php?user_id=\(userId)") else { return }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            DispatchQueue.main.async {
                isLoading = false
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let arr = json["orders"] as? [[String: Any]] else { return }
                orders = arr.map { o in
                    let items = (o["items"] as? [[String: Any]] ?? []).map { i in
                        OrderItem(name: i["name"] as? String ?? "Ukendt",
                                  quantity: i["quantity"] as? Int ?? 1,
                                  price: i["price"] as? Double ?? 0)
                    }
                    return Order(id: o["id"] as? Int ?? 0,
                                 companyName: o["company_name"] as? String ?? "Ukendt",
                                 date: o["date"] as? String ?? "",
                                 total: o["total"] as? Double ?? 0,
                                 status: o["status"] as? String ?? "pending",
                                 items: items)
                }
            }
        }.resume()
    }
}

// MARK: - Order Tracking (live status-ring som Wolt)

struct TrackPin: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let isCustomer: Bool
}

struct OrderTrackingView: View {
    let orderId: Int
    var initialCompany: String = ""
    @Environment(\.dismiss) var dismiss
    @State private var status: OrderStatus?
    @State private var isLoading = true
    @State private var pollTimer: Timer?
    @State private var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 55.676, longitude: 12.568),
        span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04))
    @State private var didCenterMap = false

    let steps = ["Modtaget", "Bekræftet", "På vej", "Leveret"]

    var mapPins: [TrackPin] {
        var pins: [TrackPin] = []
        if let s = status {
            if s.companyLat != 0 || s.companyLng != 0 {
                pins.append(TrackPin(coordinate: CLLocationCoordinate2D(latitude: s.companyLat, longitude: s.companyLng), isCustomer: false))
            }
            if s.isDelivery && (s.customerLat != 0 || s.customerLng != 0) {
                pins.append(TrackPin(coordinate: CLLocationCoordinate2D(latitude: s.customerLat, longitude: s.customerLng), isCustomer: true))
            }
        }
        return pins
    }

    var stage: Int { status?.stage ?? 0 }
    var isRejected: Bool { stage < 0 }
    var progress: Double {
        if isRejected { return 0 }
        return Double(max(0, stage)) / Double(steps.count - 1)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                // Status-ring
                ZStack {
                    Circle().stroke(Color(.systemGray5), lineWidth: 18)
                    Circle()
                        .trim(from: 0, to: isRejected ? 1 : max(0.02, progress))
                        .stroke(isRejected ? Color.red : wrombleRed,
                                style: StrokeStyle(lineWidth: 18, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.6), value: progress)
                    VStack(spacing: 8) {
                        Image(systemName: ringIcon)
                            .font(.system(size: 42))
                            .foregroundColor(isRejected ? .red : wrombleRed)
                        Text(status?.label ?? "Henter…")
                            .font(.title3.bold())
                            .multilineTextAlignment(.center)
                    }
                    .padding(34)
                }
                .frame(width: 230, height: 230)
                .padding(.top, 24)

                Text(status?.description ?? "Vi henter status på din ordre")
                    .font(.body).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)

                // Trin-indikator
                if !isRejected {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(0..<steps.count, id: \.self) { i in
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle()
                                        .fill(i <= stage ? wrombleRed : Color(.systemGray5))
                                        .frame(width: 30, height: 30)
                                    if i < stage {
                                        Image(systemName: "checkmark").font(.caption.bold()).foregroundColor(.white)
                                    } else if i == stage {
                                        Circle().fill(.white).frame(width: 10, height: 10)
                                    }
                                }
                                Text(steps[i]).font(.caption2)
                                    .foregroundColor(i <= stage ? .primary : .secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                // Ordredetaljer
                VStack(spacing: 0) {
                    detailRow(icon: "number", title: "Ordrenummer", value: "#\(orderId)")
                    Divider().padding(.leading, 50)
                    detailRow(icon: "building.2.fill", title: "Sted", value: status?.companyName ?? initialCompany)
                    if let t = status?.total, t > 0 {
                        Divider().padding(.leading, 50)
                        detailRow(icon: "creditcard", title: "Total", value: String(format: "%.2f kr", t))
                    }
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(14)
                .padding(.horizontal, 20)

                // Kort: vis hvor ordren er (restauranten - og leveringsadressen ved levering).
                if !mapPins.isEmpty && !isRejected {
                    VStack(spacing: 10) {
                        Map(coordinateRegion: $mapRegion, annotationItems: mapPins) { pin in
                            MapAnnotation(coordinate: pin.coordinate) {
                                VStack(spacing: 2) {
                                    Image(systemName: pin.isCustomer ? "house.fill" : "fork.knife.circle.fill")
                                        .font(.system(size: 26))
                                        .foregroundColor(pin.isCustomer ? .blue : wrombleRed)
                                        .background(Circle().fill(.white).frame(width: 22, height: 22))
                                    Text(pin.isCustomer ? "Dig" : (status?.companyName ?? "Restaurant"))
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color(.systemBackground).opacity(0.9)).cornerRadius(4)
                                }
                            }
                        }
                        .frame(height: 220)
                        .cornerRadius(14)
                        .allowsHitTesting(false)

                        Button(action: { openInMaps() }) {
                            HStack {
                                Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                                Text(status?.isDelivery == true ? "Åbn restauranten i Kort" : "Rutevejledning til restauranten")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundColor(wrombleRed)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(wrombleRed.opacity(0.10)).cornerRadius(12)
                        }
                    }
                    .padding(.horizontal, 20)
                }

                if isLoading { ProgressView().padding(.top, 4) }
                Spacer(minLength: 24)
            }
        }
        .navigationTitle("Følg din ordre")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await fetchStatus() }
        .onAppear { startPolling() }
        .onDisappear { pollTimer?.invalidate() }
    }

    var ringIcon: String {
        if isRejected { return "xmark.circle.fill" }
        switch stage {
        case 3: return "checkmark.seal.fill"
        case 2: return "bicycle"
        case 1: return "fork.knife"
        default: return "clock.badge.checkmark"
        }
    }

    func detailRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundColor(wrombleRed).frame(width: 26)
            Text(title).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    // Centrerer kortet paa restauranten (og zoomer ud saa leveringsadressen ogsaa er med)
    // foerste gang vi faar koordinater.
    func centerMapIfNeeded(_ s: OrderStatus) {
        guard !didCenterMap, s.companyLat != 0 || s.companyLng != 0 else { return }
        didCenterMap = true
        if s.isDelivery && (s.customerLat != 0 || s.customerLng != 0) {
            let midLat = (s.companyLat + s.customerLat) / 2
            let midLng = (s.companyLng + s.customerLng) / 2
            let dLat = abs(s.companyLat - s.customerLat) * 1.6 + 0.01
            let dLng = abs(s.companyLng - s.customerLng) * 1.6 + 0.01
            mapRegion = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: midLat, longitude: midLng),
                span: MKCoordinateSpan(latitudeDelta: dLat, longitudeDelta: dLng))
        } else {
            mapRegion = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: s.companyLat, longitude: s.companyLng),
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
        }
    }

    // Aabner restaurantens position i Apple Kort med rutevejledning.
    func openInMaps() {
        guard let s = status, s.companyLat != 0 || s.companyLng != 0 else { return }
        let name = (s.companyName).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Restaurant"
        let coord = "\(s.companyLat),\(s.companyLng)"
        if let url = URL(string: "http://maps.apple.com/?daddr=\(coord)&q=\(name)&dirflg=d") {
            UIApplication.shared.open(url)
        }
    }

    func startPolling() {
        Task { await fetchStatus() }
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { _ in
            Task { await fetchStatus() }
        }
    }

    func fetchStatus() async {
        guard let url = URL(string: "\(baseURL)/api/order-status.php?order_id=\(orderId)") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                await MainActor.run { isLoading = false }; return
            }
            let s = OrderStatus(
                stage: json["stage"] as? Int ?? 0,
                label: json["label"] as? String ?? "",
                description: json["description"] as? String ?? "",
                companyName: json["company_name"] as? String ?? initialCompany,
                total: (json["total"] as? NSNumber)?.doubleValue ?? 0,
                isDelivery: (json["is_delivery"] as? Bool) ?? false,
                companyLat: (json["company_lat"] as? NSNumber)?.doubleValue ?? 0,
                companyLng: (json["company_lng"] as? NSNumber)?.doubleValue ?? 0,
                companyAddress: json["company_address"] as? String ?? "",
                customerLat: (json["customer_lat"] as? NSNumber)?.doubleValue ?? 0,
                customerLng: (json["customer_lng"] as? NSNumber)?.doubleValue ?? 0)
            await MainActor.run {
                status = s
                isLoading = false
                centerMapIfNeeded(s)
            }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }
}

// MARK: - Chat View

class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var conversationId: Int = 0
    @Published var status: String = "open"
    @Published var isStarted = false
    @Published var isLoading = false
    @Published var isUploading = false
    private var pollTimer: Timer?
    private var lastMessageId = 0
    private var seenIds = Set<Int>()

    func startConversation(name: String, email: String) {
        isLoading = true
        guard let url = URL(string: "\(baseURL)/api/chat-start.php") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name, "email": email])

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let convId = json["conversation_id"] as? Int else {
                DispatchQueue.main.async { self?.isLoading = false }
                return
            }
            DispatchQueue.main.async {
                self?.conversationId = convId
                self?.isStarted = true
                self?.isLoading = false
                self?.startPolling()
            }
        }.resume()
    }

    func sendMessage(_ text: String, senderName: String) {
        guard conversationId > 0, !text.isEmpty else { return }
        guard let url = URL(string: "\(baseURL)/api/chat-send.php") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "conversation_id": conversationId, "sender_type": "customer",
            "sender_name": senderName, "message": text
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request) { [weak self] _, _, _ in
            DispatchQueue.main.async { self?.poll() }
        }.resume()
    }

    // Upload a photo or file to the same backend as the website (chat-upload.php)
    func uploadData(_ fileData: Data, filename: String, mimeType: String, senderName: String) {
        guard conversationId > 0 else { return }
        guard let url = URL(string: "\(baseURL)/api/chat-upload.php") else { return }
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("conversation_id", String(conversationId))
        field("sender_type", "customer")
        field("sender_name", senderName)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        isUploading = true
        URLSession.shared.dataTask(with: request) { [weak self] _, _, _ in
            DispatchQueue.main.async {
                self?.isUploading = false
                self?.poll()
            }
        }.resume()
    }

    func resetConversation() {
        stopPolling()
        messages = []
        conversationId = 0
        isStarted = false
        status = "open"
        lastMessageId = 0
        seenIds.removeAll()
    }

    func startPolling() {
        pollTimer?.invalidate()
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stopPolling() { pollTimer?.invalidate(); pollTimer = nil }

    private func poll() {
        guard conversationId > 0 else { return }
        guard let url = URL(string: "\(baseURL)/api/chat-poll.php?conversation_id=\(conversationId)&after=\(lastMessageId)") else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let msgsArray = json["messages"] as? [[String: Any]] else { return }

            let newStatus = json["status"] as? String ?? "open"
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.status = newStatus
                for msg in msgsArray {
                    let mid = msg["id"] as? Int ?? 0
                    if mid > 0 && self.seenIds.contains(mid) { continue }
                    if mid > 0 { self.seenIds.insert(mid) }
                    self.messages.append(ChatMessage(
                        id: mid,
                        senderType: msg["sender_type"] as? String ?? "",
                        senderName: msg["sender_name"] as? String ?? "",
                        message: msg["message"] as? String ?? "",
                        fileURL: msg["file_url"] as? String,
                        fileType: msg["file_type"] as? String,
                        fileName: msg["file_name"] as? String,
                        createdAt: msg["created_at"] as? String ?? ""))
                    if mid > self.lastMessageId { self.lastMessageId = mid }
                }
            }
        }.resume()
    }
}

struct ChatView: View {
    @Environment(\.horizontalSizeClass) var sizeClass
    @StateObject private var viewModel = ChatViewModel()
    @State private var nameInput = ""
    @State private var emailInput = ""
    @State private var messageInput = ""
    @State private var showAttachDialog = false
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var showCall = false

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.isStarted { chatStartForm }
            else {
                chatMessages
                if viewModel.status == "open" { chatInputBar }
                else { closedBanner }
            }
        }
        .navigationTitle("Kundeservice")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if viewModel.isStarted && viewModel.status == "open" {
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        showCall = true
                    }) {
                        Image(systemName: "video.fill").foregroundColor(wrombleRed)
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showCall) {
            let n = (nameInput.isEmpty ? "Kunde" : nameInput)
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Kunde"
            CallWebView(
                url: URL(string: "\(baseURL)/app-call.php?cid=\(viewModel.conversationId)&name=\(n)&video=1")!,
                onClose: { showCall = false }
            )
            .ignoresSafeArea()
        }
        .onDisappear { viewModel.stopPolling() }
    }

    var chatStartForm: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "message.badge.fill")
                .font(.system(size: sizeClass == .regular ? 70 : 50)).foregroundColor(wrombleRed)
            Text("Kontakt Kundeservice").font(sizeClass == .regular ? .title.bold() : .title2.bold())
            Text("Vi svarer hurtigst muligt").font(.subheadline).foregroundColor(.secondary)

            VStack(spacing: 12) {
                TextField("Dit navn", text: $nameInput).textFieldStyle(.roundedBorder).font(.body)
                TextField("E-mail (valgfrit)", text: $emailInput)
                    .textFieldStyle(.roundedBorder).font(.body)
                    .keyboardType(.emailAddress).textContentType(.emailAddress).autocapitalization(.none)
            }
            .frame(maxWidth: sizeClass == .regular ? 400 : .infinity)
            .padding(.horizontal, sizeClass == .regular ? 60 : 30)

            Button(action: {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                viewModel.startConversation(name: nameInput, email: emailInput)
            }) {
                if viewModel.isLoading { ProgressView().tint(.white) }
                else { Text("Start chat").font(.headline) }
            }
            .foregroundColor(.white)
            .frame(maxWidth: sizeClass == .regular ? 400 : .infinity)
            .padding(.vertical, 14)
            .background(nameInput.isEmpty ? Color.gray : wrombleRed).cornerRadius(12)
            .padding(.horizontal, sizeClass == .regular ? 60 : 30)
            .disabled(nameInput.isEmpty || viewModel.isLoading)
            Spacer()
        }
    }

    var chatMessages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.messages) { msg in
                        chatBubble(msg).id(msg.id)
                    }
                }
                .padding(sizeClass == .regular ? 20 : 14)
            }
            .onChange(of: viewModel.messages.count) { _ in
                if let last = viewModel.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    func chatBubble(_ msg: ChatMessage) -> some View {
        let isCustomer = msg.senderType == "customer"
        let hasFile = (msg.fileURL != nil && !(msg.fileURL ?? "").isEmpty)
        let isPlaceholder = msg.message == "[Billede]" || msg.message.hasPrefix("[Fil:")
        let showText = !msg.message.isEmpty && !(hasFile && isPlaceholder)
        return HStack {
            if isCustomer { Spacer(minLength: 60) }
            VStack(alignment: isCustomer ? .trailing : .leading, spacing: 4) {
                if !isCustomer {
                    Text(msg.senderName).font(.caption2.weight(.semibold)).foregroundColor(.secondary)
                }
                if showText {
                    Text(msg.message).font(.body)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(isCustomer ? wrombleRed : Color(.secondarySystemBackground))
                        .foregroundColor(isCustomer ? .white : .primary)
                        .cornerRadius(16)
                }
                if let fileURL = msg.fileURL, !fileURL.isEmpty {
                    if msg.fileType == "image" {
                        AsyncImage(url: URL(string: "\(baseURL)\(fileURL)")) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFit()
                                    .frame(maxWidth: 200, maxHeight: 200).cornerRadius(10)
                            case .failure:
                                Image(systemName: "photo").foregroundColor(.secondary)
                            default: ProgressView()
                            }
                        }
                    } else {
                        Button(action: {
                            if let u = URL(string: "\(baseURL)\(fileURL)") { UIApplication.shared.open(u) }
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.fill")
                                Text(msg.fileName ?? "Fil").lineLimit(1)
                            }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(isCustomer ? wrombleRed : Color(.secondarySystemBackground))
                            .foregroundColor(isCustomer ? .white : .primary)
                            .cornerRadius(16)
                        }
                    }
                }
            }
            if !isCustomer { Spacer(minLength: 60) }
        }
    }

    var chatInputBar: some View {
        HStack(spacing: 6) {
            // Synligt kamera-ikon: aabner kameraet direkte
            Button(action: {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showCamera = true
            }) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 22))
                    .foregroundColor(viewModel.isUploading ? .gray : wrombleRed)
            }
            .disabled(viewModel.isUploading)
            Button(action: { showAttachDialog = true }) {
                Image(systemName: "paperclip")
                    .font(.system(size: 22))
                    .foregroundColor(viewModel.isUploading ? .gray : wrombleRed)
            }
            .disabled(viewModel.isUploading)
            TextField("Skriv en besked...", text: $messageInput)
                .textFieldStyle(.roundedBorder).font(.body)
                .onSubmit { send() }
            if viewModel.isUploading {
                ProgressView().frame(width: 32, height: 32)
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(messageInput.isEmpty ? .gray : wrombleRed)
                }
                .disabled(messageInput.isEmpty)
            }
        }
        .padding(.horizontal, sizeClass == .regular ? 20 : 14)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
        .overlay(Divider(), alignment: .top)
        .confirmationDialog("Vedhæft", isPresented: $showAttachDialog, titleVisibility: .visible) {
            Button("Tag billede") { showCamera = true }
            Button("Vælg billede") { showPhotoPicker = true }
            Button("Vælg fil") { showFileImporter = true }
            Button("Annuller", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let jpeg = image.jpegData(compressionQuality: 0.7) {
                    viewModel.uploadData(jpeg, filename: "billede.jpg", mimeType: "image/jpeg", senderName: nameInput)
                }
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
        .onChange(of: selectedPhoto) { newItem in
            guard let newItem = newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let ui = UIImage(data: data),
                   let jpeg = ui.jpegData(compressionQuality: 0.7) {
                    await MainActor.run {
                        viewModel.uploadData(jpeg, filename: "billede.jpg", mimeType: "image/jpeg", senderName: nameInput)
                    }
                }
                await MainActor.run { selectedPhoto = nil }
            }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: allowedUploadTypes,
                      allowsMultipleSelection: false) { result in
            handleFileImport(result)
        }
    }

    var allowedUploadTypes: [UTType] {
        var types: [UTType] = [.pdf, .image, .plainText]
        for ext in ["doc", "docx", "xls", "xlsx"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }

    func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        if data.count > 10 * 1024 * 1024 { return }
        viewModel.uploadData(data, filename: url.lastPathComponent,
                             mimeType: "application/octet-stream", senderName: nameInput)
    }

    var closedBanner: some View {
        VStack(spacing: 10) {
            Text("Denne samtale er lukket").font(.subheadline).foregroundColor(.secondary)
            Button(action: {
                viewModel.resetConversation()
            }) {
                Text("Start ny samtale")
                    .font(.subheadline.weight(.bold)).foregroundColor(.white)
                    .padding(.horizontal, 24).padding(.vertical, 10)
                    .background(wrombleRed).cornerRadius(10)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .overlay(Divider(), alignment: .top)
    }

    func send() {
        let text = messageInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        messageInput = ""
        viewModel.sendMessage(text, senderName: nameInput)
    }
}

// MARK: - Camera Picker (til billeder i chat)

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Video Call (WKWebView)
// Aabner den samme WebRTC-video/lyd-loesning som paa hjemmesiden (app-call.php),
// saa opkald i appen fungerer praecis som paa wromble.dk - med eller uden kamera.
struct CallWebView: UIViewRepresentable {
    let url: URL
    var onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onClose: onClose) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(context.coordinator, name: "callEnded")

        let web = WKWebView(frame: .zero, configuration: config)
        web.uiDelegate = context.coordinator
        web.scrollView.isScrollEnabled = false
        web.isOpaque = false
        web.backgroundColor = .black
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKUIDelegate, WKScriptMessageHandler {
        let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }

        // Giv WebRTC adgang til kamera + mikrofon uden ekstra prompt inde i webview'en
        func webView(_ webView: WKWebView,
                     requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo,
                     type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.grant)
        }

        // Websiden beder om at lukke opkaldsskaermen
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if message.name == "callEnded" {
                DispatchQueue.main.async { self.onClose() }
            }
        }
    }
}

// MARK: - Profile View

struct ProfileView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var locationManager: LocationManager
    @Environment(\.horizontalSizeClass) var sizeClass
    @State private var showBiometricAlert = false
    @State private var showShareSheet = false
    @State private var showLogin = false
    @State private var showDeleteAccount = false
    @State private var showSupportChat = false
    @State private var showContactForm = false
    @State private var showPartner = false
    @State private var showJobs = false
    @State private var showProfileEdit = false
    @State private var loggedInUser: UserProfile?

    var body: some View {
        List {
            Section {
                if let user = loggedInUser, user.id > 0 {
                    HStack(spacing: sizeClass == .regular ? 20 : 16) {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: sizeClass == .regular ? 64 : 50)).foregroundColor(wrombleRed)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(user.name).font(sizeClass == .regular ? .title2.bold() : .title3.bold())
                            Text(user.email).font(sizeClass == .regular ? .body : .subheadline).foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, sizeClass == .regular ? 12 : 8)
                } else {
                    Button(action: { showLogin = true }) {
                        HStack(spacing: sizeClass == .regular ? 20 : 16) {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: sizeClass == .regular ? 64 : 50)).foregroundColor(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Log ind").font(sizeClass == .regular ? .title2.bold() : .title3.bold())
                                Text("Log ind eller opret en konto")
                                    .font(sizeClass == .regular ? .body : .subheadline).foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, sizeClass == .regular ? 12 : 8)
                }
            }

            if let user = loggedInUser, user.id > 0 {
                Section(header: Text("Min konto")) {
                    Button(action: {
                        showProfileEdit = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }) {
                        Label("Mine oplysninger", systemImage: "person.crop.circle.fill").foregroundColor(.primary)
                    }
                }
            }

            Section(header: Text("Notifikationer")) {
                Toggle(isOn: $appState.notificationsEnabled) {
                    Label("Push-notifikationer", systemImage: "bell.badge.fill")
                }
                .tint(wrombleRed)
                .onChange(of: appState.notificationsEnabled) { newValue in
                    if newValue {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                            DispatchQueue.main.async {
                                if granted { UIApplication.shared.registerForRemoteNotifications() }
                                else { appState.notificationsEnabled = false }
                                appState.save()
                            }
                        }
                    } else { appState.save() }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }

            Section(header: Text("Placering")) {
                Toggle(isOn: $appState.locationEnabled) {
                    Label("Brug placering", systemImage: "location.fill")
                }
                .tint(wrombleRed)
                .onChange(of: appState.locationEnabled) { newValue in
                    if newValue {
                        let s = locationManager.authorizationStatus
                        if s == .denied || s == .restricted {
                            // Tilladelsen er slaaet fra i systemet - den kan kun gives i
                            // iOS-indstillinger, saa vi sender brugeren derhen.
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } else {
                            locationManager.requestLocation()
                        }
                    }
                    appState.save()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }

                if let loc = locationManager.location {
                    HStack {
                        Text("Aktuel position").foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "%.2f, %.2f", loc.coordinate.latitude, loc.coordinate.longitude))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }

            Section(header: Text("Sikkerhed")) {
                Toggle(isOn: $appState.biometricEnabled) {
                    Label(biometricLabel, systemImage: biometricIcon)
                }
                .tint(wrombleRed)
                .onChange(of: appState.biometricEnabled) { newValue in
                    if newValue { authenticateBiometric() }
                    appState.save()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }

            Section(header: Text("Wromble")) {
                Button(action: {
                    showSupportChat = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }) {
                    Label("Kundeservice-chat", systemImage: "bubble.left.and.bubble.right.fill").foregroundColor(.primary)
                }

                Button(action: {
                    showContactForm = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }) {
                    Label("Kontakt os", systemImage: "envelope.fill").foregroundColor(.primary)
                }

                Button(action: {
                    showPartner = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }) {
                    Label("Bliv partner", systemImage: "building.2.fill").foregroundColor(.primary)
                }

                Button(action: {
                    showJobs = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }) {
                    Label("Job hos Wromble", systemImage: "briefcase.fill").foregroundColor(.primary)
                }
            }

            Section(header: Text("Del & Support")) {
                Button(action: {
                    showShareSheet = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }) {
                    Label("Del Wromble med venner", systemImage: "square.and.arrow.up").foregroundColor(.primary)
                }

                Link(destination: URL(string: "\(baseURL)/privacy-policy/app.php")!) {
                    Label("Privatlivspolitik", systemImage: "hand.raised.fill").foregroundColor(.primary)
                }

                Link(destination: URL(string: "\(baseURL)/terms/app.php") ?? URL(string: baseURL)!) {
                    Label("Vilkaar og betingelser", systemImage: "doc.text.fill").foregroundColor(.primary)
                }
            }

            Section(header: Text("Om")) {
                HStack {
                    Label("Version", systemImage: "info.circle")
                    Spacer()
                    Text("1.1.1 (29)").foregroundColor(.secondary)
                }
                HStack {
                    Label("Netvaerk", systemImage: appState.networkAvailable ? "wifi" : "wifi.slash")
                    Spacer()
                    Text(appState.networkAvailable ? "Forbundet" : "Ikke forbundet")
                        .foregroundColor(appState.networkAvailable ? .green : .red).font(.subheadline)
                }
                if !appState.deviceToken.isEmpty {
                    HStack {
                        Label("Push token", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        Text(String(appState.deviceToken.prefix(16)) + "...")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }

            if let user = loggedInUser, user.id > 0 {
                Section(header: Text("Konto")) {
                    Button(action: {
                        loggedInUser = nil
                        UserDefaults.standard.removeObject(forKey: "loggedInUserId")
                        UserDefaults.standard.removeObject(forKey: "loggedInUserName")
                        UserDefaults.standard.removeObject(forKey: "loggedInUserEmail")
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }) {
                        HStack {
                            Spacer()
                            Text("Log ud").foregroundColor(.orange).font(.body.weight(.semibold))
                            Spacer()
                        }
                    }

                    Button(action: { showDeleteAccount = true }) {
                        HStack {
                            Spacer()
                            Text("Slet konto").foregroundColor(.red).font(.body.weight(.semibold))
                            Spacer()
                        }
                    }
                }
            }
        }
        .navigationTitle("Profil")
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [
                "Proev Wromble - bestil mad og specialvarer fra lokale butikker! Download her: https://apps.apple.com/dk/app/wromble/id6778496033"
            ])
        }
        .sheet(isPresented: $showSupportChat) {
            NavigationStack {
                ChatView()
                    .navigationTitle("Kundeservice").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { showSupportChat = false } } }
            }
        }
        .sheet(isPresented: $showContactForm) { ContactFormView() }
        .sheet(isPresented: $showPartner) { PartnerFormView() }
        .sheet(isPresented: $showJobs) { JobsView() }
        .sheet(isPresented: $showProfileEdit) {
            if let user = loggedInUser, user.id > 0 { CustomerProfileView(userId: user.id) }
        }
        .sheet(isPresented: $showLogin) {
            NavigationStack {
                LoginView(onLogin: { user in
                    loggedInUser = user
                    if user.id > 0 {
                        UserDefaults.standard.set(user.id, forKey: "loggedInUserId")
                        UserDefaults.standard.set(user.name, forKey: "loggedInUserName")
                        UserDefaults.standard.set(user.email, forKey: "loggedInUserEmail")
                    }
                    showLogin = false
                })
                .navigationTitle("Konto").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { showLogin = false } } }
            }
        }
        .sheet(isPresented: $showDeleteAccount) {
            if let user = loggedInUser {
                AccountDeletionView(user: user, onDeleted: {
                    loggedInUser = nil
                    UserDefaults.standard.removeObject(forKey: "loggedInUserId")
                    UserDefaults.standard.removeObject(forKey: "loggedInUserName")
                    UserDefaults.standard.removeObject(forKey: "loggedInUserEmail")
                    FavoritesManager.shared.favoriteIds.removeAll()
                    UserDefaults.standard.removeObject(forKey: "favoriteRestaurants")
                    showDeleteAccount = false
                })
            }
        }
        .alert("Biometrisk login", isPresented: $showBiometricAlert) {
            Button("OK") { appState.biometricEnabled = false; appState.save() }
        } message: {
            Text("Biometrisk login er ikke tilgaengelig paa denne enhed.")
        }
        .onAppear {
            if let savedId = UserDefaults.standard.value(forKey: "loggedInUserId") as? Int, savedId > 0 {
                let n = UserDefaults.standard.string(forKey: "loggedInUserName") ?? ""
                let e = UserDefaults.standard.string(forKey: "loggedInUserEmail") ?? ""
                loggedInUser = UserProfile(id: savedId, name: n, email: e, phone: nil, type: "customer")
            }
        }
    }

    var biometricLabel: String {
        let ctx = LAContext()
        if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
            return ctx.biometryType == .faceID ? "Face ID" : "Touch ID"
        }
        return "Biometrisk login"
    }

    var biometricIcon: String {
        let ctx = LAContext()
        if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
            return ctx.biometryType == .faceID ? "faceid" : "touchid"
        }
        return "lock.shield.fill"
    }

    func authenticateBiometric() {
        let ctx = LAContext()
        var error: NSError?
        if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Log ind med biometri") { success, _ in
                DispatchQueue.main.async {
                    if !success { appState.biometricEnabled = false; appState.save() }
                }
            }
        } else {
            showBiometricAlert = true
        }
    }
}

// MARK: - Account Deletion

struct AccountDeletionView: View {
    let user: UserProfile
    var onDeleted: () -> Void
    @Environment(\.dismiss) var dismiss
    @Environment(\.horizontalSizeClass) var sizeClass
    @State private var password = ""
    @State private var isDeleting = false
    @State private var errorMessage = ""
    @State private var showFinalConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 40)

                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 60)).foregroundColor(.red)

                    Text("Slet din konto")
                        .font(.title.bold())

                    Text("Dette vil permanent slette din konto og alle tilknyttede data, herunder ordrehistorik og samtaler. Denne handling kan ikke fortrydes.")
                        .font(.body).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("E-mail:").foregroundColor(.secondary)
                            Text(user.email).font(.body.bold())
                        }
                        .padding(.horizontal, 30)

                        SecureField("Indtast adgangskode for at bekraefte", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .padding(.horizontal, 30)
                    }

                    if !errorMessage.isEmpty {
                        Text(errorMessage).foregroundColor(.red).font(.subheadline)
                            .padding(.horizontal, 30)
                    }

                    Button(action: { showFinalConfirmation = true }) {
                        HStack {
                            Image(systemName: "trash.fill")
                            if isDeleting { ProgressView().tint(.white) }
                            else { Text("Slet konto permanent").font(.headline) }
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: sizeClass == .regular ? 400 : .infinity)
                        .padding(.vertical, 16)
                        .background(password.isEmpty ? Color.gray : Color.red)
                        .cornerRadius(14)
                    }
                    .padding(.horizontal, 30)
                    .disabled(password.isEmpty || isDeleting)

                    Button("Annuller") { dismiss() }
                        .foregroundColor(.secondary)

                    Spacer(minLength: 40)
                }
            }
            .navigationTitle("Slet konto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } }
            }
            .alert("Er du helt sikker?", isPresented: $showFinalConfirmation) {
                Button("Ja, slet min konto", role: .destructive) { deleteAccount() }
                Button("Annuller", role: .cancel) {}
            } message: {
                Text("Din konto og alle data vil blive slettet permanent. Dette kan ikke fortrydes.")
            }
        }
    }

    func deleteAccount() {
        isDeleting = true
        errorMessage = ""
        guard let url = URL(string: "\(baseURL)/api/delete-account.php") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["user_id": user.id, "email": user.email, "password": password]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, _ in
            DispatchQueue.main.async {
                isDeleting = false
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    errorMessage = "Netvaerksfejl. Proev igen."
                    return
                }
                if let error = json["error"] as? String { errorMessage = error; return }
                if json["success"] as? Bool == true {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onDeleted()
                }
            }
        }.resume()
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

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

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
            DispatchQueue.main.async { self?.isConnected = path.status == .satisfied }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
