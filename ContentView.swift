import SwiftUI

// MARK: - Models
struct Recipe: Identifiable {
    let id = UUID()
    let title: String
    let description: String
    let ingredients: [String]
    let instructions: [String]
    let prepTime: Int
}

// MARK: - App Entry Point
@main
struct CookeryAIApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - Main Interface
struct ContentView: View {
    @State private var recipes: [Recipe] = [
        Recipe(
            title: "Classic Avocado Toast",
            description: "A quick, creamy, and crispy breakfast favorite.",
            ingredients: ["1 slice of sourdough bread", "1/2 ripe avocado", "1 tsp chili flakes", "Salt & pepper to taste"],
            instructions: ["Toast the bread to your desired crispiness.", "Mash the avocado in a bowl with salt and pepper.", "Spread evenly over the toast and top with chili flakes."],
            prepTime: 5
        ),
        Recipe(
            title: "Quick Garlic Pasta",
            description: "A simple, comforting Italian dinner made in under 15 minutes.",
            ingredients: ["200g Spaghetti", "3 cloves garlic, sliced", "2 tbsp olive oil", "Fresh parsley"],
            instructions: ["Boil pasta in salted water according to package instructions.", "Sauté garlic in olive oil over low heat until golden.", "Toss pasta in the garlic oil and garnish with chopped parsley."],
            prepTime: 15
        )
    ]
    
    @State private var selectedRecipe: Recipe? = nil
    @State private var showingGenerator = false
    @State private var ingredientInput = ""
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Cookery AI")
                                .font(.system(.largeTitle, design: .rounded))
                                .bold()
                            Text("Your minimalist cooking assistant")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    
                    Button(action: { showingGenerator = true }) {
                        HStack {
                            Image(systemName: "sparkles")
                            Text("Generate with AI")
                                .font(.headline)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.blue)
                        .cornerRadius(12)
                    }
                    .padding(.horizontal)
                    
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Your Recipes")
                            .font(.title2)
                            .bold()
                            .padding(.horizontal)
                        
                        ForEach(recipes) { recipe in
                            Button(action: { selectedRecipe = recipe }) {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(recipe.title)
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Text("\(recipe.prepTime) mins")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color(.systemGray5))
                                            .cornerRadius(6)
                                    }
                                    Text(recipe.description)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.systemGray6))
                                .cornerRadius(12)
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationBarHidden(true)
            .sheet(item: $selectedRecipe) { recipe in
                RecipeDetailView(recipe: recipe)
            }
            .sheet(isPresented: $showingGenerator) {
                AIGeneratorView(recipes: $recipes, isPresented: $showingGenerator)
            }
        }
    }
}

// MARK: - Detail View
struct RecipeDetailView: View {
    let recipe: Recipe
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Image(systemName: "clock")
                            .foregroundColor(.secondary)
                        Text("Ready in \(recipe.prepTime) minutes")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Text(recipe.description)
                        .font(.body)
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Ingredients")
                            .font(.headline)
                        ForEach(recipe.ingredients, id: \.self) { ingredient in
                            HStack(alignment: .top) {
                                Text("•")
                                Text(ingredient)
                            }
                            .font(.subheadline)
                        }
                    }
                    
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Instructions")
                            .font(.headline)
                        ForEach(0..<recipe.instructions.count, id: \.self) { index in
                            HStack(alignment: .top) {
                                Text("\(index + 1).")
                                    .bold()
                                    .foregroundColor(.blue)
                                Text(recipe.instructions[index])
                            }
                            .font(.subheadline)
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(recipe.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - AI Generator View
struct AIGeneratorView: View {
    @Binding var recipes: [Recipe]
    @Binding var isPresented: Bool
    @State private var ingredients = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("What's in your fridge?")) {
                    TextField("Ingredients (e.g., eggs, tomato, cheese)", text: $ingredients)
                }
                
                Button(action: {
                    let newRecipe = Recipe(
                        title: "AI Generated Meal",
                        description: "A custom creation using your ingredients.",
                        ingredients: ingredients.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                        instructions: ["Combine the ingredients.", "Cook thoroughly.", "Serve hot."],
                        prepTime: 10
                    )
                    recipes.append(newRecipe)
                    isPresented = false
                }) {
                    Text("Generate Recipe")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .disabled(ingredients.isEmpty)
            }
            .navigationTitle("AI Recipe Creator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }
}