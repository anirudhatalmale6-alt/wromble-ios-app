import SwiftUI
import WebKit
import CoreLocation
import LocalAuthentication
import Network

let wrombleRed = Color(red: 226/255, green: 15/255, blue: 30/255)
let baseURL = "https://wromble.dk"

// MARK: - User Model

struct UserProfile: Codable {
    let id: Int
    let name: String
    let email: String
    let phone: String?
    let type: String
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
                withAnimation(.easeOut(duration: 0.5)) {
                    showSplash = false
                }
            }
            networkMonitor.start()
            if !appState.biometricEnabled {
                appState.isAuthenticated = true
            }
        }
        .onChange(of: networkMonitor.isConnected) { newValue in
            appState.networkAvailable = newValue
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
                    .tabItem {
                        Image(systemName: "house.fill")
                        Text("Hjem")
                    }
                    .tag(0)

                    NavigationStack {
                        ExploreView(locationManager: locationManager)
                    }
                    .tabItem {
                        Image(systemName: "magnifyingglass")
                        Text("Udforsk")
                    }
                    .tag(1)

                    NavigationStack {
                        OrdersView()
                    }
                    .tabItem {
                        Image(systemName: "bag.fill")
                        Text("Ordrer")
                    }
                    .tag(2)

                    NavigationStack {
                        ChatView()
                    }
                    .tabItem {
                        Image(systemName: "message.fill")
                        Text("Chat")
                    }
                    .tag(3)

                    NavigationStack {
                        ProfileView(locationManager: locationManager)
                    }
                    .tabItem {
                        Image(systemName: "person.fill")
                        Text("Profil")
                    }
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
                        .foregroundColor(wrombleRed)
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
                DispatchQueue.main.async {
                    if success { appState.isAuthenticated = true }
                }
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
    }
}

// MARK: - Login View (Native)

struct LoginView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.horizontalSizeClass) var sizeClass
    @State private var isLogin = true
    @State private var email = ""
    @State private var password = ""
    @State private var firstname = ""
    @State private var lastname = ""
    @State private var phone = ""
    @State private var errorMessage = ""
    @State private var isLoading = false
    var onLogin: (UserProfile) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: sizeClass == .regular ? 28 : 20) {
                Spacer(minLength: sizeClass == .regular ? 40 : 20)

                Image("SplashLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: sizeClass == .regular ? 100 : 70, height: sizeClass == .regular ? 100 : 70)

                Text(isLogin ? "Log ind" : "Opret konto")
                    .font(sizeClass == .regular ? .largeTitle.bold() : .title.bold())

                Text(isLogin ? "Log ind med din Wromble konto" : "Opret en gratis Wromble konto")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                // Segment picker
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
                        Image(systemName: "lock.fill")
                            .foregroundColor(.secondary)
                            .frame(width: 20)
                        SecureField("Adgangskode", text: $password)
                            .textContentType(isLogin ? .password : .newPassword)
                    }
                    .padding(14)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                }
                .frame(maxWidth: sizeClass == .regular ? 400 : .infinity)

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }

                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if isLogin { doLogin() } else { doRegister() }
                }) {
                    Group {
                        if isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Text(isLogin ? "Log ind" : "Opret konto")
                                .font(.headline)
                        }
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: sizeClass == .regular ? 400 : .infinity)
                    .padding(.vertical, 16)
                    .background((email.isEmpty || password.isEmpty) ? Color.gray : wrombleRed)
                    .cornerRadius(14)
                }
                .disabled(email.isEmpty || password.isEmpty || isLoading)

                Button(action: {
                    onLogin(UserProfile(id: 0, name: "Gaest", email: "", phone: nil, type: "guest"))
                }) {
                    Text("Fortsaet uden login")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)

                Spacer(minLength: 40)
            }
            .padding(.horizontal, sizeClass == .regular ? 60 : 24)
        }
    }

    func inputField(_ placeholder: String, text: Binding<String>, icon: String, keyboard: UIKeyboardType = .default, autocap: Bool = true) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 20)
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
        isLoading = true
        errorMessage = ""
        guard let url = URL(string: "\(baseURL)/api/login.php") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["email": email, "password": password, "mode": "customer"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, _ in
            DispatchQueue.main.async {
                isLoading = false
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    errorMessage = "Netvaerksfejl. Proev igen."
                    return
                }
                if let error = json["error"] as? String {
                    errorMessage = error
                    return
                }
                if let userDict = json["user"] as? [String: Any] {
                    let user = UserProfile(
                        id: userDict["id"] as? Int ?? 0,
                        name: userDict["name"] as? String ?? "",
                        email: userDict["email"] as? String ?? "",
                        phone: userDict["phone"] as? String,
                        type: userDict["type"] as? String ?? "customer"
                    )
                    onLogin(user)
                }
            }
        }.resume()
    }

    func doRegister() {
        isLoading = true
        errorMessage = ""
        guard !firstname.isEmpty else {
            errorMessage = "Fornavn er paakraevet"
            isLoading = false
            return
        }
        guard let url = URL(string: "\(baseURL)/api/register.php") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "firstname": firstname,
            "lastname": lastname,
            "email": email,
            "phone": phone,
            "password": password
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, _ in
            DispatchQueue.main.async {
                isLoading = false
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    errorMessage = "Netvaerksfejl. Proev igen."
                    return
                }
                if let error = json["error"] as? String {
                    errorMessage = error
                    return
                }
                if let userDict = json["user"] as? [String: Any] {
                    let user = UserProfile(
                        id: userDict["id"] as? Int ?? 0,
                        name: userDict["name"] as? String ?? "",
                        email: userDict["email"] as? String ?? "",
                        phone: userDict["phone"] as? String,
                        type: userDict["type"] as? String ?? "customer"
                    )
                    onLogin(user)
                }
            }
        }.resume()
    }
}

