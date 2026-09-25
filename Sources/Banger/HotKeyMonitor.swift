//  HotKeyMonitor.swift — Control-Option-Command-B, from the background.
//
//  Why Carbon and not NSEvent.addGlobalMonitorForEvents:
//  a global NSEvent monitor is a passive tap on other applications' input, so the
//  system requires an Accessibility (Privacy > Accessibility) grant and silently
//  delivers nothing until the user gives it. RegisterEventHotKey reserves the
//  combination with the window server instead — the key never reaches the front
//  app, no tap exists, and it needs NO permission at all. It is what every menu
//  bar utility has used for twenty years and it still works on macOS 26.
//
//  A local NSEvent monitor would add nothing here: this process is .accessory and
//  is never the active application, so it would never see a key event.

import AppKit
import Carbon.HIToolbox

struct HotKeyModifiers: OptionSet, Sendable {
    let rawValue: Int
    static let command = HotKeyModifiers(rawValue: cmdKey)
    static let option  = HotKeyModifiers(rawValue: optionKey)
    static let control = HotKeyModifiers(rawValue: controlKey)
    static let shift   = HotKeyModifiers(rawValue: shiftKey)
}

@MainActor
final class HotKeyMonitor {

    static let keyB = UInt32(kVK_ANSI_B)

    /// 'BNGR'
    private static let signature: OSType = 0x424E_4752
    private static var lastIdentifier: UInt32 = 0

    /// Per instance. Every monitor's handler sits on the same event target and sees every
    /// 'BNGR' key, so each one answers only to its own id and passes the rest along.
    fileprivate let identifier: UInt32

    init() {
        Self.lastIdentifier += 1
        identifier = Self.lastIdentifier
    }

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    /// Returns false if the combination is already claimed by something else.
    @discardableResult
    func register(keyCode: UInt32, modifiers: HotKeyModifiers, action: @escaping () -> Void) -> Bool {
        unregister()
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(),
                                            bangerHotKeyHandler,
                                            1, &eventType,
                                            context,
                                            &handlerRef)
        guard installed == noErr else {
            self.action = nil
            return false
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        let registered = RegisterEventHotKey(keyCode,
                                             UInt32(modifiers.rawValue),
                                             hotKeyID,
                                             GetApplicationEventTarget(),
                                             0,
                                             &hotKeyRef)
        guard registered == noErr else {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        action = nil
    }

    fileprivate func fire() {
        action?()
    }
}

/// Carbon requires a C function. It is dispatched on the main run loop, which is
/// why assuming main-actor isolation here is sound rather than hopeful.
private func bangerHotKeyHandler(_ callRef: EventHandlerCallRef?,
                                 _ event: EventRef?,
                                 _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotKeyID)
    guard status == noErr, hotKeyID.signature == 0x424E_4752 else {
        return OSStatus(eventNotHandledErr)
    }

    let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(userData).takeUnretainedValue()
    return MainActor.assumeIsolated {
        guard hotKeyID.id == monitor.identifier else { return OSStatus(eventNotHandledErr) }
        monitor.fire()
        return noErr
    }
}
