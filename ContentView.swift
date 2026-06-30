import SwiftUI
import StoreKit

extension Color {
    static let brandBg = Color(red: 250/255, green: 248/255, blue: 245/255)
    static let brandCard = Color.white
    static let brandText = Color(red: 43/255, green: 32/255, blue: 11/255)
    static let brandSecondary = Color(red: 120/255, green: 110/255, blue: 95/255)
    static let brandGold = Color(red: 226/255, green: 179/255, blue: 60/255)
    static let brandGoldLight = Color(red: 253/255, green: 251/255, blue: 235/255)
    static let brandBorder = Color(red: 230/255, green: 225/255, blue: 218/255)
}

struct Recipe: Identifiable {
    let id = UUID()
    let title: String
    let description: String
    let ingredients: [String]
    let instructions: [String]
    let prepTime: Int
    let imageUrl: String?
    let photographerName: String?
    let photographerUrl: String?
}

enum CreationMode {
    case ai, ingredients, manual
}

class SupabaseAuth: ObservableObject {
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
    
    private let projectUrl = "https://ojvigxnwweixjhugekmm.supabase.co"
    private let apiKey = "sb_publishable_ok_vkZ1FDJ_hv-qdv76tJw_RJ78nd6W"
    private let dailyQuota = 3
    private let chefProductId = "com.cookery.chef.upgrade"
    private var updateListenerTask: Task<Void, Error>? = nil
    
    enum PurchaseState {
        case idle
        case purchasing
        case purchased
        case failed(String)
    }
    
    init() {
        updateListenerTask = listenForTransactions()
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
    }
    
