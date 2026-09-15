//
//  ShelfWidget.swift
//  HappyQuickAI
//
//  The shelf-widget surface: descriptor plus the widget's view compositions.
//
//  Follows the example droplets (WorldClock, Teleprompter): straight on the
//  shelf, no card, the host's inset once, DroppyAnimation presets for state
//  changes (frozen while the shelf is transitioning), and the user's Widget
//  Text colour when they set one in Droppy.
//

import DroppyKit
import SwiftUI

// MARK: - Shelf widget

extension HappyQuickAIDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: "happy-quick-ai",
                title: "Happy Quick-AI",
                systemImage: "sparkles",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 520,
                    preferredPairedWidth: 260,
                    contentHeight: .fixed(264)
                ),
                focusPolicy: .keyboardFocusable,
                searchKeywords: ["chat", "ai", "assistant", "gpt", "chatgpt", "claude", "gemini"]
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(HappyQuickAIWidget(droplet: self, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

// MARK: - Chat Widget View

private struct HappyQuickAIWidget: View {
    @ObservedObject var droplet: HappyQuickAIDroplet
    let context: ShelfWidgetContext

    /// The user's Widget Text colour, when they set one in Droppy.
    @Environment(\.dropletShelfWidgetTextColor) private var widgetTextColor

    @State private var inputText: String = ""

    /// The accent the widget's primary action uses.
    private var accent: Color { AdaptiveColors.selectionBlueAuto }

    /// Button sizes: the backdrop controls shrink beside another widget.
    private var headerDiscSize: CGFloat { context.isCompact ? 18 : 20 }
    private var inputDiscSize: CGFloat { context.isCompact ? 22 : 26 }

    /// Text ladder: the user's Widget Text colour wins over the fixed
    /// white-over-black tokens whenever the user set one.
    private var primaryText: Color {
        widgetTextColor ?? AdaptiveColors.notchSurfacePrimaryText
    }

    private var secondaryText: Color {
        if let widgetTextColor { return widgetTextColor.opacity(0.82) }
        return AdaptiveColors.notchSurfaceSecondaryText
    }

    private var tertiaryText: Color {
        if let widgetTextColor { return widgetTextColor.opacity(0.60) }
        return AdaptiveColors.notchSurfaceTertiaryText
    }

    private var isFrozen: Bool { context.isShelfTransitioning }

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            headerRow

            if !droplet.isConfigured {
                unconfiguredView
            } else if context.isCompact {
                compactView
            } else {
                expandedView
            }
        }
        .padding(context.contentInsets)
        // A fixed 3pt safe margin inside the rectangle: the shelf's corner
        // rounding cuts into the slot, so content drawn flush to the edge
        // loses its corners to the curve.
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(isFrozen ? nil : DroppyAnimation.state, value: droplet.messages.count)
        .animation(isFrozen ? nil : DroppyAnimation.state, value: droplet.isGenerating)
        .animation(isFrozen ? nil : DroppyAnimation.state, value: droplet.selectedProvider)
    }

    // MARK: Sub-views

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .medium))
            Text("Happy Quick-AI")
                .font(.system(size: 12, weight: .semibold))

            if !context.isCompact {
                Text(droplet.selectedProvider.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, DroppySpacing.xsm)
                    .padding(.vertical, DroppySpacing.xs)
                    .background {
                        RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous)
                            .fill(AdaptiveColors.notchSurfaceCardFill)
                    }
            }

            Spacer(minLength: 0)

            if !context.isCompact {
                Button {
                    droplet.clearMessages()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: headerDiscSize))
                .help("Clear chat")
                .accessibilityLabel("Clear chat")

                Button {
                    droplet.openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: headerDiscSize))
                .help("Settings")
                .accessibilityLabel("Settings")
            }
        }
        .foregroundStyle(secondaryText)
        .allowsHitTesting(!isFrozen)
    }

    @ViewBuilder
    private var unconfiguredView: some View {
        VStack(spacing: DroppySpacing.smd) {
            Spacer(minLength: 0)
            Image(systemName: "key.slash")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(tertiaryText)
                .contentTransition(.symbolEffect(.replace))

            Text(droplet.setupHintTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(primaryText)

            Text(droplet.setupHintDetail)
                .font(.system(size: 11))
                .foregroundStyle(secondaryText)
                .multilineTextAlignment(.center)

            Button {
                droplet.openSettings()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape.fill")
                    Text("Open Settings")
                }
            }
            .buttonStyle(DroppyAccentButtonStyle(color: accent, size: context.isCompact ? .small : .medium))
            .help("Opens the droplet's settings page")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(!isFrozen)
    }

    @ViewBuilder
    private var compactView: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            if let last = droplet.messages.last {
                Text(last.role == .user ? "You:" : "AI:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(secondaryText)

                if last.role == .user {
                    Text(last.content)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(primaryText)
                        .lineLimit(4)
                        .truncationMode(.tail)
                } else {
                    Text(MarkdownText.teaser(last.content))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(primaryText)
                        .lineLimit(4)
                        .truncationMode(.tail)
                }
            } else {
                Text(droplet.selectedProvider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(primaryText)
                Text("Start a chat in the full widget")
                    .font(.system(size: 11))
                    .foregroundStyle(tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var expandedView: some View {
        // Chat scroll area
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DroppySpacing.xs) {
                    if droplet.messages.isEmpty {
                        Text("Ask a question to start the conversation…")
                            .font(.system(size: 12))
                            .foregroundStyle(tertiaryText)
                            .padding(.vertical, DroppySpacing.sm)
                    } else {
                        ForEach(droplet.messages) { msg in
                            messageBubble(msg)
                        }
                    }

                    if droplet.isGenerating {
                        HStack(spacing: DroppySpacing.xs) {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.9)
                            Text("Thinking…")
                                .font(.system(size: 11))
                                .foregroundStyle(secondaryText)
                        }
                        .padding(.vertical, DroppySpacing.xs)
                        .id("generating")
                        .transition(.opacity)
                    }

                    if let err = droplet.errorMessage {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.red)
                            .padding(.horizontal, DroppySpacing.smd)
                            .padding(.vertical, DroppySpacing.xs)
                            .background {
                                RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous)
                                    .fill(Color.red.opacity(0.15))
                            }
                            .transition(.opacity)
                    }
                }
                .padding(.bottom, DroppySpacing.xs)
                .animation(isFrozen ? nil : DroppyAnimation.state, value: droplet.messages.count)
                .animation(isFrozen ? nil : DroppyAnimation.state, value: droplet.isGenerating)
            }
            .onChange(of: droplet.messages.count) { _, _ in
                if let last = droplet.messages.last {
                    withAnimation(isFrozen ? nil : DroppyAnimation.state) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: droplet.isGenerating) { _, generating in
                if generating {
                    withAnimation(isFrozen ? nil : DroppyAnimation.state) {
                        proxy.scrollTo("generating", anchor: .bottom)
                    }
                }
            }
        }

        // Input bar — outside ScrollViewReader so it always receives keyboard focus
        inputBar
    }

    @ViewBuilder
    private func messageBubble(_ msg: ChatMessage) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            if msg.role == .user { Spacer(minLength: DroppySpacing.xxl) }
            Group {
                if msg.role == .user {
                    // The user's own text stays exactly as typed.
                    Text(msg.content)
                        .font(.system(size: 12))
                } else {
                    // The AI's reply renders its markdown (bold, rules, code…).
                    MarkdownText(markdown: msg.content, secondary: secondaryText)
                }
            }
            .padding(.horizontal, DroppySpacing.smd)
            .padding(.vertical, DroppySpacing.xsm)
            .background {
                RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous)
                    .fill(
                        msg.role == .user
                            ? AdaptiveColors.selectionBlueAuto
                            : AdaptiveColors.notchSurfaceCardFill
                    )
            }
            .foregroundStyle(
                msg.role == .user
                    ? AdaptiveColors.selectionForegroundAuto
                    : primaryText
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: msg.role == .user ? .trailing : .leading)
            if msg.role == .assistant { Spacer(minLength: DroppySpacing.xxl) }
        }
        .id(msg.id)
    }

    @ViewBuilder
    private var inputBar: some View {
        HStack(spacing: DroppySpacing.xs) {
            ChatInputField(text: $inputText, onSubmit: { sendCurrentText() })
                .padding(.horizontal, DroppySpacing.smd)
                .padding(.vertical, DroppySpacing.xsm)
                .background {
                    RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous)
                        .fill(AdaptiveColors.notchSurfaceCardFill)
                }

            // The primary action: neutral glass, the accent in the glyph,
            // the way the example droplets tint their one accent disc.
            Button {
                sendCurrentText()
            } label: {
                Image(systemName: droplet.isGenerating ? "ellipsis" : "paperplane.fill")
                    .font(.system(size: 11))
                    .contentTransition(.symbolEffect(.replace))
                    .animation(isFrozen ? nil : DroppyAnimation.state, value: droplet.isGenerating)
            }
            .buttonStyle(
                DroppyCircleButtonStyle(
                    size: inputDiscSize,
                    destructive: false,
                    solidFill: nil,
                    foregroundColorOverride: droplet.isGenerating ? nil : accent
                )
            )
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || droplet.isGenerating)
            .help("Send")
            .accessibilityLabel("Send")
        }
        .allowsHitTesting(!isFrozen)
    }

    private func sendCurrentText() {
        if droplet.sendMessage(inputText) {
            inputText = ""
        }
    }
}