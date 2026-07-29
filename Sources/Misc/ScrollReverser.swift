//
//  ScrollReverser.swift
//  Capture + — Misc: Windows-style scrolling for mice
//
//  macOS couples "natural scrolling" across trackpad AND mice (still true on
//  macOS 26): turning it off for a mouse also flips the trackpad. This restores
//  the split the OS won't offer — a CGEventTap inverts the vertical scroll of
//  MOUSE events only, leaving trackpad gestures untouched. The distinction is
//  made per event, so it applies automatically whenever any mouse scrolls; no
//  device-connection tracking is needed.
//
//  Detection (the same heuristic Scroll Reverser / Mos rely on):
//   - non-continuous scrolls (classic click-wheel lines)         → mouse
//   - continuous scrolls WITHOUT gesture phases (smooth wheels)  → mouse
//   - continuous scrolls WITH gesture/momentum phases            → trackpad
//
//  Modifying input events system-wide requires the user to grant Capture +
//  Accessibility permission (one-time, System Settings → Privacy & Security →
//  Accessibility).
//

import AppKit
import ApplicationServices

@MainActor
final class ScrollReverser {

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Retries starting the tap while enabled but blocked (permission not yet
    /// granted, or tap creation failed). Invalidated once running or disabled.
    private var retryTimer: Timer?

    private(set) var isEnabled = false

    /// Whether the user has granted the Accessibility permission the tap needs.
    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// Ask macOS to show the Accessibility-permission prompt (deep-links the user
    /// to the right pane). Safe to call repeatedly.
    static func promptForPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Turn the reverser on or off. When enabled without permission (or if the tap
    /// can't start yet), it keeps retrying quietly and engages as soon as it can —
    /// so granting permission in System Settings "just works" without a relaunch.
    func apply(enabled: Bool) {
        isEnabled = enabled
        if enabled {
            startIfPossible()
            scheduleRetryIfNeeded()
        } else {
            stop()
        }
    }

    // MARK: - Tap lifecycle

    private func startIfPossible() {
        guard isEnabled, tap == nil, Self.hasPermission else { return }

        let mask: CGEventMask = 1 << CGEventType.scrollWheel.rawValue
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                // The system disables a tap it thinks is slow or during secure
                // input; re-enable rather than silently dying.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let refcon {
                        let reverser = Unmanaged<ScrollReverser>
                            .fromOpaque(refcon).takeUnretainedValue()
                        DispatchQueue.main.async { reverser.reenable() }
                    }
                    return Unmanaged.passUnretained(event)
                }
                _ = ScrollReverser.reverseIfMouseScroll(event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon)
        else { return }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        retryTimer?.invalidate()
        retryTimer = nil
    }

    private func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        tap = nil
    }

    private func reenable() {
        guard isEnabled, let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func scheduleRetryIfNeeded() {
        guard isEnabled, tap == nil, retryTimer == nil else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.startIfPossible()
                if self.tap != nil || !self.isEnabled {
                    self.retryTimer?.invalidate()
                    self.retryTimer = nil
                }
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    // MARK: - The transform

    /// If `event` is a MOUSE scroll, invert its vertical deltas (all three delta
    /// representations, so line- and pixel-based consumers agree) and return true.
    /// Trackpad gestures (continuous with phase/momentum data) are left untouched.
    ///
    /// Static and pure so the self-test harness can verify it on synthetic events.
    @discardableResult
    static func reverseIfMouseScroll(_ event: CGEvent) -> Bool {
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        if continuous {
            let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
            let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            if phase != 0 || momentum != 0 { return false }   // trackpad gesture
        }

        // The three delta fields are linked representations of ONE value — setting one
        // re-syncs the others. Snapshot all originals BEFORE writing, or sequential
        // read-negate-write cycles re-negate each other and the sign flips back.
        let line = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let point = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let fixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -line)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -point)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixed)
        return true
    }
}
