import SwiftUI
import StoreKit
import Combine
import UserNotifications
import AuthenticationServices

extension Color {
    static let brandBg = Color(red: 250/255, green: 248/255, blue: 245/255)
    static let brandCard = Color.white
    static let brandText = Color(red: 43/255, green: 32/255, blue: 11/255)
    static let brandSecondary = Color(red: 120/255, green: 110/255, blue: 95/255)
    static let brandGold = Color(red: 226/255, green: 179/255, blue: 60/255)
    static let brandGoldLight = Color(red: 253/255, green: 251/255, blue: 235/255)
    static let brandBorder = Color(red: 230/255, green: 225/255, blue: 218/255)
}

struct Recipe: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var description: String
    var ingredients: [String]
    var instructions: [String]
    var prepTime: Int
    var imageUrl: String?
    var photographerName: String?
    var photographerUrl: String?
    
    init(id: UUID = UUID(), title: String, description: String, ingredients: [String], instructions: [String], prepTime: Int, imageUrl: String?, photographerName: String?, photographerUrl: String?) {
        self.id = id
        self.title = title
        self.description = description
        self.ingredients = ingredients
        self.instructions = instructions
        self.prepTime = prepTime
        self.imageUrl = imageUrl
        self.photographerName = photographerName
        self.photographerUrl = photographerUrl
    }
}

enum CreationMode {
    case ai, ingredients, manual
}

class SupabaseAuth: ObservableObject, @unchecked Sendable {
    @Published var isAuthenticated: Bool = false
    @Published var errorMessage: String? = nil
    @Published var isLoading: Bool = false
    @Published var isChef: Bool = false
    @Published var dailyRecipeCount: Int = 0
    @Published var lastRecipeDate: Date? = nil
    @Published var showQuotaModal: Bool = false
    @Published var showUpgradeModal: Bool = false
    @Published var isProcessingPayment: Bool = false
    @Published var product: Product? = nil
    @Published var purchaseState: PurchaseState = .idle
    @Published var unsplashAccessKey: String? = nil
    @Published var unsplashSecretKey: String? = nil
    @Published var googleApiKey: String? = nil
    @Published var appError: String? = nil
    @Published var notificationsEnabled: Bool = false
    @Published var passkeyAvailable: Bool = false
    
    private let projectUrl = "https://ojvigxnwweixjhugekmm.supabase.co"
    private let apiKey = "sb_publishable_ok_vkZ1FDJ_hv-qdv76tJw_RJ78nd6W"
    private let dailyQuota = 3
    private let chefProductId = "com.cookery.chef.upgrade"
    private var updateListenerTask: Task<Void, Error>? = nil
    
    private let authKey = "cookery_auth_state"
    private let chefKey = "cookery_chef_status"
    private let recipeCountKey = "cookery_daily_count"
    private let lastDateKey = "cookery_last_date"
    private let notificationsKey = "cookery_notifications_enabled"
    
    enum PurchaseState {
        case idle
        case purchasing
        case purchased
        case failed(String)
    }
    
    init() {
        loadPersistedState()
        updateListenerTask = listenForTransactions()
        fetchSecrets()
        checkNotificationPermission()
        checkPasskeyAvailability()
    }
    
    deinit {
        updateListenerTask?.cancel()
    }
    
    var hasReachedQuota: Bool {
        if isChef { return false }
        
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        
        if let lastDate = lastRecipeDate {
            let lastDay = calendar.startOfDay(for: lastDate)
            if lastDay < today {
                return false
            }
        }
        
        return dailyRecipeCount >= dailyQuota
    }
    
    func incrementRecipeCount() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        
        if let lastDate = lastRecipeDate {
            let lastDay = calendar.startOfDay(for: lastDate)
            if lastDay < today {
                dailyRecipeCount = 1
                lastRecipeDate = Date()
            } else {
                dailyRecipeCount += 1
            }
        } else {
            dailyRecipeCount = 1
            lastRecipeDate = Date()
        }
        saveQuotaState()
    }
    
    func loadProduct() {
        Task { @MainActor in
            do {
                let products = try await Product.products(for: [chefProductId])
                if let product = products.first {
                    self.product = product
                }
            } catch {
                print("Failed to load product: \(error)")
            }
        }
    }
    
    func upgradeToChef() {
        guard let product = product else {
            loadProduct()
            return
        }
        
        isProcessingPayment = true
        purchaseState = .purchasing
        
        Task {
            do {
                let result = try await product.purchase()
                
                switch result {
                case .success(let verification):
                    let transaction = try checkVerified(verification)
                    await transaction.finish()
                    
                    DispatchQueue.main.async {
                        self.isChef = true
                        self.isProcessingPayment = false
                        self.purchaseState = .purchased
                        self.showUpgradeModal = false
                        self.showQuotaModal = false
                        self.saveChefStatus()
                    }
                    
                case .userCancelled:
                    DispatchQueue.main.async {
                        self.isProcessingPayment = false
                        self.purchaseState = .idle
                    }
                    
                case .pending:
                    DispatchQueue.main.async {
                        self.isProcessingPayment = false
                        self.purchaseState = .idle
                    }
                    
                @unknown default:
                    DispatchQueue.main.async {
                        self.isProcessingPayment = false
                        self.purchaseState = .failed("Unknown error")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isProcessingPayment = false
                    self.purchaseState = .failed(error.localizedDescription)
                }
            }
        }
    }
    
    private func checkVerified<T>(_ verification: VerificationResult<T>) throws -> T {
        switch verification {
        case .unverified:
            throw PurchaseError.failedVerification
        case .verified(let safe):
            return safe
        }
    }
    
    private func listenForTransactions() -> Task<Void, Error> {
        return Task.detached {
            for await result in StoreKit.Transaction.updates {
                await self.handleTransaction(result)
            }
        }
    }
    
    private func handleTransaction(_ result: VerificationResult<StoreKit.Transaction>) async {
        let transaction = try? checkVerified(result)
        
        guard let transaction = transaction else {
            return
        }
        
        if transaction.productID == chefProductId {
            await MainActor.run {
                self.isChef = true
                self.saveChefStatus()
            }
            await transaction.finish()
        }
    }
}

enum PurchaseError: Error {
    case failedVerification
}

extension SupabaseAuth {
    func signUp(email: String, password: String) {
        performAuthAction(endpoint: "/auth/v1/signup", email: email, password: password)
    }
    
    func signIn(email: String, password: String) {
        performAuthAction(endpoint: "/auth/v1/token?grant_type=password", email: email, password: password)
    }
    