// MARK: - Home View (Native)

struct Restaurant: Identifiable, Codable {
    let id: Int
    let name: String
    let alias: String
    let type: Int
    let type_label: String
    let address: String
    let lat: Double
    let lng: Double
    let image: String?
    let categories: Int
    let items: Int
}

struct HomeView: View {
    @ObservedObject var locationManager: LocationManager
    @EnvironmentObject var appState: AppState
    @Environment(\.horizontalSizeClass) var sizeClass
    @State private var restaurants: [Restaurant] = []
    @State private var searchText = ""
    @State private var selectedFilter = "Alle"
    @State private var isLoading = true

    let filters = ["Alle", "Restauranter", "Butikker"]

    var filteredRestaurants: [Restaurant] {
        var list = restaurants
        if selectedFilter == "Restauranter" {
            list = list.filter { $0.type == 2 }
        } else if selectedFilter == "Butikker" {
            list = list.filter { $0.type != 2 }
        }
        if !searchText.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.address.localizedCaseInsensitiveContains(searchText) }
        }
        return list
    }

    var gridColumns: [GridItem] {
        if sizeClass == .regular {
            return [GridItem(.adaptive(minimum: 300), spacing: 16)]
        }
        return [GridItem(.flexible())]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Wromble")
                        .font(.system(size: sizeClass == .regular ? 38 : 28, weight: .heavy))
                        .foregroundColor(wrombleRed)
                    Text("Hvad har du lyst til i dag?")
                        .font(sizeClass == .regular ? .title3 : .subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                .padding(.top, 8)
                .padding(.bottom, 16)

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Soeg restauranter, butikker...", text: $searchText)
                        .font(sizeClass == .regular ? .body : .subheadline)
                }
                .padding(sizeClass == .regular ? 14 : 12)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                .padding(.bottom, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(filters, id: \.self) { filter in
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                selectedFilter = filter
                            }) {
                                Text(filter)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(selectedFilter == filter ? .white : .primary)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 10)
                                    .background(selectedFilter == filter ? wrombleRed : Color(.secondarySystemBackground))
                                    .cornerRadius(20)
                            }
                        }
                    }
                    .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                }
                .padding(.bottom, 20)

                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView().scaleEffect(1.2)
                        Text("Henter restauranter...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else if filteredRestaurants.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("Ingen resultater")
                            .font(.headline)
                        Text("Proev et andet soegeord")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVGrid(columns: gridColumns, spacing: sizeClass == .regular ? 16 : 12) {
                        ForEach(filteredRestaurants) { restaurant in
                            NavigationLink(destination: RestaurantDetailView(restaurant: restaurant)) {
                                RestaurantCard(restaurant: restaurant)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                }

                Spacer(minLength: 40)
            }
        }
        .navigationBarHidden(true)
        .refreshable { await loadRestaurants() }
        .task { await loadRestaurants() }
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
            }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }
}

