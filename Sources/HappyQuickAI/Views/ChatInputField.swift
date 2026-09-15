//
//  ChatInputField.swift
//  HappyQuickAI
//
//  One-line chat input backed by `NSTextField`.
//
//  A plain SwiftUI `TextField` cannot be trusted on every host: while the field
//  is being edited the host is free to swallow the key events at or before its
//  own event dispatch, so the caret appears and nothing types (observed when
//  Droppy runs in English but not Spanish). While this field is mid-edit, a
//  local key monitor feeds every keystroke into the field editor and consumes
//  it, so typing works identically in every host language and the host's own
//  focus cycle never has a chance to eat it.
//
//  Keys are routed through `NSTextView.interpretKeyEvents(_:)`, not injected
//  as raw text: that keeps the system's text input machinery — input methods
//  (IME) and dead keys for the droplet's own 日本語 and 中文 output languages —
//  working, because the monitor runs before the host dispatches the event but
//  the editor still performs its normal input interpretation.
//

import AppKit
import SwiftUI

struct ChatInputField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.placeholderString = "Ask AI…"
        field.textColor = .white
        field.alignment = .left
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        context.coordinator.install(on: field)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ChatInputField
        private weak var field: NSTextField?
        private var keyMonitor: Any?
        private var didMakeKey = false

        init(_ parent: ChatInputField) {
            self.parent = parent
        }

        func install(on field: NSTextField) {
            self.field = field
            // Must return the coordinator's decision verbatim: `nil` swallows the
            // event, anything else lets it keep its normal route. Returning the
            // event here when the handler chose `nil` redelivers the keystroke to
            // the field editor, which inserts it a second time.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handleKeyDown(event)
            }
        }

        func teardown() {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
            keyMonitor = nil
            field = nil
        }

        private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
            // No dependence on NSApp.isActive: a floating shelf/hud panel can be
            // editing while the app is not the global active app.
            guard let field, let editor = field.currentEditor() as? NSTextView else { return event }
            // Command/control combinations keep their normal route (copy, paste, menus).
            if !event.modifierFlags.intersection([.command, .control]).isEmpty { return event }

            switch event.keyCode {
            case 36, 76: // Return / keypad Enter.
                // Confirm an in-progress IME composition instead of submitting.
                if editor.hasMarkedText() {
                    editor.interpretKeyEvents([event])
                    return nil
                }
                parent.onSubmit()
                return nil
            case 48, 53: // Tab, Escape — keep the host's focus cycle / route.
                return event
            default:
                // Function keys and other char-less events have nothing to type;
                // leave them to the host's normal route.
                let hasCharacters = (event.characters?.isEmpty == false)
                    || (event.charactersIgnoringModifiers?.isEmpty == false)
                guard hasCharacters else { return event }
                // Feed the keystroke to the field editor's input interpretation:
                // IMEs, dead keys, delete, arrows and selection edits all work,
                // while the event is still consumed so the host cannot re-deliver it.
                editor.interpretKeyEvents([event])
                return nil
            }
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let field, let editor = field.currentEditor() as? NSTextView else { return }
            editor.insertionPointColor = .white
            if !didMakeKey, let window = field.window {
                window.makeKey()
                window.makeFirstResponder(field)
                didMakeKey = true
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field else { return }
            parent.text = field.stringValue
        }

        @objc func submit(_ sender: Any?) {
            parent.onSubmit()
        }
    }
}