    private func performAuthAction(endpoint: String, email: String, password: String) {
        guard let url = URL(string: projectUrl + endpoint) else { return }
        
        DispatchQueue.main.async {
            self.isLoading = true
            self.errorMessage = nil
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = ["email": email, "password": password]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                self.isLoading = false
                if let error = error {
                    self.errorMessage = error.localizedDescription
                    return
                }
                
                if let httpResponse = response as? HTTPURLResponse {
                    if (200...299).contains(httpResponse.statusCode) {
                        self.isAuthenticated = true
                        self.saveAuthState()
                    } else {
                        if let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let msg = json["error_description"] as? String ?? json["msg"] as? String {
                            self.errorMessage = msg
                        } else {
                            self.errorMessage = "Authentication failed (Status code: \(httpResponse.statusCode))"
                        }
                    }
                }
            }
        }.resume()
    }
    
    func signOut() {
        self.isAuthenticated = false
        UserDefaults.standard.set(false, forKey: authKey)
    }
    
    func continueWithoutAccount() {
        self.isAuthenticated = true
        UserDefaults.standard.set(true, forKey: authKey)
    }
    
    private func loadPersistedState() {
        self.isAuthenticated = UserDefaults.standard.bool(forKey: authKey)
        self.isChef = UserDefaults.standard.bool(forKey: chefKey)
        self.dailyRecipeCount = UserDefaults.standard.integer(forKey: recipeCountKey)
        self.notificationsEnabled = UserDefaults.standard.bool(forKey: notificationsKey)
        if let lastDate = UserDefaults.standard.object(forKey: lastDateKey) as? Date {
            self.lastRecipeDate = lastDate
        }
    }
    
    private func saveAuthState() {
        UserDefaults.standard.set(isAuthenticated, forKey: authKey)
    }
    
    private func saveChefStatus() {
        UserDefaults.standard.set(isChef, forKey: chefKey)
    }
    
    private func saveQuotaState() {
        UserDefaults.standard.set(dailyRecipeCount, forKey: recipeCountKey)
        if let lastDate = lastRecipeDate {
            UserDefaults.standard.set(lastDate, forKey: lastDateKey)
        }
    }
    
    private func saveNotificationState() {
        UserDefaults.standard.set(notificationsEnabled, forKey: notificationsKey)
    }
    
    func checkNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.notificationsEnabled = settings.authorizationStatus == .authorized
            }
        }
    }
    
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DispatchQueue.main.async {
                self.notificationsEnabled = granted
                self.saveNotificationState()
                if let error = error {
                    self.appError = "Failed to enable notifications: \(error.localizedDescription)"
                }
            }
        }
    }
    
    func sendRecipeNotification(recipeTitle: String) {
        let content = UNMutableNotificationContent()
        content.title = "Recipe Ready!"
        content.body = "Your \(recipeTitle) recipe is ready to view."
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                DispatchQueue.main.async {
                    self.appError = "Failed to send notification: \(error.localizedDescription)"
                }
            }
        }
    }
    
    func fetchSecrets() {
        fetchUnsplashKeys()
        fetchGoogleApiKey()
    }
    
    private func fetchUnsplashKeys() {
        Task { @MainActor in
            do {
                let urlString = "\(projectUrl)/rest/v1/secrets?key_name=eq.unsplash_access_key&select=key_value,secret_key"
                guard let url = URL(string: urlString) else { return }
                
                var request = URLRequest(url: url)
                request.setValue(apiKey, forHTTPHeaderField: "apikey")
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                
                let (data, _) = try await URLSession.shared.data(for: request)
                if let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                   let secret = json.first {
                    self.unsplashAccessKey = secret["key_value"] as? String
                    self.unsplashSecretKey = secret["secret_key"] as? String
                }
            } catch {
                print("Failed to fetch Unsplash keys: \(error)")
            }
        }
    }
    
    private func fetchGoogleApiKey() {
        Task { @MainActor in
            do {
                let urlString = "\(projectUrl)/rest/v1/secrets?key_name=eq.lola_api_key&select=key_value"
                guard let url = URL(string: urlString) else { return }
                
                var request = URLRequest(url: url)
                request.setValue(apiKey, forHTTPHeaderField: "apikey")
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                
                let (data, _) = try await URLSession.shared.data(for: request)
                if let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                   let secret = json.first {
                    self.googleApiKey = secret["key_value"] as? String
                }
            } catch {
                print("Failed to fetch Google API key: \(error)")
            }
        }
    }
    
    func fetchFoodImage(query: String = "food") async -> String? {
        guard let accessKey = unsplashAccessKey else {
            fetchUnsplashKeys()
            return nil
        }
        
        do {
            let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "food"
            let urlString = "https://api.unsplash.com/photos/random?query=\(encodedQuery)&count=1&client_id=\(accessKey)"
            guard let url = URL(string: urlString) else { return nil }
            
            let request = URLRequest(url: url)
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let photo = json.first,
               let imageUrl = photo["urls"] as? [String: Any],
               let regularUrl = imageUrl["regular"] as? String {
                
                if let photoId = photo["id"] as? String {
                    let downloadUrl = "https://api.unsplash.com/photos/\(photoId)/download?client_id=\(accessKey)"
                    if let downloadURL = URL(string: downloadUrl) {
                        _ = try? await URLSession.shared.data(from: downloadURL)
                    }
                }
                
                return regularUrl
            }
        } catch {
            print("Failed to fetch Unsplash image: \(error)")
        }
        
        return nil
    }
    
    func generateRecipe(prompt: String, dietary: [String], style: String) async -> Recipe? {
        guard let apiKey = googleApiKey else {
            fetchGoogleApiKey()
            return nil
        }
        
        do {
            let dietaryText = dietary.isEmpty ? "no dietary restrictions" : dietary.joined(separator: ", ")
            let systemPrompt = "You are a professional chef. Generate a detailed recipe based on the user's request. Return the response in JSON format with the following structure: {\"title\": \"recipe title\", \"description\": \"brief description\", \"ingredients\": [\"ingredient 1\", \"ingredient 2\"], \"instructions\": [\"step 1\", \"step 2\"], \"prepTime\": 30}"
            
            let userPrompt = "Create a recipe for: \(prompt). Style: \(style). Dietary requirements: \(dietaryText)."
            
            let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent?key=\(apiKey)"
            guard let url = URL(string: urlString) else { return nil }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let requestBody: [String: Any] = [
                "contents": [
                    [
                        "role": "user",
                        "parts": [
                            ["text": systemPrompt],
                            ["text": userPrompt]
                        ]
                    ]
                ],
                "generationConfig": [
                    "temperature": 0.7,
                    "maxOutputTokens": 1024
                ]
            ]
            
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let candidates = json["candidates"] as? [[String: Any]],
               let firstCandidate = candidates.first,
               let content = firstCandidate["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]],
               let firstPart = parts.first,
               let text = firstPart["text"] as? String {
                
                let jsonPattern = #"\\{\s*\"title\"\s*:\s*\"([^\"]+)\"\s*,\s*\"description\"\s*:\s*\"([^\"]+)\"\s*,\s*\"ingredients\"\s*:\s*\[([^\]]+)\]\s*,\s*\"instructions\"\s*:\s*\[([^\]]+)\]\s*,\s*\"prepTime\"\s*:\s*(\d+)"#
                
                if let regex = try? NSRegularExpression(pattern: jsonPattern, options: []),
                   let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                    
                    let title = (text as NSString).substring(with: match.range(at: 1))
                    let description = (text as NSString).substring(with: match.range(at: 2))
                    let ingredientsString = (text as NSString).substring(with: match.range(at: 3))
                    let instructionsString = (text as NSString).substring(with: match.range(at: 4))
                    let prepTime = Int((text as NSString).substring(with: match.range(at: 5))) ?? 20
                    
                    let ingredients = ingredientsString.components(separatedBy: ",").map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "") }
                    let instructions = instructionsString.components(separatedBy: ",").map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "") }
                    
                    let imageUrl = await fetchFoodImage(query: title)
                    
                    return Recipe(
                        title: title,
                        description: description,
                        ingredients: ingredients,
                        instructions: instructions,
                        prepTime: prepTime,
                        imageUrl: imageUrl,
                        photographerName: "Unsplash",
                        photographerUrl: "https://unsplash.com"
                    )
                }
            }
        } catch {
            print("Failed to generate recipe: \(error)")
        }
        
        return nil
    }
    
    func checkPasskeyAvailability() {
        passkeyAvailable = true
    }
    
    func registerPasskey(email: String) async -> Bool {
        guard let url = URL(string: "\(projectUrl)/auth/v1/mfa") else { return false }
        
        let challenge = generateChallenge()
        let userID = UUID().uuidString
        
        let registrationRequest: [String: Any] = [
            "email": email,
            "challenge": challenge,
            "user_id": userID,
            "origin": "https://\(projectUrl)"
        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: registrationRequest)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData
            
            let (_, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return false
            }
            
            return true
        } catch {
            print("Passkey registration failed: \(error)")
            appError = "Passkey registration failed"
            return false
        }
    }
    
    func signInWithPasskey() async -> Bool {
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.email, .fullName]
        
        return await withCheckedContinuation { continuation in
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = PasskeyDelegate(continuation: continuation, auth: self)
            controller.performRequests()
        }
    }
    
    func verifyPasskeyAuthorization(_ credential: ASAuthorizationCredential) async -> Bool {
        guard let appleIDCredential = credential as? ASAuthorizationAppleIDCredential,
              let identityToken = appleIDCredential.identityToken else {
            return false
        }
        
        let tokenString = String(data: identityToken, encoding: .utf8) ?? ""
        
        guard let url = URL(string: "\(projectUrl)/auth/v1/verify") else { return false }
        
        let verificationRequest: [String: Any] = [
            "id_token": tokenString,
            "provider": "apple"
        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: verificationRequest)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return false
            }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let accessToken = json["access_token"] as? String {
                UserDefaults.standard.set(accessToken, forKey: authKey)
                isAuthenticated = true
                return true
            }
            
            return false
        } catch {
            print("Passkey verification failed: \(error)")
            appError = "Passkey verification failed"
            return false
        }
    }
    
    private func generateChallenge() -> String {
        var data = Data(count: 32)
        data.withUnsafeMutableBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                let status = SecRandomCopyBytes(kSecRandomDefault, 32, baseAddress)
                if status != errSecSuccess {
                    print("Failed to generate random bytes")
                }
            }
        }
        return data.base64EncodedString()
    }
}

class PasskeyDelegate: NSObject, ASAuthorizationControllerDelegate {
    let continuation: CheckedContinuation<Bool, Never>
    let auth: SupabaseAuth
    