// MARK: - Restaurant Card

struct RestaurantCard: View {
    let restaurant: Restaurant
    @Environment(\.horizontalSizeClass) var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                if let img = restaurant.image, !img.isEmpty {
                    AsyncImage(url: URL(string: "\(baseURL)/uploads/\(img)")) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            restaurantPlaceholder
                        }
                    }
                    .frame(height: sizeClass == .regular ? 180 : 140)
                    .clipped()
                } else {
                    restaurantPlaceholder
                        .frame(height: sizeClass == .regular ? 180 : 140)
                }

                Text(restaurant.type_label)
                    .font(.caption.weight(.bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(wrombleRed)
                    .cornerRadius(8)
                    .padding(10)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(restaurant.name)
                    .font(sizeClass == .regular ? .title3.weight(.bold) : .headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundColor(wrombleRed)
                        .font(.caption)
                    Text(restaurant.address)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 12) {
                    Label("\(restaurant.categories) kategorier", systemImage: "list.bullet")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Label("\(restaurant.items) varer", systemImage: "cart")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(sizeClass == .regular ? 14 : 12)
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    var restaurantPlaceholder: some View {
        ZStack {
            Color(.tertiarySystemBackground)
            Image(systemName: restaurant.type == 2 ? "fork.knife" : "bag.fill")
                .font(.system(size: 36))
                .foregroundColor(.secondary.opacity(0.4))
        }
    }
}

// MARK: - Restaurant Detail (Native)

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

struct RestaurantDetailView: View {
    let restaurant: Restaurant
    @Environment(\.horizontalSizeClass) var sizeClass
    @State private var categories: [MenuCategory] = []
    @State private var isLoading = true
    @State private var showWebOrder = false

    var body: some View {
        Group {
            if showWebOrder {
                WebOrderView(restaurant: restaurant)
            } else {
                menuContent
            }
        }
        .navigationTitle(restaurant.name)
        .navigationBarTitleDisplayMode(.large)
        .task { await loadMenu() }
    }

    var menuContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(restaurant.type_label)
                                .font(.caption.weight(.bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(wrombleRed)
                                .cornerRadius(6)
                            Text(restaurant.name)
                                .font(sizeClass == .regular ? .title.bold() : .title2.bold())
                        }
                        Spacer()
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundColor(wrombleRed)
                        Text(restaurant.address)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(sizeClass == .regular ? 24 : 16)

                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    showWebOrder = true
                }) {
                    HStack {
                        Image(systemName: "cart.fill")
                        Text("Bestil nu")
                            .font(.headline)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(wrombleRed)
                    .cornerRadius(12)
                }
                .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                .padding(.bottom, 20)

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if categories.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "menucard")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("Ingen menukort endnu")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    ForEach(categories) { category in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(category.name)
                                .font(sizeClass == .regular ? .title2.bold() : .title3.bold())
                                .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                                .padding(.top, 12)

                            ForEach(category.products) { item in
                                MenuItemRow(item: item)
                                    .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                            }
                        }

                        if category.id != categories.last?.id {
                            Divider()
                                .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                                .padding(.vertical, 8)
                        }
                    }
                }

                Spacer(minLength: 40)
            }
        }
    }

    func loadMenu() async {
        guard let url = URL(string: "\(baseURL)/api/menu.php?company_id=\(restaurant.id)") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct Response: Codable {
                let company: CompanyInfo?
                let categories: [MenuCategory]
                struct CompanyInfo: Codable { let id: Int; let name: String }
            }
            let response = try JSONDecoder().decode(Response.self, from: data)
            await MainActor.run {
                categories = response.categories
                isLoading = false
            }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }
}

