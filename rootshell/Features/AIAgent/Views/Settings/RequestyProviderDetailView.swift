#if !CHINA_BUILD
//
//  RequestyProviderDetailView.swift
//  rootshell
//
//  Detail view for configuring Requesty provider with model discovery and favorites
//

import SwiftUI

struct RequestyProviderDetailView: View {
    private var credentialsManager: AICredentialsManager { AICredentialsManager.shared }

    @State private var apiKeyInput = ""
    @State private var showKey = false
    @State private var saveError: String?
    @State private var showDeleteConfirmation = false

    // Model discovery state
    @State private var isDiscoveringModels = false
    @State private var discoveryError: String?

    // Search & Filter state
    @State private var searchText = ""
    @State private var selectedProvider: String? = nil
    @State private var selectedTier: AIProviderModel.ModelTier? = nil
    @State private var showOnlyManaged = false

    // Pagination
    @State private var displayedModelCount = 50

    // Temperature state
    @State private var temperature: Double = 0.4
    @State private var isUsingDefaultTemperature = true

    var body: some View {
        List {
            apiKeySection

            if credentialsManager.hasRequestyAPIKey {
                favoriteModelsSection
                temperatureSection

                Section("Browse Models") {
                    filterControlsSection
                }

                filteredModelsSection

                deleteSection
            }
        }
        .themedList()
        .onAppear {
            loadTemperature()
        }
        .navigationTitle("Requesty")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search models...")
        .onChange(of: searchText) {
            // Reset pagination when search changes
            displayedModelCount = 50
        }
        .alert("Delete API Key", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                try? credentialsManager.deleteRequestyAPIKey()
                apiKeyInput = ""
            }
        } message: {
            Text("This will remove your Requesty API key and all favorites. You'll need to configure it again to use Requesty models.")
        }
    }

    // MARK: - Sections

    private var apiKeySection: some View {
        Section {
            HStack {
                if showKey {
                    TextField("rqsty-...", text: $apiKeyInput)
                        .textContentType(.password)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                } else {
                    SecureField("rqsty-...", text: $apiKeyInput)
                        .textContentType(.password)
                }

                Button(action: { showKey.toggle() }) {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .themedRow()

            if let error = saveError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .themedRow()
            }

            if !apiKeyInput.isEmpty {
                Button("Save API Key") {
                    saveAPIKey()
                }
                .themedRow()
            }

            if credentialsManager.hasRequestyAPIKey && apiKeyInput.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("API key saved in Keychain")
                        .foregroundColor(.secondary)
                }
                .font(.caption)
                .themedRow()
            }
        } header: {
            Text("API Key")
        } footer: {
            Text("Get your API key from app.requesty.ai/api-keys. Requesty provides access to models from many providers, plus your managed policies.")
        }
    }

    private var favoriteModelsSection: some View {
        Section {
            if credentialsManager.requestyFavoriteModels.isEmpty {
                Text("No favorites yet. Browse models below and tap the star to add favorites.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .themedRow()
            } else {
                ForEach(credentialsManager.requestyFavoriteModels) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName)
                            Text(model.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button {
                            credentialsManager.removeRequestyFavorite(model.id)
                        } label: {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                        }
                        .buttonStyle(.plain)
                    }
                    .themedRow()
                }
            }
        } header: {
            HStack {
                Text("Favorites")
                Spacer()
                Text("\(credentialsManager.requestyFavoriteModels.count) models")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } footer: {
            Text("Only favorited models appear in the main model picker.")
        }
    }

    @ViewBuilder
    private var filterControlsSection: some View {
        // Refresh button
        Button {
            Task {
                await discoverModels()
            }
        } label: {
            HStack {
                if isDiscoveringModels {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(isDiscoveringModels ? String(localized: "Discovering...", comment: "Requesty: model discovery in progress") : String(localized: "Refresh Models", comment: "Requesty: refresh models button"))
            }
        }
        .disabled(isDiscoveringModels)
        .themedRow()

        if let error = discoveryError {
            Text(error)
                .font(.caption)
                .foregroundColor(.red)
                .themedRow()
        }

        // Provider filter
        Picker("Provider", selection: $selectedProvider) {
            Text("All Providers").tag(nil as String?)
            ForEach(credentialsManager.requestyProviderSlugs, id: \.self) { slug in
                Text(formatProviderName(slug)).tag(slug as String?)
            }
        }
        .themedRow()

        // Tier filter
        Picker("Tier", selection: $selectedTier) {
            Text("All Tiers").tag(nil as AIProviderModel.ModelTier?)
            Text("Budget").tag(AIProviderModel.ModelTier.budget as AIProviderModel.ModelTier?)
            Text("Standard").tag(AIProviderModel.ModelTier.standard as AIProviderModel.ModelTier?)
            Text("Premium").tag(AIProviderModel.ModelTier.premium as AIProviderModel.ModelTier?)
        }
        .themedRow()

        // Managed policies toggle
        Toggle("Managed policies only", isOn: $showOnlyManaged)
            .themedRow()
    }

    private var filteredModelsSection: some View {
        Section {
            if credentialsManager.requestyDiscoveredModels.isEmpty {
                Text("No models discovered yet. Tap 'Refresh Models' to fetch the model catalog.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .themedRow()
            } else {
                let models = filteredModels
                let displayModels = Array(models.prefix(displayedModelCount))

                ForEach(displayModels) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName)
                            Text(model.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        // Favorite button
                        Button {
                            toggleFavorite(model)
                        } label: {
                            Image(systemName: credentialsManager.isRequestyFavorite(model.id) ? "star.fill" : "star")
                                .foregroundColor(credentialsManager.isRequestyFavorite(model.id) ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .themedRow()
                }

                // Load more button
                if displayedModelCount < models.count {
                    Button {
                        displayedModelCount += 50
                    } label: {
                        HStack {
                            Spacer()
                            Text("Load more (\(models.count - displayedModelCount) remaining)")
                                .font(.caption)
                            Spacer()
                        }
                    }
                    .themedRow()
                }
            }
        } header: {
            HStack {
                Text("All Models")
                Spacer()
                Text("\(filteredModels.count) of \(credentialsManager.requestyDiscoveredModels.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                HStack {
                    Spacer()
                    Text("Delete API Key")
                    Spacer()
                }
            }
            .themedRow()
        }
    }

    private var temperatureSection: some View {
        let defaultTemp = AICredentialsManager.defaultTemperatures[RequestyProvider.providerID] ?? 0.4

        return Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Temperature")
                    Spacer()
                    Text(String(format: "%.2f", temperature))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }

                Slider(value: $temperature, in: 0.0...2.0, step: 0.05)
                    .onChange(of: temperature) { _, newValue in
                        credentialsManager.setTemperature(newValue, for: RequestyProvider.providerID)
                        isUsingDefaultTemperature = false
                    }

                HStack {
                    Text("Deterministic")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("Creative")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .themedRow()

            if !isUsingDefaultTemperature {
                Button("Reset to Default (\(String(format: "%.1f", defaultTemp)))") {
                    credentialsManager.setTemperature(nil, for: RequestyProvider.providerID)
                    temperature = defaultTemp
                    isUsingDefaultTemperature = true
                }
                .font(.caption)
                .themedRow()
            }
        } header: {
            Text("Temperature")
        } footer: {
            Text("Lower values produce more focused responses. Higher values produce more varied, creative responses.")
        }
    }

    // MARK: - Computed Properties

    private var filteredModels: [AIProviderModel] {
        var models = credentialsManager.requestyDiscoveredModels

        // Search filter
        if !searchText.isEmpty {
            let search = searchText.lowercased()
            models = models.filter { model in
                model.displayName.lowercased().contains(search) ||
                model.id.lowercased().contains(search) ||
                model.description.lowercased().contains(search)
            }
        }

        // Provider filter
        if let provider = selectedProvider {
            models = models.filter { model in
                AIProviderModel.requestyProviderSlug(for: model.id) == provider
            }
        }

        // Tier filter
        if let tier = selectedTier {
            models = models.filter { $0.tier == tier }
        }

        // Managed policies filter
        if showOnlyManaged {
            models = models.filter { model in
                AIProviderModel.isRequestyManagedPolicy(model.id)
            }
        }

        return models
    }

    // MARK: - Actions

    private func loadTemperature() {
        let defaultTemp = AICredentialsManager.defaultTemperatures[RequestyProvider.providerID] ?? 0.4
        if let savedTemp = credentialsManager.temperature(for: RequestyProvider.providerID) {
            temperature = savedTemp
            isUsingDefaultTemperature = false
        } else {
            temperature = defaultTemp
            isUsingDefaultTemperature = true
        }
    }

    private func saveAPIKey() {
        saveError = nil

        guard !apiKeyInput.isEmpty else {
            saveError = "API key cannot be empty"
            return
        }

        // No prefix check: Requesty key formats vary, and the model discovery
        // triggered below rejects an invalid key with a clear error.

        do {
            try credentialsManager.saveRequestyAPIKey(apiKeyInput)
            apiKeyInput = ""
            // Auto-discover models after saving key
            Task {
                await discoverModels()
            }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func discoverModels() async {
        guard let apiKey = credentialsManager.loadRequestyAPIKey() else {
            discoveryError = "API key not configured"
            return
        }

        isDiscoveringModels = true
        discoveryError = nil

        do {
            let models = try await RequestyProvider.discoverModels(apiKey: apiKey)
            credentialsManager.updateRequestyDiscoveredModels(models)
            discoveryError = nil
        } catch {
            discoveryError = error.localizedDescription
        }

        isDiscoveringModels = false
    }

    private func toggleFavorite(_ model: AIProviderModel) {
        if credentialsManager.isRequestyFavorite(model.id) {
            credentialsManager.removeRequestyFavorite(model.id)
        } else {
            credentialsManager.addRequestyFavorite(model.id)
        }
    }

    private func formatProviderName(_ slug: String) -> String {
        // Format provider slugs to display names
        switch slug {
        case "anthropic": return "Anthropic"
        case "openai": return "OpenAI"
        case "google": return "Google"
        case "meta-llama": return "Meta Llama"
        case "mistralai": return "Mistral AI"
        case "cohere": return "Cohere"
        case "deepseek": return "DeepSeek"
        case "qwen": return "Qwen"
        case "perplexity": return "Perplexity"
        case "microsoft": return "Microsoft"
        case "nvidia": return "NVIDIA"
        case "x-ai": return "xAI"
        default:
            // Capitalize first letter of each word
            return slug.split(separator: "-")
                .map { $0.capitalized }
                .joined(separator: " ")
        }
    }
}

#Preview {
    NavigationStack {
        RequestyProviderDetailView()
    }
}
#endif