    init(continuation: CheckedContinuation<Bool, Never>, auth: SupabaseAuth) {
        self.continuation = continuation
        self.auth = auth
        super.init()
    }
    
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        Task {
            let success = await auth.verifyPasskeyAuthorization(authorization.credential)
            continuation.resume(returning: success)
        }
    }
    
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        print("Passkey sign in failed: \(error)")
        auth.appError = "Passkey sign in failed"
        continuation.resume(returning: false)
    }
}

@main
@available(iOS 16.0, *)
struct CookeryAIApp: App {
    @StateObject private var auth = SupabaseAuth()
    
    var body: some Scene {
        WindowGroup {
            if auth.isAuthenticated {
                ContentView()
                    .environmentObject(auth)
            } else {
                LoginScreen()
                    .environmentObject(auth)
            }
        }
    }
}

struct LoginScreen: View {
    @EnvironmentObject var auth: SupabaseAuth
    @State private var email = ""
    @State private var password = ""
    @State private var isSignUpMode = false
    @State private var showAuthForm = false
    
    var body: some View {
        VStack {
            if showAuthForm {
                authForm
            } else {
                welcomeScreen
            }
        }
        .background(Color.brandBg.ignoresSafeArea())
    }
    
    private var welcomeScreen: some View {
        ScrollView {
            VStack(spacing: 0) {
                ZStack {
                    Image("cooking")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 500)
                        .clipped()
                    
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.3),
                            Color.black.opacity(0.1),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 500)
                    
                    VStack(alignment: .leading, spacing: 16) {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.brandGold, Color.orange],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 80, height: 80)
                            .shadow(color: Color.brandGold.opacity(0.4), radius: 20, x: 0, y: 10)
                            .overlay {
                                Image(systemName: "fork.knife")
                                    .font(.system(size: 36, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Cookery")
                                .font(.system(size: 42, weight: .bold, design: .serif))
                                .foregroundColor(.white)
                                .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
                            
                            Text("Welcome to the future of recipes.")
                                .font(.system(size: 18, weight: .medium, design: .serif))
                                .foregroundColor(.white.opacity(0.95))
                                .lineSpacing(4)
                                .shadow(color: Color.black.opacity(0.2), radius: 2, x: 0, y: 1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(32)
                    .padding(.top, 60)
                }
                
                VStack(spacing: 20) {
                    VStack(spacing: 12) {
                        Button(action: { showAuthForm = true }) {
                            HStack {
                                Text("Get Started")
                                    .font(.system(size: 17, weight: .semibold))
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .buttonStyle(.borderedProminent)
                        }
                        
                        Button(action: { showAuthForm = true }) {
                            Text("Login")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal, 24)
                    
                    Button(action: { auth.continueWithoutAccount() }) {
                        HStack(spacing: 6) {
                            Text("Continue without an account")
                                .font(.system(size: 15, weight: .medium))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.brandSecondary)
                    }
                    .padding(.top, 8)
                }
                .padding(.top, 40)
                .padding(.bottom, 40)
            }
        }
        .background(Color.brandBg.ignoresSafeArea())
    }
    
    private var authForm: some View {
        ScrollView {
            VStack(spacing: 24) {
                Button(action: { showAuthForm = false }) {
                    HStack {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Back")
                            .font(.system(.body))
                            .fontWeight(.medium)
                    }
                    .foregroundColor(.brandText)
                    .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 16) {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.brandGold)
                            .frame(width: 64, height: 64)
                            .shadow(color: Color.brandText.opacity(0.1), radius: 6, x: 0, y: 3)
                            .overlay {
                                Image(systemName: "fork.knife")
                                    .font(.system(size: 26, weight: .medium))
                                    .foregroundColor(.white)
                            }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(isSignUpMode ? "Create Account" : "Sign In")
                                .font(.system(.largeTitle, design: .serif))
                                .fontWeight(.bold)
                                .foregroundColor(.brandText)
                            Text(isSignUpMode ? "Enter your details to get started" : "Welcome back to Cookery")
                                .font(.subheadline)
                                .foregroundColor(.brandSecondary)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.brandCard)
                .mask { RoundedRectangle(cornerRadius: 28, style: .continuous) }
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.brandBorder, lineWidth: 1))
                .padding(.horizontal)
                .shadow(color: Color.brandText.opacity(0.04), radius: 12, x: 0, y: 6)
                
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Email Address")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.brandSecondary)
                        TextField("name@example.com", text: $email)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                            .padding()
                            .background(Color.brandBg)
                            .cornerRadius(12)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Password")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.brandSecondary)
                        SecureField("••••••••", text: $password)
                            .padding()
                            .background(Color.brandBg)
                            .cornerRadius(12)
                    }
                }
                .padding(20)
                .background(Color.brandCard)
                .cornerRadius(24)
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.brandBorder, lineWidth: 1))
                .padding(.horizontal)
                
                if let error = auth.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                
                VStack(spacing: 12) {
                    Button(action: {
                        if isSignUpMode {
                            auth.signUp(email: email, password: password)
                        } else {
                            auth.signIn(email: email, password: password)
                        }
                    }) {
                        HStack {
                            if auth.isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Text(isSignUpMode ? "Create Account" : "Sign In")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                            }
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .buttonStyle(.borderedProminent)
                    }
                    .disabled(email.isEmpty || password.isEmpty || auth.isLoading)
                    
                    if auth.passkeyAvailable {
                        Button(action: {
                            Task {
                                if await auth.signInWithPasskey() {
                                    showAuthForm = false
                                }
                            }
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "faceid")
                                    .font(.system(size: 16, weight: .semibold))
                                Text("Sign in with Passkey")
                                    .font(.system(size: 15, weight: .medium))
                            }
                            .foregroundColor(.brandText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .buttonStyle(.bordered)
                        }
                    }
                    
                    Button(action: { isSignUpMode.toggle() }) {
                        Text(isSignUpMode ? "Already have an account? Sign In" : "Don't have an account? Sign Up")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(Color.brandGold)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
    }
}

@available(iOS 16.0, *)
struct ContentView: View {
    @EnvironmentObject var auth: SupabaseAuth
    @State private var recipes: [Recipe] = []
    @State private var selectedRecipe: Recipe? = nil
    @State private var showingGenerator = false
    @State private var showingEditSheet = false
    @State private var editingRecipe: Recipe? = nil
    @State private var showingDeleteAlert = false
    @State private var recipeToDelete: Recipe? = nil
    @State private var showingSettings = false
    