// MARK: - Menu Item Row

struct MenuItemRow: View {
    let item: MenuItem
    @Environment(\.horizontalSizeClass) var sizeClass

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(sizeClass == .regular ? .body.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                if let desc = item.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Text(String(format: "%.2f kr", item.price))
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(wrombleRed)
            }

            Spacer()

            if let img = item.image, !img.isEmpty {
                AsyncImage(url: URL(string: "\(baseURL)/uploads/\(img)")) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Color(.tertiarySystemBackground)
                    }
                }
                .frame(width: sizeClass == .regular ? 80 : 64, height: sizeClass == .regular ? 80 : 64)
                .cornerRadius(10)
                .clipped()
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Web Order View (checkout only)

struct WebOrderView: View {
    let restaurant: Restaurant
    @State private var orderURL: URL?

    var body: some View {
        WrombleWebView(url: $orderURL)
            .navigationTitle("Bestil")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                let alias = restaurant.alias.isEmpty ? "\(restaurant.id)" : restaurant.alias
                orderURL = URL(string: "\(baseURL)/\(alias)/")
            }
    }
}

// MARK: - Explore View (Native)

struct ExploreView: View {
    @ObservedObject var locationManager: LocationManager
    @EnvironmentObject var appState: AppState
    @Environment(\.horizontalSizeClass) var sizeClass

    let categories: [(name: String, icon: String)] = [
        ("Alle", "square.grid.2x2.fill"),
        ("Restauranter", "fork.knife"),
        ("Butikker", "bag.fill"),
        ("Cafeer", "cup.and.saucer.fill"),
        ("Bagerier", "birthday.cake.fill"),
    ]

