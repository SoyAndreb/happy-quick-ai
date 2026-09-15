//
//  SettingsPane.swift
//  HappyQuickAI
//
//  The settings-pane surface: the droplet's settings page in Droppy's
//  Settings, built from the same rows Droppy's own pages use.
//

import AppKit
import DroppyKit
import SwiftUI

// MARK: - Settings pane

extension HappyQuickAIDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(HappyQuickAISettings(droplet: self))
    }

    public var settingsSearchEntries: [SettingsSearchEntry] {
        [
            SettingsSearchEntry(title: "Chat", keywords: ["api", "key", "provider", "model"]),
            SettingsSearchEntry(title: "Connection", keywords: ["test", "models", "status"])
        ]
    }
}

/// The droplet's settings, built from the same rows Droppy's own pages use.
private struct HappyQuickAISettings: View {
    @ObservedObject var droplet: HappyQuickAIDroplet

    @State private var confirmsClear = false

    var body: some View {
        // No page-level padding or ScrollView: the host applies the page inset
        // and scrolls the pane, so cards must fill the proposed width and line
        // up with Droppy's own pages.
        VStack(alignment: .leading, spacing: DroppySpacing.lg) {
            chatCard
            apiKeyCard
            connectionCard
            conversationCard
        }
        .alert("Clear the conversation?", isPresented: $confirmsClear) {
            Button("Clear", role: .destructive) { droplet.clearMessages() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The stored chat history shown in the widget is deleted.")
        }
    }

    // MARK: Chat

    @ViewBuilder
    private var chatCard: some View {
        DropletSettingsCard {
            settingsUnifiedPickerRow(
                title: "Provider",
                subtitle: "Where your chat runs.",
                icon: "network",
                options: AIProvider.allCases,
                groupPosition: .top,
                isSelected: { $0 == droplet.selectedProvider },
                action: { droplet.selectedProvider = $0 }
            ) { provider, _, _ in
                Text(provider.displayName)
                    .font(.callout)
            }

            DropletSettingsDivider()

            modelRow

            if droplet.selectedProvider == .custom {
                DropletSettingsDivider()
                DropletStackedRow(
                    title: "Base URL",
                    icon: "link",
                    infoTip: "Server address for your OpenAI-compatible API, for example http://localhost:11434/v1."
                ) {
                    TextField("http://localhost:1234/v1", text: baseURLBinding)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(DroppySpacing.xs)
                        .background(AdaptiveColors.overlayAuto(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: DroppyRadius.xs, style: .continuous))
                }
            }
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        if droplet.selectedProvider == .custom {
            DropletStackedRow(
                title: "Model",
                icon: "cpu",
                infoTip: "The custom server owns its model names; type the one you want, or fetch the list from its /models endpoint."
            ) {
                HStack(spacing: DroppySpacing.xs) {
                    TextField("Model name", text: modelBinding)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(DroppySpacing.xs)
                        .background(AdaptiveColors.overlayAuto(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: DroppyRadius.xs, style: .continuous))
                    refreshModelsButton
                }
            }
        } else {
            DropletControlRow(
                title: "Model",
                icon: "cpu",
                infoTip: "Your provider's available models, fetched from its API."
            ) {
                HStack(spacing: DroppySpacing.xs) {
                    Picker("", selection: modelBinding) {
                        ForEach(droplet.availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 220, alignment: .trailing)
                    refreshModelsButton
                }
            }
        }
    }

    @ViewBuilder
    private var refreshModelsButton: some View {
        Button {
            droplet.updateAvailableModelsList()
        } label: {
            if droplet.isFetchingModels {
                ProgressView()
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(DroppyCircleButtonStyle(size: 20))
        .disabled(droplet.isFetchingModels)
        .help("Refresh model list")
    }

    // MARK: API key

    @ViewBuilder
    private var apiKeyCard: some View {
        DropletSettingsCard {
            DropletStackedRow(
                title: "API key",
                icon: "key",
                infoTip: keyInfoTip
            ) {
                SecureField("", text: keyBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(DroppySpacing.xs)
                    .background(AdaptiveColors.overlayAuto(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: DroppyRadius.xs, style: .continuous))
            }
        }
    }

    private var keyInfoTip: String {
        switch droplet.selectedProvider {
        case .custom:
            return "Optional — your server may not need one."
        default:
            return "Secret API key for \(droplet.selectedProvider.displayName)."
        }
    }

    private var keyBinding: Binding<String> {
        switch droplet.selectedProvider {
        case .chatGPT: return strBinding(get: droplet.chatgptApiKey) { droplet.chatgptApiKey = $0 }
        case .gemini: return strBinding(get: droplet.geminiApiKey) { droplet.geminiApiKey = $0 }
        case .claude: return strBinding(get: droplet.claudeApiKey) { droplet.claudeApiKey = $0 }
        case .deepseek: return strBinding(get: droplet.deepseekApiKey) { droplet.deepseekApiKey = $0 }
        case .openRouter: return strBinding(get: droplet.openRouterApiKey) { droplet.openRouterApiKey = $0 }
        case .custom: return strBinding(get: droplet.customApiKey) { droplet.customApiKey = $0 }
        }
    }

    // MARK: Connection

    @ViewBuilder
    private var connectionCard: some View {
        DropletSettingsCard {
            DropletControlRow(
                title: "Test connection",
                icon: "bolt.fill",
                infoTip: "Asks the selected provider's models endpoint with your stored credentials and shows the server's own answer."
            ) {
                if droplet.isTestingConnection {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Test") {
                        Task { await droplet.testConnection() }
                    }
                    .buttonStyle(DroppyAccentButtonStyle(color: AdaptiveColors.selectionBlueAuto, size: .small))
                }
            }

            if let status = droplet.connectionStatus {
                DropletSettingsDivider()
                DropletControlRow(title: "Result") {
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 260, alignment: .trailing)
                }
            }

            if let error = droplet.modelsFetchError {
                DropletSettingsDivider()
                DropletControlRow(title: "Models error") {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 260, alignment: .trailing)
                }
            }
        }
    }

    // MARK: Conversation

    @ViewBuilder
    private var conversationCard: some View {
        DropletSettingsCard {
            DropletStackedRow(
                title: "System prompt",
                icon: "text.alignleft",
                infoTip: "Style instruction sent as the system message in every chat request."
            ) {
                TextEditor(text: promptBinding)
                    .font(.system(size: 12))
                    .frame(minHeight: 80)
                    .padding(DroppySpacing.xs)
                    .scrollContentBackground(.hidden)
                    .background(AdaptiveColors.overlayAuto(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: DroppyRadius.xs, style: .continuous))
            }

            DropletSettingsDivider()

            DropletControlRow(
                title: "Clear conversation",
                icon: "trash",
                infoTip: "Deletes the stored chat history shown in the widget."
            ) {
                Button("Clear") {
                    confirmsClear = true
                }
                .buttonStyle(DroppyQuietButtonStyle(size: .small, destructive: true))
                .help("Deletes the stored chat history shown in the widget")
            }
        }
    }

// MARK: Bindings

    private func strBinding(get: String, set: @escaping (String) -> Void) -> Binding<String> {
        Binding(get: { get }, set: { set($0) })
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { droplet.selectedModel },
            set: { droplet.selectedModel = $0 }
        )
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { droplet.customBaseURL },
            set: { droplet.customBaseURL = $0 }
        )
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: { droplet.systemPrompt },
            set: { droplet.systemPrompt = $0 }
        )
    }
}