    private let recipesKey = "cookery_recipes"
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.brandBg.ignoresSafeArea()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Cookery")
                                        .font(.system(.largeTitle, design: .serif))
                                        .fontWeight(.bold)
                                        .foregroundColor(.brandText)
                                    if auth.isChef {
                                        Text("Chef")
                                            .font(.caption)
                                            .fontWeight(.bold)
                                            .foregroundColor(.brandGold)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.brandGoldLight)
                                            .cornerRadius(12)
                                    }
                                }
                                Text("Your kitchen, thoughtfully guided.")
                                    .font(.subheadline)
                                    .foregroundColor(.brandSecondary)
                            }
                            Spacer()
                            
                            HStack(spacing: 12) {
                                if !auth.isChef {
                                    Text("\(auth.dailyRecipeCount)/3")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.brandSecondary)
                                }
                                Button(action: { showingSettings = true }) {
                                    Image(systemName: "gearshape")
                                        .foregroundColor(.brandSecondary)
                                        .font(.system(size: 18))
                                }
                                Button(action: { auth.signOut() }) {
                                    Image(systemName: "rectangle.portrait.and.arrow.right")
                                        .foregroundColor(.brandSecondary)
                                        .font(.system(size: 18))
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 12)
                        
                        Button(action: { showingGenerator = true }) {
                            HStack(spacing: 8) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Recipe Lab")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.horizontal)
                        
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Your Recipes")
                                .font(.system(.title2, design: .serif))
                                .fontWeight(.medium)
                                .foregroundColor(.brandText)
                                .padding(.horizontal)
                            
                            ForEach(recipes) { recipe in
                                Button(action: { selectedRecipe = recipe }) {
                                    VStack(alignment: .leading, spacing: 0) {
                                        if let imageUrl = recipe.imageUrl {
                                            AsyncImage(url: URL(string: imageUrl)) { phase in
                                                switch phase {
                                                case .empty:
                                                    Rectangle()
                                                        .fill(Color.brandBg)
                                                        .frame(height: 160)
                                                case .success(let image):
                                                    image
                                                        .resizable()
                                                        .aspectRatio(contentMode: .fill)
                                                        .frame(height: 160)
                                                        .clipped()
                                                case .failure:
                                                    Rectangle()
                                                        .fill(Color.brandBg)
                                                        .frame(height: 160)
                                                        .overlay {
                                                            Image(systemName: "photo")
                                                                .foregroundColor(.brandSecondary)
                                                        }
                                                @unknown default:
                                                    EmptyView()
                                                }
                                            }
                                        }
                                        
                                        VStack(alignment: .leading, spacing: 10) {
                                            HStack(alignment: .firstTextBaseline) {
                                                Text(recipe.title)
                                                    .font(.system(.headline, design: .serif))
                                                    .foregroundColor(.brandText)
                                                Spacer()
                                                Text("\(recipe.prepTime) min")
                                                    .font(.caption)
                                                    .fontWeight(.semibold)
                                                    .foregroundColor(.brandGold)
                                                    .padding(.horizontal, 10)
                                                    .padding(.vertical, 4)
                                                    .background(Color.brandGoldLight)
                                                    .cornerRadius(20)
                                            }
                                            Text(recipe.description)
                                                .font(.subheadline)
                                                .foregroundColor(.brandSecondary)
                                                .multilineTextAlignment(.leading)
                                                .lineSpacing(2)
                                        }
                                        .padding(20)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.brandCard)
                                    .cornerRadius(24)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 24)
                                            .stroke(Color.brandBorder, lineWidth: 1)
                                    )
                                }
                                .contextMenu {
                                    Button(action: { editRecipe(recipe) }) {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    Button(action: { recipeToDelete = recipe; showingDeleteAlert = true }) {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                    .padding(.vertical)
                }
            }
            .navigationBarHidden(true)
            .sheet(item: $selectedRecipe) { recipe in
                RecipeDetailView(recipe: recipe)
            }
            .sheet(isPresented: $showingGenerator) {
                AIGeneratorView(recipes: $recipes, isPresented: $showingGenerator)
            }
            .alert("Daily Recipe Limit Reached", isPresented: $auth.showQuotaModal) {
                Button("Cancel", role: .cancel) { }
                Button("Upgrade to Chef") {
                    auth.loadProduct()
                    auth.showUpgradeModal = true
                }
            } message: {
                Text("You've used your 3 free recipes for today. Upgrade to Chef for unlimited recipe creation.")
            }
            .alert("Upgrade to Chef", isPresented: $auth.showUpgradeModal) {
                if auth.isProcessingPayment {
                    Button("Processing", role: .none) { }
                } else {
                    Button("Cancel", role: .cancel) {
                        auth.showUpgradeModal = false
                        auth.purchaseState = .idle
                    }
                    if auth.product != nil {
                        Button("Upgrade Now") {
                            auth.upgradeToChef()
                        }
                    } else {
                        Button("Retry") {
                            auth.loadProduct()
                        }
                    }
                }
            } message: {
                if auth.isProcessingPayment {
                    Text("Processing your payment...")
                } else if let product = auth.product {
                    Text("Unlock unlimited recipe creation for \(product.displayPrice).")
                } else {
                    Text("Loading pricing...")
                }
            }
            .alert("Delete Recipe", isPresented: $showingDeleteAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    if let recipe = recipeToDelete {
                        deleteRecipe(recipe)
                    }
                }
            } message: {
                Text("Are you sure you want to delete this recipe?")
            }
            .sheet(item: $editingRecipe) { recipe in
                EditRecipeSheet(recipe: recipe, onSave: { updatedRecipe in
                    if let index = recipes.firstIndex(where: { $0.id == updatedRecipe.id }) {
                        recipes[index] = updatedRecipe
                    }
                })
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .alert("Error", isPresented: .constant(auth.appError != nil)) {
                Button("OK") {
                    auth.appError = nil
                }
            } message: {
                if let error = auth.appError {
                    Text(error)
                }
            }
        }
        .onAppear {
            auth.loadProduct()
            loadRecipes()
        }
        .onChange(of: recipes) { _ in
            saveRecipes()
        }
    }
    
    private func loadRecipes() {
        if let data = UserDefaults.standard.data(forKey: recipesKey),
           let decoded = try? JSONDecoder().decode([Recipe].self, from: data) {
            recipes = decoded
        } else {
            recipes = [
                Recipe(
                    title: "Classic Avocado Toast",
                    description: "A quick, creamy, and crispy breakfast favorite.",
                    ingredients: ["1 slice of sourdough bread", "1/2 ripe avocado", "1 tsp chili flakes", "Salt & pepper to taste"],
                    instructions: ["Toast the bread to your desired crispiness.", "Mash the avocado in a bowl with salt and pepper.", "Spread evenly over the toast and top with chili flakes."],
                    prepTime: 5,
                    imageUrl: "https://images.unsplash.com/photo-1541519227354-08fa5d50c44d?q=80&w=600&auto=format&fit=crop",
                    photographerName: "Annie Spratt",
                    photographerUrl: "https://unsplash.com/@anniespratt"
                ),
                Recipe(
                    title: "Quick Garlic Pasta",
                    description: "A simple, comforting Italian dinner made in under 15 minutes.",
                    ingredients: ["200g Spaghetti", "3 cloves garlic, sliced", "2 tbsp olive oil", "Fresh parsley"],
                    instructions: ["Boil pasta in salted water according to package instructions.", "Sauté garlic in olive oil over low heat until golden.", "Toss pasta in the garlic oil and garnish with chopped parsley."],
                    prepTime: 15,
                    imageUrl: "https://images.unsplash.com/photo-1621996346565-e3dbc646d9a9?q=80&w=600&auto=format&fit=crop",
                    photographerName: "Lindsay Almond",
                    photographerUrl: "https://unsplash.com/@lindsayalmond"
                )
            ]
        }
    }
    
    private func saveRecipes() {
        if let encoded = try? JSONEncoder().encode(recipes) {
            UserDefaults.standard.set(encoded, forKey: recipesKey)
        }
    }
    
    private func deleteRecipe(_ recipe: Recipe) {
        recipes.removeAll { $0.id == recipe.id }
    }
    
    private func editRecipe(_ recipe: Recipe) {
        editingRecipe = recipe
        showingEditSheet = true
    }
}

@available(iOS 16.0, *)
struct RecipeDetailView: View {
    let recipe: Recipe
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.brandBg.ignoresSafeArea()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let imageUrl = recipe.imageUrl {
                            AsyncImage(url: URL(string: imageUrl)) { phase in
                                switch phase {
                                case .empty:
                                    Rectangle()
                                        .fill(Color.brandBg)
                                        .frame(height: 240)
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(height: 240)
                                        .clipped()
                                case .failure:
                                    Rectangle()
                                        .fill(Color.brandBg)
                                        .frame(height: 240)
                                        .overlay {
                                            Image(systemName: "photo")
                                                .foregroundColor(.brandSecondary)
                                        }
                                @unknown default:
                                    EmptyView()
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .cornerRadius(24)
                            
                            if let photographerName = recipe.photographerName, let photographerUrl = recipe.photographerUrl {
                                HStack(spacing: 4) {
                                    Text("Photo by")
                                        .font(.caption2)
                                        .foregroundColor(.brandSecondary)
                                    Link(photographerName, destination: URL(string: photographerUrl) ?? URL(string: "https://unsplash.com")!)
                                        .font(.caption2)
                                        .foregroundColor(.brandGold)
                                    Text("on")
                                        .font(.caption2)
                                        .foregroundColor(.brandSecondary)
                                    Link("Unsplash", destination: URL(string: "https://unsplash.com")!)
                                        .font(.caption2)
                                        .foregroundColor(.brandGold)
                                }
                                .padding(.horizontal, 20)
                            }
                        }
                        
                        HStack(spacing: 6) {
                            Image(systemName: "clock")
                                .font(.system(size: 14))
                                .foregroundColor(.brandGold)
                            Text("Ready in \(recipe.prepTime) minutes")
                                .font(.subheadline)
                                .foregroundColor(.brandSecondary)
                        }
                        
                        Text(recipe.description)
                            .font(.body)
                            .foregroundColor(.brandSecondary)
                            .lineSpacing(4)
                        
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Ingredients")
                                .font(.system(.headline, design: .serif))
                                .foregroundColor(.brandText)
                            
                            ForEach(recipe.ingredients, id: \.self) { ingredient in
                                HStack(alignment: .top, spacing: 10) {
                                    Text("•")
                                        .foregroundColor(.brandGold)
                                        .fontWeight(.bold)
                                    Text(ingredient)
                                        .font(.subheadline)
                                        .foregroundColor(.brandText)
                                }
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.brandCard)
                        .cornerRadius(24)
                        .overlay(
                            RoundedRectangle(cornerRadius: 24)
                                .stroke(Color.brandBorder, lineWidth: 1)
                        )
                        
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Instructions")
                                .font(.system(.headline, design: .serif))
                                .foregroundColor(.brandText)
                            
                            ForEach(0..<recipe.instructions.count, id: \.self) { index in
                                HStack(alignment: .top, spacing: 12) {
                                    Text("\(index + 1)")
                                        .font(.subheadline)
                                        .fontWeight(.bold)
                                        .foregroundColor(.brandGold)
                                        .frame(width: 22, height: 22)
                                        .background(Color.brandGoldLight)
                                        .clipShape(Circle())
                                    
                                    Text(recipe.instructions[index])
                                        .font(.subheadline)
                                        .foregroundColor(.brandText)
                                        .lineSpacing(3)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.brandCard)
                        .cornerRadius(24)
                        .overlay(
                            RoundedRectangle(cornerRadius: 24)
                                .stroke(Color.brandBorder, lineWidth: 1)
                        )
                    }
                    .padding()
                }
            }
            .navigationTitle(recipe.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body)
                        .foregroundColor(.brandText)
                }
            }
        }
    }
}