    let quickActions: [(name: String, icon: String)] = [
        ("Bordbestilling", "calendar.badge.clock"),
        ("Wromble+", "star.fill"),
        ("Bliv partner", "handshake.fill"),
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
                            .foregroundColor(wrombleRed)
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
                        .foregroundColor(wrombleRed)
                    }
                    .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                }

                VStack(alignment: .leading, spacing: sizeClass == .regular ? 18 : 12) {
                    Text("Kategorier")
                        .font(sizeClass == .regular ? .title.bold() : .title2.bold())
                        .padding(.horizontal, sizeClass == .regular ? 24 : 16)

                    LazyVGrid(columns: gridColumns, spacing: sizeClass == .regular ? 16 : 12) {
                        ForEach(categories, id: \.name) { cat in
                            HStack(spacing: sizeClass == .regular ? 16 : 12) {
                                Image(systemName: cat.icon)
                                    .font(sizeClass == .regular ? .title2 : .title3)
                                    .foregroundColor(.white)
                                    .frame(width: sizeClass == .regular ? 56 : 44, height: sizeClass == .regular ? 56 : 44)
                                    .background(wrombleRed)
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
                    .padding(.horizontal, sizeClass == .regular ? 24 : 16)
                }

                VStack(alignment: .leading, spacing: sizeClass == .regular ? 18 : 12) {
                    Text("Hurtig adgang")
                        .font(sizeClass == .regular ? .title.bold() : .title2.bold())
                        .padding(.horizontal, sizeClass == .regular ? 24 : 16)

                    ForEach(quickActions, id: \.name) { action in
                        HStack(spacing: sizeClass == .regular ? 18 : 14) {
                            Image(systemName: action.icon)
                                .font(sizeClass == .regular ? .title2 : .title3)
                                .foregroundColor(wrombleRed)
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
                        .padding(.horizontal, sizeClass == .regular ? 24 : 16)
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

// MARK: - Orders View (Native)

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
                    if user.id > 0 {
                        showLogin = false
                        loadOrders(userId: user.id)
                    }
                })
            } else {
                loginPrompt
            }
        }
        .navigationTitle("Ordrer")
        .onAppear {
            if let savedId = UserDefaults.standard.value(forKey: "loggedInUserId") as? Int, savedId > 0 {
                let savedName = UserDefaults.standard.string(forKey: "loggedInUserName") ?? ""
                let savedEmail = UserDefaults.standard.string(forKey: "loggedInUserEmail") ?? ""
                loggedInUser = UserProfile(id: savedId, name: savedName, email: savedEmail, phone: nil, type: "customer")
                loadOrders(userId: savedId)
            }
        }
    }

    var loginPrompt: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bag.circle.fill")
                .font(.system(size: sizeClass == .regular ? 70 : 50))
                .foregroundColor(wrombleRed)
            Text("Se dine ordrer")
                .font(sizeClass == .regular ? .title.bold() : .title2.bold())
            Text("Log ind for at se din ordrehistorik")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button(action: {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showLogin = true
            }) {
                Text("Log ind")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: sizeClass == .regular ? 300 : .infinity)
                    .padding(.vertical, 14)
                    .background(wrombleRed)
                    .cornerRadius(12)
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
                    Text("Henter ordrer...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                    Spacer()
                }
            } else if orders.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "bag")
                        .font(.system(size: 50))
                        .foregroundColor(.secondary)
                    Text("Ingen ordrer endnu")
                        .font(.title3.bold())
                    Text("Dine ordrer vises her naar du bestiller")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List(orders) { order in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(order.companyName)
                                .font(.headline)
                            Spacer()
                            orderStatusBadge(order.status)
                        }

                        if !order.date.isEmpty {
                            Text(order.date)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        ForEach(order.items, id: \.name) { item in
                            HStack {
                                Text("\(item.quantity)x \(item.name)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(String(format: "%.2f kr", item.price * Double(item.quantity)))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }

                        HStack {
                            Spacer()
                            Text(String(format: "Total: %.2f kr", order.total))
                                .font(.subheadline.weight(.bold))
                                .foregroundColor(wrombleRed)
                        }
                    }
                    .padding(.vertical, 4)
                }
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
            .font(.caption.weight(.bold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color)
            .cornerRadius(6)
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
                      let ordersArray = json["orders"] as? [[String: Any]] else { return }

                orders = ordersArray.map { o in
                    let items = (o["items"] as? [[String: Any]] ?? []).map { i in
                        OrderItem(
                            name: i["name"] as? String ?? "Ukendt",
                            quantity: i["quantity"] as? Int ?? 1,
                            price: i["price"] as? Double ?? 0
                        )
                    }
                    return Order(
                        id: o["id"] as? Int ?? 0,
                        companyName: o["company_name"] as? String ?? "Ukendt",
                        date: o["date"] as? String ?? "",
                        total: o["total"] as? Double ?? 0,
                        status: o["status"] as? String ?? "pending",
                        items: items
                    )
                }
            }
        }.resume()
    }
}

// MARK: - Chat View (Native)

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