    func loadProduct() {
        Task {
            do {
                let products = try await Product.products(for: [chefProductId])
                if let product = products.first {
                    DispatchQueue.main.async {
                        self.product = product
                    }
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
    
    private func checkVerified<T>(_ verification: Verification<T>) throws -> T {
        switch verification {
        case .unverified:
            throw PurchaseError.failedVerification
        case .verified(let safe):
            return safe
        }
    }
    
    private func listenForTransactions() -> Task<Void, Error> {
        return Task.detached {
            for await result in Transaction.updates {
                await self.handleTransaction(result)
            }
        }
    }
    
    private func handleTransaction(_ result: VerificationResult<Transaction>) async {
        let transaction = try? checkVerified(result)
        
        guard let transaction = transaction else {
            return
        }
        
        if transaction.productID == chefProductId {
            await MainActor.run {
                self.isChef = true
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
    }
}

@main
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
    
    var body: some View {
        ZStack {
            Color.brandBg.ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 24) {
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
                                Text("Cookery")
                                    .font(.system(.largeTitle, design: .serif))
                                    .fontWeight(.bold)
                                    .foregroundColor(.brandText)
                                Text("Welcome to the future of recipes.")
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
                    .padding(.top, 20)
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
                            .background(email.isEmpty || password.isEmpty ? Color.brandSecondary.opacity(0.5) : Color.brandText)
                            .cornerRadius(16)
                        }
                        .disabled(email.isEmpty || password.isEmpty || auth.isLoading)
                        
                        Button(action: { isSignUpMode.toggle() }) {
                            Text(isSignUpMode ? "Already have an account? Sign In" : "Don't have an account? Sign Up")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(Color.brandGold)
                                .padding(.vertical, 8)
                        }
                        
                        Button(action: { auth.isAuthenticated = true }) {
                            Text("Try without an account")
                                .font(.caption)
                                .foregroundColor(.brandSecondary)
                                .padding(.top, 8)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}

@main
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

struct ContentView: View {
    @EnvironmentObject var auth: SupabaseAuth
    @State private var recipes: [Recipe] = [
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
    
    @State private var selectedRecipe: Recipe? = nil
    @State private var showingGenerator = false
    
    var body: some View {
        NavigationView {
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
                            .background(Color.brandText)
                            .cornerRadius(16)
                            .shadow(color: Color.brandText.opacity(0.1), radius: 8, x: 0, y: 4)
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
                    if let product = auth.product {
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
        }
        .onAppear {
            auth.loadProduct()
        }
    }
}

struct RecipeDetailView: View {
    let recipe: Recipe
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
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

struct AIGeneratorView: View {
    @Binding var recipes: [Recipe]
    @Binding var isPresented: Bool
    @EnvironmentObject var auth: SupabaseAuth
    
    @State private var selectedMode: CreationMode = .ai
    
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
        NavigationView {
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
                
                let generatedTitle = cravingInput.isEmpty ? "AI Generated Recipe" : cravingInput
                let dietaryText = selectedDietaryRequirements.isEmpty ? "No specific dietary requirements" : selectedDietaryRequirements.joined(separator: ", ")
                let randomImageId = ["1541519227354-08fa5d50c44d", "1621996346565-e3dbc646d9a9", "1495195129352-aec325b55b65", "1504674900247-97ec8e7455f2"].randomElement() ?? "1541519227354-08fa5d50c44d"
                let newRecipe = Recipe(
                    title: generatedTitle,
                    description: "AI tailored recipe with \(selectedStyle) style. Dietary considerations: \(dietaryText).",
                    ingredients: ["AI-selected ingredients based on your preferences"],
                    instructions: ["Follow AI-generated steps tailored to your craving and dietary needs."],
                    prepTime: 25,
                    imageUrl: "https://images.unsplash.com/photo-\(randomImageId)?q=80&w=600&auto=format&fit=crop",
                    photographerName: "Unsplash",
                    photographerUrl: "https://unsplash.com"
                )
                recipes.append(newRecipe)
                auth.incrementRecipeCount()
                isPresented = false
            }) {
                Text("Generate Recipe")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(cravingInput.isEmpty ? Color.brandSecondary.opacity(0.4) : Color.brandText)
                    .cornerRadius(16)
            }
            .disabled(cravingInput.isEmpty)
            .padding(.horizontal)
            .padding(.top, 10)
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
                
                let filteredIngredients = ingredientFields.filter { !$0.isEmpty }
                let randomImageId = ["1541519227354-08fa5d50c44d", "1621996346565-e3dbc646d9a9", "1495195129352-aec325b55b65", "1504674900247-97ec8e7455f2"].randomElement() ?? "1541519227354-08fa5d50c44d"
                let newRecipe = Recipe(
                    title: "Ingredient-Based Creation",
                    description: "A recipe crafted from your available ingredients: \(filteredIngredients.joined(separator: ", ")).",
                    ingredients: filteredIngredients.isEmpty ? ["Available ingredients"] : filteredIngredients,
                    instructions: ["Prepare your ingredients.", "Follow cooking instructions tailored to your available items."],
                    prepTime: 20,
                    imageUrl: "https://images.unsplash.com/photo-\(randomImageId)?q=80&w=600&auto=format&fit=crop",
                    photographerName: "Unsplash",
                    photographerUrl: "https://unsplash.com"
                )
                recipes.append(newRecipe)
                auth.incrementRecipeCount()
                isPresented = false
            }) {
                Text("Generate Recipe from Ingredients")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.brandText)
                    .cornerRadius(16)
            }
            .padding(.horizontal)
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
                
                let calculatedTime = Int(manualPrepTime) ?? 10
                let randomImageId = ["1541519227354-08fa5d50c44d", "1621996346565-e3dbc646d9a9", "1495195129352-aec325b55b65", "1504674900247-97ec8e7455f2"].randomElement() ?? "1541519227354-08fa5d50c44d"
                let newRecipe = Recipe(
                    title: manualTitle.isEmpty ? "Custom Created Recipe" : manualTitle,
                    description: manualDescription.isEmpty ? "Manually documented cookbook creation." : manualDescription,
                    ingredients: manualIngredients.filter { !$0.isEmpty },
                    instructions: manualInstructions.filter { !$0.isEmpty },
                    prepTime: calculatedTime,
                    imageUrl: "https://images.unsplash.com/photo-\(randomImageId)?q=80&w=600&auto=format&fit=crop",
                    photographerName: "Unsplash",
                    photographerUrl: "https://unsplash.com"
                )
                recipes.append(newRecipe)
                auth.incrementRecipeCount()
                isPresented = false
            }) {
                Text("Save Recipe")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(manualTitle.isEmpty ? Color.brandSecondary.opacity(0.4) : Color.brandText)
                    .cornerRadius(16)
            }
            .disabled(manualTitle.isEmpty)
            .padding(.horizontal)
        }
    }
}