@available(iOS 16.0, *)
struct AIGeneratorView: View {
    @Binding var recipes: [Recipe]
    @Binding var isPresented: Bool
    @EnvironmentObject var auth: SupabaseAuth
    
    @State private var selectedMode: CreationMode = .ai
    @State private var isGenerating = false
    @State private var showNotificationPrompt = false
    @State private var notificationPermissionGranted = false
    
    @State private var cravingInput = ""
    @State private var selectedDietaryRequirements: Set<String> = []
    @State private var customDietaryInput = ""
    @State private var selectedStyle = ""
    @State private var showExpandedStyles = false
    
    @State private var ingredientFields: [String] = [""]
    
    @State private var manualTitle = ""
    @State private var manualDescription = ""
    @State private var manualPrepTime = ""
    @State private var manualStyle = ""
    @State private var manualIngredients: [String] = [""]
    @State private var manualInstructions: [String] = [""]
    
    private let dietaryOptions = [
        ("No Requirements", "checkmark.circle.fill"),
        ("Vegan", "leaf.fill"),
        ("Vegetarian", "carrot.fill"),
        ("Gluten-Free", "wheat"),
        ("Dairy-Free", "cheese"),
        ("Nut-Free", "peanut"),
        ("Kosher", "star.of.life.fill"),
        ("Halal", "crescent.moon.fill"),
        ("Low-Sodium", "drop.slash.fill"),
        ("Sugar-Free", "cube.fill"),
        ("Pescatarian", "fish.fill"),
        ("Paleo", "bone.fill"),
        ("Keto", "flame.fill")
    ]
    
    private let mainStyles = ["Gourmet", "Quick & Easy", "Traditional", "Experimental"]
    
    private let regionalCuisines = ["Italian", "Mexican", "Japanese", "Indian", "Thai", "Chinese", "French", "Greek", "Spanish", "Korean", "Vietnamese", "Moroccan"]
    
    private let cookingMethods = ["Grilled", "Baked", "Fried", "Steamed", "Roasted", "Slow-Cooked", "Air-Fried", "Raw"]
    