class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var conversationId: Int = 0
    @Published var status: String = "open"
    @Published var isStarted = false
    @Published var isLoading = false

    private var pollTimer: Timer?
    private var lastMessageId = 0

    func startConversation(name: String, email: String) {
        isLoading = true
        guard let url = URL(string: "\(baseURL)/api/chat-start.php") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["name": name, "email": email]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

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
            "conversation_id": conversationId,
            "sender_type": "customer",
            "sender_name": senderName,
            "message": text
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    func startPolling() {
        pollTimer?.invalidate()
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        guard conversationId > 0 else { return }
        guard let url = URL(string: "\(baseURL)/api/chat-poll.php?conversation_id=\(conversationId)&after=\(lastMessageId)") else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let msgsArray = json["messages"] as? [[String: Any]] else { return }

            let newStatus = json["status"] as? String ?? "open"
            var newMessages: [ChatMessage] = []
            for msg in msgsArray {
                let cm = ChatMessage(
                    id: msg["id"] as? Int ?? 0,
                    senderType: msg["sender_type"] as? String ?? "",
                    senderName: msg["sender_name"] as? String ?? "",
                    message: msg["message"] as? String ?? "",
                    fileURL: msg["file_url"] as? String,
                    fileType: msg["file_type"] as? String,
                    fileName: msg["file_name"] as? String,
                    createdAt: msg["created_at"] as? String ?? ""
                )
                newMessages.append(cm)
            }

            DispatchQueue.main.async {
                self?.status = newStatus
                if !newMessages.isEmpty {
                    self?.messages.append(contentsOf: newMessages)
                    self?.lastMessageId = newMessages.last?.id ?? self?.lastMessageId ?? 0
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

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.isStarted {
                chatStartForm
            } else {
                chatMessages
                if viewModel.status == "open" {
                    chatInputBar
                } else {
                    closedBanner
                }
            }
        }
        .navigationTitle("Kundeservice")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { viewModel.stopPolling() }
    }

    var chatStartForm: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "message.badge.fill")
                .font(.system(size: sizeClass == .regular ? 70 : 50))
                .foregroundColor(wrombleRed)

            Text("Kontakt Kundeservice")
                .font(sizeClass == .regular ? .title.bold() : .title2.bold())

            Text("Vi svarer hurtigst muligt")
                .font(.subheadline)
                .foregroundColor(.secondary)

            VStack(spacing: 12) {
                TextField("Dit navn", text: $nameInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)

                TextField("E-mail (valgfrit)", text: $emailInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .autocapitalization(.none)
            }
            .frame(maxWidth: sizeClass == .regular ? 400 : .infinity)
            .padding(.horizontal, sizeClass == .regular ? 60 : 30)

            Button(action: {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                viewModel.startConversation(name: nameInput, email: emailInput)
            }) {
                if viewModel.isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text("Start chat")
                        .font(.headline)
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: sizeClass == .regular ? 400 : .infinity)
            .padding(.vertical, 14)
            .background(nameInput.isEmpty ? Color.gray : wrombleRed)
            .cornerRadius(12)
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
                        chatBubble(msg)
                            .id(msg.id)
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
        return HStack {
            if isCustomer { Spacer(minLength: 60) }
            VStack(alignment: isCustomer ? .trailing : .leading, spacing: 4) {
                if !isCustomer {
                    Text(msg.senderName)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                }
                Text(msg.message)
                    .font(.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isCustomer ? wrombleRed : Color(.secondarySystemBackground))
                    .foregroundColor(isCustomer ? .white : .primary)
                    .cornerRadius(16)

                if let fileURL = msg.fileURL, !fileURL.isEmpty, msg.fileType == "image" {
                    AsyncImage(url: URL(string: "\(baseURL)\(fileURL)")) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                                .frame(maxWidth: 200, maxHeight: 150)
                                .cornerRadius(10)
                        default:
                            ProgressView()
                        }
                    }
                }
            }
            if !isCustomer { Spacer(minLength: 60) }
        }
    }

    var chatInputBar: some View {
        HStack(spacing: 10) {
            TextField("Skriv en besked...", text: $messageInput)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .onSubmit { send() }

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(messageInput.isEmpty ? .gray : wrombleRed)
            }
            .disabled(messageInput.isEmpty)
        }
        .padding(.horizontal, sizeClass == .regular ? 20 : 14)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
        .overlay(Divider(), alignment: .top)
    }

    var closedBanner: some View {
        VStack(spacing: 10) {
            Text("Denne samtale er lukket")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button(action: {
                viewModel.stopPolling()
                viewModel.messages = []
                viewModel.conversationId = 0
                viewModel.isStarted = false
                viewModel.status = "open"
            }) {
                Text("Start ny samtale")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(wrombleRed)
                    .cornerRadius(10)
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
        viewModel.sendMessage(text, senderName: nameInput)
        let localMsg = ChatMessage(
            id: (viewModel.messages.last?.id ?? 0) + 1,
            senderType: "customer",
            senderName: nameInput,
            message: text,
            fileURL: nil,
            fileType: nil,
            fileName: nil,
            createdAt: ""
        )
        viewModel.messages.append(localMsg)
        messageInput = ""
    }
}

// MARK: - Profile View (Fully Native)

struct ProfileView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var locationManager: LocationManager
    @Environment(\.horizontalSizeClass) var sizeClass
    @State private var showBiometricAlert = false
    @State private var showShareSheet = false
    @State private var showLogin = false
    @State private var loggedInUser: UserProfile?

    var body: some View {
        List {
            // User section
            Section {
                if let user = loggedInUser, user.id > 0 {
                    HStack(spacing: sizeClass == .regular ? 20 : 16) {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: sizeClass == .regular ? 64 : 50))
                            .foregroundColor(wrombleRed)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(user.name)
                                .font(sizeClass == .regular ? .title2.bold() : .title3.bold())
                            Text(user.email)
                                .font(sizeClass == .regular ? .body : .subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, sizeClass == .regular ? 12 : 8)
                } else {
                    Button(action: { showLogin = true }) {
                        HStack(spacing: sizeClass == .regular ? 20 : 16) {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: sizeClass == .regular ? 64 : 50))
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Log ind")
                                    .font(sizeClass == .regular ? .title2.bold() : .title3.bold())
                                Text("Log ind eller opret en konto")
                                    .font(sizeClass == .regular ? .body : .subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, sizeClass == .regular ? 12 : 8)
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
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }

            Section(header: Text("Placering")) {
                Toggle(isOn: $appState.locationEnabled) {
                    Label("Brug placering", systemImage: "location.fill")
                }
                .tint(wrombleRed)
                .onChange(of: appState.locationEnabled) { newValue in
                    if newValue { locationManager.requestLocation() }
                    appState.save()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
                .tint(wrombleRed)
                .onChange(of: appState.biometricEnabled) { newValue in
                    if newValue { authenticateBiometric() }
                    appState.save()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }

            Section(header: Text("Del & Support")) {
                Button(action: {
                    showShareSheet = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }) {
                    Label("Del Wromble med venner", systemImage: "square.and.arrow.up")
                        .foregroundColor(.primary)
                }

                Link(destination: URL(string: "\(baseURL)/privacy-policy/app.php")!) {
                    Label("Privatlivspolitik", systemImage: "hand.raised.fill")
                        .foregroundColor(.primary)
                }
            }

            Section(header: Text("Om")) {
                HStack {
                    Label("Version", systemImage: "info.circle")
                    Spacer()
                    Text("1.0 (6)")
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

            if loggedInUser != nil && loggedInUser!.id > 0 {
                Section {
                    Button(action: {
                        loggedInUser = nil
                        UserDefaults.standard.removeObject(forKey: "loggedInUserId")
                        UserDefaults.standard.removeObject(forKey: "loggedInUserName")
                        UserDefaults.standard.removeObject(forKey: "loggedInUserEmail")
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }) {
                        HStack {
                            Spacer()
                            Text("Log ud")
                                .foregroundColor(.red)
                                .font(.body.weight(.semibold))
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
                .navigationTitle("Konto")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Luk") { showLogin = false }
                    }
                }
            }
        }
        .alert("Biometrisk login", isPresented: $showBiometricAlert) {
            Button("OK") {
                appState.biometricEnabled = false
                appState.save()
            }
        } message: {
            Text("Biometrisk login er ikke tilgaengelig paa denne enhed.")
        }
        .onAppear {
            if let savedId = UserDefaults.standard.value(forKey: "loggedInUserId") as? Int, savedId > 0 {
                let savedName = UserDefaults.standard.string(forKey: "loggedInUserName") ?? ""
                let savedEmail = UserDefaults.standard.string(forKey: "loggedInUserEmail") ?? ""
                loggedInUser = UserProfile(id: savedId, name: savedName, email: savedEmail, phone: nil, type: "customer")
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

// MARK: - WebView (checkout flow only)

struct WrombleWebView: UIViewRepresentable {
    @Binding var url: URL?

    func makeCoordinator() -> WebCoordinator {
        WebCoordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let userController = WKUserContentController()
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

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if let newURL = url, uiView.url != newURL {
            uiView.load(URLRequest(url: newURL))
        }
    }

    class WebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var webView: WKWebView?

        @objc func handleRefresh(_ refreshControl: UIRefreshControl) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            webView?.reload()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                refreshControl.endRefreshing()
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