    private let mealTypes = ["Breakfast", "Lunch", "Dinner", "Snack", "Dessert", "Appetizer"]
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.brandBg.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        HStack(spacing: 4) {
                            Button(action: { setRecipeCreationMode(.ai) }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 12))
                                    Text("Generate Recipe")
                                        .font(.caption)
                                        .fontWeight(.bold)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 38)
                                .background(selectedMode == .ai ? Color.brandGoldLight : Color.clear)
                                .foregroundColor(selectedMode == .ai ? Color.brandText : Color.brandSecondary)
                                .cornerRadius(10)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selectedMode == .ai ? Color.brandGold.opacity(0.3) : Color.clear, lineWidth: 1))
                            }
                            
                            Button(action: { setRecipeCreationMode(.ingredients) }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "carrot.fill")
                                        .font(.system(size: 12))
                                    Text("Ingredient Only")
                                        .font(.caption)
                                        .fontWeight(.bold)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 38)
                                .background(selectedMode == .ingredients ? Color.brandGoldLight : Color.clear)
                                .foregroundColor(selectedMode == .ingredients ? Color.brandText : Color.brandSecondary)
                                .cornerRadius(10)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selectedMode == .ingredients ? Color.brandGold.opacity(0.3) : Color.clear, lineWidth: 1))
                            }
                            
                            Button(action: { setRecipeCreationMode(.manual) }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 12))
                                    Text("Create Manually")
                                        .font(.caption)
                                        .fontWeight(.bold)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 38)
                                .background(selectedMode == .manual ? Color.brandGoldLight : Color.clear)
                                .foregroundColor(selectedMode == .manual ? Color.brandText : Color.brandSecondary)
                                .cornerRadius(10)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selectedMode == .manual ? Color.brandGold.opacity(0.3) : Color.clear, lineWidth: 1))
                            }
                        }
                        .padding(4)
                        .background(Color.brandCard)
                        .cornerRadius(14)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.brandBorder, lineWidth: 1))
                        .padding(.horizontal)
                        
                        if selectedMode == .ai {
                            aiPromptForm
                        } else if selectedMode == .ingredients {
                            ingredientsIsolationForm
                        } else {
                            manualForm
                        }
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle("Recipe Lab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { isPresented = false }
                        .font(.body)
                        .foregroundColor(.brandSecondary)
                }
            }
        }
    }
    
    private func setRecipeCreationMode(_ mode: CreationMode) {
        selectedMode = mode
    }
    
    private var aiPromptForm: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What are you craving?")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.brandSecondary)
                TextField("e.g. A spicy vegan pasta with summer vegetables", text: $cravingInput)
                    .padding()
                    .background(Color.brandCard)
                    .cornerRadius(14)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.brandBorder, lineWidth: 1))
            }
            .padding(.horizontal)
            
            VStack(alignment: .leading, spacing: 10) {
                Text("Dietary Requirements")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.brandSecondary)
                Text("Select all that apply")
                    .font(.caption2)
                    .foregroundColor(.brandSecondary)
                
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(dietaryOptions, id: \.0) { option in
                        Button(action: {
                            if option.0 == "No Requirements" {
                                selectedDietaryRequirements = ["No Requirements"]
                            } else {
                                selectedDietaryRequirements.remove("No Requirements")
                                if selectedDietaryRequirements.contains(option.0) {
                                    selectedDietaryRequirements.remove(option.0)
                                } else {
                                    selectedDietaryRequirements.insert(option.0)
                                }
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: option.1)
                                    .font(.system(size: 12))
                                Text(option.0)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                if selectedDietaryRequirements.contains(option.0) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(selectedDietaryRequirements.contains(option.0) ? Color.brandGoldLight : Color.brandCard)
                            .foregroundColor(selectedDietaryRequirements.contains(option.0) ? Color.brandText : Color.brandText)
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selectedDietaryRequirements.contains(option.0) ? Color.brandGold : Color.brandBorder, lineWidth: selectedDietaryRequirements.contains(option.0) ? 1 : 1))
                        }
                    }
                }
                
                HStack {
                    Image(systemName: "plus.circle")
                        .foregroundColor(.brandGold)
                    TextField("Add custom dietary requirement...", text: $customDietaryInput)
                        .font(.caption)
                        .onSubmit {
                            if !customDietaryInput.isEmpty {
                                selectedDietaryRequirements.remove("No Requirements")
                                selectedDietaryRequirements.insert(customDietaryInput)
                                customDietaryInput = ""
                            }
                        }
                }
                .padding()
                .background(Color.brandCard)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.brandBorder, lineWidth: 1))
            }
            .padding(.horizontal)
            
            VStack(alignment: .leading, spacing: 10) {
                Text("Cooking Style")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.brandSecondary)
                
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(mainStyles, id: \.self) { style in
                        Button(action: { selectedStyle = style }) {
                            Text(style)
                                .font(.caption)
                                .fontWeight(.medium)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(selectedStyle == style ? Color.brandText : Color.brandCard)
                                .foregroundColor(selectedStyle == style ? .white : Color.brandText)
                                .cornerRadius(10)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.brandBorder, lineWidth: selectedStyle == style ? 0 : 1))
                        }
                    }
                }
                
                Button(action: { showExpandedStyles.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: showExpandedStyles ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12))
                        Text(showExpandedStyles ? "Show less cooking styles" : "Show more cooking styles")
                            .font(.caption)
                            .foregroundColor(.brandGold)
                    }
                }
                
                if showExpandedStyles {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Regional Cuisines")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.brandSecondary)
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                                ForEach(regionalCuisines, id: \.self) { style in
                                    Button(action: { selectedStyle = style }) {
                                        Text(style)
                                            .font(.caption2)
                                            .fontWeight(.medium)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 8)
                                            .background(selectedStyle == style ? Color.brandText : Color.brandCard)
                                            .foregroundColor(selectedStyle == style ? .white : Color.brandText)
                                            .cornerRadius(8)
                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.brandBorder, lineWidth: selectedStyle == style ? 0 : 1))
                                    }
                                }
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Cooking Methods")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.brandSecondary)
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                                ForEach(cookingMethods, id: \.self) { style in
                                    Button(action: { selectedStyle = style }) {
                                        Text(style)
                                            .font(.caption2)
                                            .fontWeight(.medium)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 8)
                                            .background(selectedStyle == style ? Color.brandText : Color.brandCard)
                                            .foregroundColor(selectedStyle == style ? .white : Color.brandText)
                                            .cornerRadius(8)
                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.brandBorder, lineWidth: selectedStyle == style ? 0 : 1))
                                    }
                                }
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Meal Types")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.brandSecondary)
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                                ForEach(mealTypes, id: \.self) { style in
                                    Button(action: { selectedStyle = style }) {
                                        Text(style)
                                            .font(.caption2)
                                            .fontWeight(.medium)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 8)
                                            .background(selectedStyle == style ? Color.brandText : Color.brandCard)
                                            .foregroundColor(selectedStyle == style ? .white : Color.brandText)
                                            .cornerRadius(8)
                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.brandBorder, lineWidth: selectedStyle == style ? 0 : 1))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            
            Button(action: {
                if auth.hasReachedQuota {
                    auth.showQuotaModal = true
                    return
                }
                
                if !auth.notificationsEnabled {
                    showNotificationPrompt = true
                    return
                }
                
                isGenerating = true
                
                Task {
                    let dietaryArray = Array(selectedDietaryRequirements)
                    if let generatedRecipe = await auth.generateRecipe(
                        prompt: cravingInput.isEmpty ? "a delicious recipe" : cravingInput,
                        dietary: dietaryArray,
                        style: selectedStyle.isEmpty ? "home cooking" : selectedStyle
                    ) {
                        await MainActor.run {
                            recipes.append(generatedRecipe)
                            auth.incrementRecipeCount()
                            auth.sendRecipeNotification(recipeTitle: generatedRecipe.title)
                            isPresented = false
                            isGenerating = false
                        }
                    } else {
                        await MainActor.run {
                            isGenerating = false
                        }
                    }
                }
            }) {
                HStack {
                    if isGenerating {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    }
                    Text(isGenerating ? "Generating..." : "Generate Recipe")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .buttonStyle(.borderedProminent)
            }
            .disabled(cravingInput.isEmpty || isGenerating)
            .padding(.horizontal)
            .padding(.top, 10)
        }
        .alert("Get Notified", isPresented: $showNotificationPrompt) {
            Button("Not Now") {
                isGenerating = true
                Task {
                    let dietaryArray = Array(selectedDietaryRequirements)
                    if let generatedRecipe = await auth.generateRecipe(
                        prompt: cravingInput.isEmpty ? "a delicious recipe" : cravingInput,
                        dietary: dietaryArray,
                        style: selectedStyle.isEmpty ? "home cooking" : selectedStyle
                    ) {
                        await MainActor.run {
                            recipes.append(generatedRecipe)
                            auth.incrementRecipeCount()
                            isPresented = false
                            isGenerating = false
                        }
                    } else {
                        await MainActor.run {
                            isGenerating = false
                        }
                    }
                }
            }
            Button("Enable Notifications") {
                auth.requestNotificationPermission()
                showNotificationPrompt = false
                isGenerating = true
                Task {
                    let dietaryArray = Array(selectedDietaryRequirements)
                    if let generatedRecipe = await auth.generateRecipe(
                        prompt: cravingInput.isEmpty ? "a delicious recipe" : cravingInput,
                        dietary: dietaryArray,
                        style: selectedStyle.isEmpty ? "home cooking" : selectedStyle
                    ) {
                        await MainActor.run {
                            recipes.append(generatedRecipe)
                            auth.incrementRecipeCount()
                            auth.sendRecipeNotification(recipeTitle: generatedRecipe.title)
                            isPresented = false
                            isGenerating = false
                        }
                    } else {
                        await MainActor.run {
                            isGenerating = false
                        }
                    }
                }
            }
        } message: {
            if notificationPermissionGranted {
                Text("We'll notify you when your recipe is ready. Feel free to leave the app while we work our magic!")
            } else {
                Text("Want to leave the app but still know when your recipe is ready? Enable notifications to get alerted when it's done.")
            }
        }
    }
    
    private var ingredientsIsolationForm: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Isolate Available Ingredients")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.brandSecondary)
                
                ForEach(0..<ingredientFields.count, id: \.self) { index in
                    HStack {
                        TextField("e.g. 2 eggs or chicken breast", text: $ingredientFields[index])
                            .padding()
                            .background(Color.brandCard)
                            .cornerRadius(12)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.brandBorder, lineWidth: 1))
                        
                        if ingredientFields.count > 1 {
                            Button(action: { ingredientFields.remove(at: index) }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                                    .padding(.horizontal, 8)
                            }
                        }
                    }
                }
                
                Button(action: { addAvailableIngredientField() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12))
                        Text("Add Ingredient")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.brandGold)
                }
            }
            .padding(.horizontal)
            
            Button(action: {
                if auth.hasReachedQuota {
                    auth.showQuotaModal = true
                    return
                }
                
                if !auth.notificationsEnabled {
                    showNotificationPrompt = true
                    return
                }
                
                let filteredIngredients = ingredientFields.filter { !$0.isEmpty }
                
                Task {
                    let imageUrl = await auth.fetchFoodImage(query: filteredIngredients.first ?? "food")
                    
                    await MainActor.run {
                        let newRecipe = Recipe(
                            title: "Ingredient-Based Creation",
                            description: "A recipe crafted from your available ingredients: \(filteredIngredients.joined(separator: ", ")).",
                            ingredients: filteredIngredients.isEmpty ? ["Available ingredients"] : filteredIngredients,
                            instructions: ["Prepare your ingredients.", "Follow cooking instructions tailored to your available items."],
                            prepTime: 20,
                            imageUrl: imageUrl,
                            photographerName: "Unsplash",
                            photographerUrl: "https://unsplash.com"
                        )
                        recipes.append(newRecipe)
                        auth.incrementRecipeCount()
                        auth.sendRecipeNotification(recipeTitle: newRecipe.title)
                        isPresented = false
                    }
                }
            }) {
                Text("Generate Recipe from Ingredients")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
        }
        .alert("Get Notified", isPresented: $showNotificationPrompt) {
            Button("Not Now") {
                let filteredIngredients = ingredientFields.filter { !$0.isEmpty }
                Task {
                    let imageUrl = await auth.fetchFoodImage(query: filteredIngredients.first ?? "food")
                    await MainActor.run {
                        let newRecipe = Recipe(
                            title: "Ingredient-Based Creation",
                            description: "A recipe crafted from your available ingredients: \(filteredIngredients.joined(separator: ", ")).",
                            ingredients: filteredIngredients.isEmpty ? ["Available ingredients"] : filteredIngredients,
                            instructions: ["Prepare your ingredients.", "Follow cooking instructions tailored to your available items."],
                            prepTime: 20,
                            imageUrl: imageUrl,
                            photographerName: "Unsplash",
                            photographerUrl: "https://unsplash.com"
                        )
                        recipes.append(newRecipe)
                        auth.incrementRecipeCount()
                        isPresented = false
                    }
                }
            }
            Button("Enable Notifications") {
                auth.requestNotificationPermission()
                showNotificationPrompt = false
                let filteredIngredients = ingredientFields.filter { !$0.isEmpty }
                Task {
                    let imageUrl = await auth.fetchFoodImage(query: filteredIngredients.first ?? "food")
                    await MainActor.run {
                        let newRecipe = Recipe(
                            title: "Ingredient-Based Creation",
                            description: "A recipe crafted from your available ingredients: \(filteredIngredients.joined(separator: ", ")).",
                            ingredients: filteredIngredients.isEmpty ? ["Available ingredients"] : filteredIngredients,
                            instructions: ["Prepare your ingredients.", "Follow cooking instructions tailored to your available items."],
                            prepTime: 20,
                            imageUrl: imageUrl,
                            photographerName: "Unsplash",
                            photographerUrl: "https://unsplash.com"
                        )
                        recipes.append(newRecipe)
                        auth.incrementRecipeCount()
                        auth.sendRecipeNotification(recipeTitle: newRecipe.title)
                        isPresented = false
                    }
                }
            }
        } message: {
            if notificationPermissionGranted {
                Text("We'll notify you when your recipe is ready. Feel free to leave the app while we work our magic!")
            } else {
                Text("Want to leave the app but still know when your recipe is ready? Enable notifications to get alerted when it's done.")
            }
        }
    }
    
    private func addAvailableIngredientField() {
        ingredientFields.append("")
    }
    
    private var manualForm: some View {
        VStack(spacing: 20) {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recipe Title")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.brandSecondary)
                    TextField("e.g. Spicy Thai Basil Stir Fry", text: $manualTitle)
                        .padding()
                        .background(Color.brandCard)
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.brandBorder, lineWidth: 1))
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cooking Style")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.brandSecondary)
                    Picker("", selection: $manualStyle) {
                        Text("Select a style...").tag("")
                        Text("Gourmet").tag("Gourmet")
                        Text("Quick & Easy").tag("Quick & Easy")
                        Text("Traditional").tag("Traditional")
                        Text("Experimental").tag("Experimental")
                        Text("Italian").tag("Italian")
                        Text("Mexican").tag("Mexican")
                        Text("Asian").tag("Asian")
                        Text("Mediterranean").tag("Mediterranean")
                    }
                    .pickerStyle(MenuPickerStyle())
                    .padding()
                    .background(Color.brandCard)
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.brandBorder, lineWidth: 1))
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("Short Description Summary")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.brandSecondary)
                    TextField("Brief description of your recipe", text: $manualDescription)
                        .padding()
                        .background(Color.brandCard)
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.brandBorder, lineWidth: 1))
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cooking Time (minutes)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.brandSecondary)
                    TextField("e.g. 30", text: $manualPrepTime)
                        .keyboardType(.numberPad)
                        .padding()
                        .background(Color.brandCard)
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.brandBorder, lineWidth: 1))
                }
            }
            .padding(.horizontal)
            
            VStack(alignment: .leading, spacing: 10) {
                Text("Ingredients List")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.brandSecondary)
                
                ForEach(0..<manualIngredients.count, id: \.self) { index in
                    HStack {
                        TextField("Ingredient requirement", text: $manualIngredients[index])
                            .padding()
                            .background(Color.brandCard)
                            .cornerRadius(12)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.brandBorder, lineWidth: 1))
                        
                        if manualIngredients.count > 1 {
                            Button(action: { manualIngredients.remove(at: index) }) {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .padding(.leading, 4)
                        }
                    }
                }
                
                Button(action: { manualIngredients.append("") }) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12))
                        Text("Add Ingredient")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.brandGold)
                }
            }
            .padding(.horizontal)
            
            VStack(alignment: .leading, spacing: 10) {
                Text("Directional Instructions")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.brandSecondary)
                
                ForEach(0..<manualInstructions.count, id: \.self) { index in
                    HStack {
                        TextField("Step instruction", text: $manualInstructions[index])
                            .padding()
                            .background(Color.brandCard)
                            .cornerRadius(12)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.brandBorder, lineWidth: 1))
                        
                        if manualInstructions.count > 1 {
                            Button(action: { manualInstructions.remove(at: index) }) {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .padding(.leading, 4)
                        }
                    }
                }
                
                Button(action: { manualInstructions.append("") }) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12))
                        Text("Add Step")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.brandGold)
                }
            }
            .padding(.horizontal)
            
            Button(action: {
                if auth.hasReachedQuota {
                    auth.showQuotaModal = true
                    return
                }
                
                if !auth.notificationsEnabled {
                    showNotificationPrompt = true
                    return
                }
                
                let calculatedTime = Int(manualPrepTime) ?? 10
                
                Task {
                    let imageUrl = await auth.fetchFoodImage(query: manualTitle.isEmpty ? "food" : manualTitle)
                    
                    await MainActor.run {
                        let newRecipe = Recipe(
                            title: manualTitle.isEmpty ? "Custom Created Recipe" : manualTitle,
                            description: manualDescription.isEmpty ? "Manually documented cookbook creation." : manualDescription,
                            ingredients: manualIngredients.filter { !$0.isEmpty },
                            instructions: manualInstructions.filter { !$0.isEmpty },
                            prepTime: calculatedTime,
                            imageUrl: imageUrl,
                            photographerName: "Unsplash",
                            photographerUrl: "https://unsplash.com"
                        )
                        recipes.append(newRecipe)
                        auth.incrementRecipeCount()
                        auth.sendRecipeNotification(recipeTitle: newRecipe.title)
                        isPresented = false
                    }
                }
            }) {
                Text("Save Recipe")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .buttonStyle(.borderedProminent)
            }
            .disabled(manualTitle.isEmpty)
            .padding(.horizontal)
        }
        .alert("Get Notified", isPresented: $showNotificationPrompt) {
            Button("Not Now") {
                let calculatedTime = Int(manualPrepTime) ?? 10
                Task {
                    let imageUrl = await auth.fetchFoodImage(query: manualTitle.isEmpty ? "food" : manualTitle)
                    await MainActor.run {
                        let newRecipe = Recipe(
                            title: manualTitle.isEmpty ? "Custom Created Recipe" : manualTitle,
                            description: manualDescription.isEmpty ? "Manually documented cookbook creation." : manualDescription,
                            ingredients: manualIngredients.filter { !$0.isEmpty },
                            instructions: manualInstructions.filter { !$0.isEmpty },
                            prepTime: calculatedTime,
                            imageUrl: imageUrl,
                            photographerName: "Unsplash",
                            photographerUrl: "https://unsplash.com"
                        )
                        recipes.append(newRecipe)
                        auth.incrementRecipeCount()
                        isPresented = false
                    }
                }
            }
            Button("Enable Notifications") {
                auth.requestNotificationPermission()
                showNotificationPrompt = false
                let calculatedTime = Int(manualPrepTime) ?? 10
                Task {
                    let imageUrl = await auth.fetchFoodImage(query: manualTitle.isEmpty ? "food" : manualTitle)
                    await MainActor.run {
                        let newRecipe = Recipe(
                            title: manualTitle.isEmpty ? "Custom Created Recipe" : manualTitle,
                            description: manualDescription.isEmpty ? "Manually documented cookbook creation." : manualDescription,
                            ingredients: manualIngredients.filter { !$0.isEmpty },
                            instructions: manualInstructions.filter { !$0.isEmpty },
                            prepTime: calculatedTime,
                            imageUrl: imageUrl,
                            photographerName: "Unsplash",
                            photographerUrl: "https://unsplash.com"
                        )
                        recipes.append(newRecipe)
                        auth.incrementRecipeCount()
                        auth.sendRecipeNotification(recipeTitle: newRecipe.title)
                        isPresented = false
                    }
                }
            }
        } message: {
            if notificationPermissionGranted {
                Text("We'll notify you when your recipe is ready. Feel free to leave the app while we work our magic!")
            } else {
                Text("Want to leave the app but still know when your recipe is ready? Enable notifications to get alerted when it's done.")
            }
        }
    }
}

@available(iOS 16.0, *)
struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var auth: SupabaseAuth
    @State private var showingAcknowledgments = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.brandBg.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    List {
                        Section {
                            HStack {
                                Image(systemName: "bell.fill")
                                    .foregroundColor(.brandGold)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Notifications")
                                        .font(.body)
                                        .foregroundColor(.brandText)
                                    Text("Get notified when recipes are ready")
                                        .font(.caption)
                                        .foregroundColor(.brandSecondary)
                                }
                                Spacer()
                                Toggle("", isOn: $auth.notificationsEnabled)
                                    .onChange(of: auth.notificationsEnabled) { newValue in
                                        if newValue {
                                            auth.requestNotificationPermission()
                                        }
                                    }
                            }
                            .padding(.vertical, 8)
                        }
                        .listRowBackground(Color.brandCard)
                        .listRowSeparator(.hidden)
                        
                        Section {
                            HStack {
                                Image(systemName: "star.fill")
                                    .foregroundColor(.brandGold)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Upgrade to Chef")
                                        .font(.body)
                                        .foregroundColor(.brandText)
                                    Text("Unlimited recipe creation")
                                        .font(.caption)
                                        .foregroundColor(.brandSecondary)
                                }
                                Spacer()
                                if auth.isChef {
                                    Text("Active")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.brandGold)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.brandGoldLight)
                                        .cornerRadius(12)
                                } else {
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.brandSecondary)
                                        .font(.system(size: 14))
                                }
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if !auth.isChef {
                                    auth.showUpgradeModal = true
                                }
                            }
                        }
                        .listRowBackground(Color.brandCard)
                        .listRowSeparator(.hidden)
                        
                        Section {
                            HStack {
                                Image(systemName: "info.circle.fill")
                                    .foregroundColor(.brandGold)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Acknowledgments")
                                        .font(.body)
                                        .foregroundColor(.brandText)
                                    Text("Licenses and attributions")
                                        .font(.caption)
                                        .foregroundColor(.brandSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.brandSecondary)
                                    .font(.system(size: 14))
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                showingAcknowledgments = true
                            }
                        }
                        .listRowBackground(Color.brandCard)
                        .listRowSeparator(.hidden)
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.body)
                    .foregroundColor(.brandText)
                }
            }
            .sheet(isPresented: $auth.showUpgradeModal) {
                UpgradeModal()
            }
            .sheet(isPresented: $showingAcknowledgments) {
                AcknowledgmentsView()
            }
        }
    }
}

@available(iOS 16.0, *)
struct UpgradeModal: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var auth: SupabaseAuth
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
                .onTapGesture {
                    dismiss()
                }
            
            VStack(spacing: 24) {
                VStack(spacing: 16) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.brandGold)
                    
                    Text("Upgrade to Chef")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.brandText)
                    
                    Text("Unlock unlimited recipe creation and support the development of Cookery.")
                        .font(.body)
                        .foregroundColor(.brandSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                }
                .padding(24)
                
                VStack(spacing: 12) {
                    if auth.isProcessingPayment {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .brandGold))
                        Text("Processing your payment...")
                            .font(.caption)
                            .foregroundColor(.brandSecondary)
                    } else if let product = auth.product {
                        Text("Unlock unlimited recipe creation for \(product.displayPrice).")
                            .font(.body)
                            .foregroundColor(.brandText)
                    } else {
                        Text("Loading pricing...")
                            .font(.body)
                            .foregroundColor(.brandSecondary)
                    }
                }
                .padding(.horizontal, 24)
                
                HStack(spacing: 12) {
                    Button("Cancel") {
                        auth.showUpgradeModal = false
                        auth.purchaseState = .idle
                    }
                    .font(.body)
                    .foregroundColor(.brandSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.brandCard)
                    .cornerRadius(12)
                    
                    if auth.product != nil {
                        Button("Upgrade Now") {
                            auth.upgradeToChef()
                        }
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.brandText)
                        .cornerRadius(12)
                    } else {
                        Button("Retry") {
                            auth.loadProduct()
                        }
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.brandText)
                        .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .background(Color.brandCard)
            .cornerRadius(24)
            .padding(.horizontal, 32)
        }
    }
}

@available(iOS 16.0, *)
struct AcknowledgmentsView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.openURL) var openURL
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.brandBg.ignoresSafeArea()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Acknowledgments")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.brandText)
                            
                            Text("Cookery uses the following open-source libraries and services:")
                                .font(.body)
                                .foregroundColor(.brandSecondary)
                        }
                        .padding(.horizontal)
                        
                        VStack(spacing: 16) {
                            AcknowledgmentCard(
                                name: "SwiftUI",
                                description: "Apple's declarative UI framework",
                                license: "Apple License",
                                url: "https://developer.apple.com/documentation/swiftui"
                            )
                            
                            AcknowledgmentCard(
                                name: "StoreKit",
                                description: "Apple's in-app purchase framework",
                                license: "Apple License",
                                url: "https://developer.apple.com/documentation/storekit"
                            )
                            
                            AcknowledgmentCard(
                                name: "UserNotifications",
                                description: "Apple's notification framework",
                                license: "Apple License",
                                url: "https://developer.apple.com/documentation/usernotifications"
                            )
                            
                            AcknowledgmentCard(
                                name: "Unsplash API",
                                description: "Free high-quality photos",
                                license: "Unsplash License",
                                url: "https://unsplash.com/license"
                            )
                            
                            AcknowledgmentCard(
                                name: "Google AI Studio",
                                description: "AI-powered recipe generation",
                                license: "Google Terms of Service",
                                url: "https://ai.google.dev/terms"
                            )
                            
                            AcknowledgmentCard(
                                name: "Supabase",
                                description: "Backend-as-a-Service platform",
                                license: "MIT License",
                                url: "https://github.com/supabase/supabase"
                            )
                        }
                        .padding(.horizontal)
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle("Licenses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.body)
                    .foregroundColor(.brandText)
                }
            }
        }
    }
}

struct AcknowledgmentCard: View {
    let name: String
    let description: String
    let license: String
    let url: String
    @Environment(\.openURL) var openURL
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.headline)
                        .foregroundColor(.brandText)
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.brandSecondary)
                }
                Spacer()
                Button(action: {
                    if let url = URL(string: url) {
                        openURL(url)
                    }
                }) {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundColor(.brandGold)
                        .font(.system(size: 20))
                }
            }
            
            HStack {
                Text(license)
                    .font(.caption2)
                    .foregroundColor(.brandSecondary)
                Spacer()
            }
        }
        .padding(16)
        .background(Color.brandCard)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.brandBorder, lineWidth: 1)
        )
    }
}

@available(iOS 16.0, *)
struct EditRecipeSheet: View {
    @Environment(\.dismiss) var dismiss
    let recipe: Recipe
    let onSave: (Recipe) -> Void
    
    @State private var title: String
    @State private var description: String
    @State private var ingredients: [String]
    @State private var instructions: [String]
    @State private var prepTime: String
    
    init(recipe: Recipe, onSave: @escaping (Recipe) -> Void) {
        self.recipe = recipe
        self.onSave = onSave
        self._title = State(initialValue: recipe.title)
        self._description = State(initialValue: recipe.description)
        self._ingredients = State(initialValue: recipe.ingredients)
        self._instructions = State(initialValue: recipe.instructions)
        self._prepTime = State(initialValue: String(recipe.prepTime))
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.brandBg.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Recipe Title")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.brandSecondary)
                            TextField("Recipe name", text: $title)
                                .padding()
                                .background(Color.brandCard)
                                .cornerRadius(12)
                        }
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Description")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.brandSecondary)
                            TextField("Brief description", text: $description)
                                .padding()
                                .background(Color.brandCard)
                                .cornerRadius(12)
                        }
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Prep Time (minutes)")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.brandSecondary)
                            TextField("30", text: $prepTime)
                                .keyboardType(.numberPad)
                                .padding()
                                .background(Color.brandCard)
                                .cornerRadius(12)
                        }
                        
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Ingredients")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.brandSecondary)
                            
                            ForEach(0..<ingredients.count, id: \.self) { index in
                                HStack {
                                    TextField("Ingredient", text: $ingredients[index])
                                        .padding()
                                        .background(Color.brandCard)
                                        .cornerRadius(12)
                                    Button(action: { ingredients.remove(at: index) }) {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundColor(.red)
                                    }
                                }
                            }
                            
                            Button(action: { ingredients.append("") }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 12))
                                    Text("Add Ingredient")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                }
                                .foregroundColor(.brandGold)
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Instructions")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.brandSecondary)
                            
                            ForEach(0..<instructions.count, id: \.self) { index in
                                HStack {
                                    TextField("Step", text: $instructions[index])
                                        .padding()
                                        .background(Color.brandCard)
                                        .cornerRadius(12)
                                    Button(action: { instructions.remove(at: index) }) {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundColor(.red)
                                    }
                                }
                            }
                            
                            Button(action: { instructions.append("") }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 12))
                                    Text("Add Step")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                }
                                .foregroundColor(.brandGold)
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Edit Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        let updatedRecipe = Recipe(
                            id: recipe.id,
                            title: title.isEmpty ? recipe.title : title,
                            description: description.isEmpty ? recipe.description : description,
                            ingredients: ingredients.filter { !$0.isEmpty },
                            instructions: instructions.filter { !$0.isEmpty },
                            prepTime: Int(prepTime) ?? recipe.prepTime,
                            imageUrl: recipe.imageUrl,
                            photographerName: recipe.photographerName,
                            photographerUrl: recipe.photographerUrl
                        )
                        onSave(updatedRecipe)
                        dismiss()
                    }
                    .disabled(title.isEmpty)
                }
            }
        }
    }
}