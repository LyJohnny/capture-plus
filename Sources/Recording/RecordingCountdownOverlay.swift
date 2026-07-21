//
//  RecordingCountdownOverlay.swift
//  Capture + — Feature 3: Screen recording
//
//  A translucent 3-2-1 countdown shown centered on a screen BEFORE recording
//  begins. Recording starts only once the overlay clears, so the countdown
//  itself is never captured. The window is borderless, transparent and
//  non-interactive (click-through), floats above everything, and joins all
//  Spaces so it shows regardless of the active desktop.
//
//  Self-contained: a SwiftUI view hosted in a borderless NSWindow drives the
//  per-tick scale/fade animation; the controller owns the tick timer and the
//  teardown.
//

import AppKit
import SwiftUI

// MARK: - Tick view model

/// Backing store for the countdown view: the number currently on screen. The
/// controller mutates `value` once per second; the view animates each change.
@MainActor
final class CountdownModel: ObservableObject {
    @Published var value: Int

    init(value: Int) {
        self.value = value
    }
}

// MARK: - Number view

/// A single large translucent number on a dimmed rounded backdrop, centered in
/// its container. Each new value fades/scales in via a transition so the tick
/// reads as a distinct beat.
struct CountdownView: View {
    @ObservedObject var model: CountdownModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // A whisper-thin scrim — just enough to keep the number legible over
            // bright content without darkening the scene like a heavy overlay would.
            Color.black.opacity(0.08)
                .ignoresSafeArea()

            backdrop
                .overlay(number)
        }
        .allowsHitTesting(false)
    }

    private var backdrop: some View {
        // Genuinely translucent: the material itself is the fill (no black layer
        // muddying it), a hairline edge for that refined Apple-HUD look, and a
        // soft ambient shadow to lift it off the desktop.
        RoundedRectangle(cornerRadius: 46, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 46, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            )
            .frame(width: 240, height: 240)
            .shadow(color: .black.opacity(0.22), radius: 26, y: 10)
    }

    private var number: some View {
        // `id` + transition: swapping the value inserts a fresh Text, so the old
        // number fades/scales out while the new one fades/scales in. With Reduce
        // Motion on we drop the large scale and cross-fade only, keeping the beat
        // legible without the big zoom.
        Text("\(model.value)")
            .font(.system(size: 176, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.95))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            .id(model.value)
            .transition(reduceMotion
                ? .opacity
                : .scale(scale: 0.6).combined(with: .opacity))
    }
}

// MARK: - Window

/// Borderless, transparent, click-through window that hosts the countdown. Never
/// becomes key or main so it can't steal focus from the frontmost app.
private final class CountdownWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controller

/// Shows a centered 3-2-1 countdown before recording starts, then calls back so
/// the caller can begin the capture. Reusable: calling `run` again while a
/// countdown is in flight cancels the previous one first.
@MainActor
final class RecordingCountdownOverlay {
    private var window: CountdownWindow?
    private var model: CountdownModel?
    private var timer: Timer?
    private var completion: (() -> Void)?
    /// Pending post-orderOut safety delay before `completion` fires. Held so a new
    /// run (or a cancel) can drop the completion before it runs.
    private var pendingCompletion: DispatchWorkItem?

    /// How long to wait after the overlay window is ordered off-screen before
    /// firing `completion`, so the compositor has flushed the overlay away and it
    /// can't appear in the first recorded frames.
    private static let flushDelay: TimeInterval = 0.18

    public init() {}

    /// Runs a `seconds`-long countdown on `screen` (defaults to the main screen),
    /// then calls `completion` on the main thread. If `seconds <= 0` the overlay
    /// is skipped and `completion` fires immediately. Calling again while running
    /// cancels the in-flight countdown (its completion does NOT fire) before
    /// starting the new one.
    func run(seconds: Int, on screen: NSScreen?, completion: @escaping () -> Void) {
        // Cancel any in-flight countdown without firing its completion.
        cancel()

        guard seconds > 0 else {
            completion()
            return
        }

        self.completion = completion

        let model = CountdownModel(value: seconds)
        self.model = model

        let targetScreen = screen ?? NSScreen.main
        let frame = targetScreen?.frame ?? NSRect(x: 0, y: 0, width: 800, height: 600)

        let window = CountdownWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        window.contentView = NSHostingView(rootView: CountdownView(model: model))
        window.setFrame(frame, display: false)
        self.window = window

        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            window.animator().alphaValue = 1
        }

        // Tick down once per second. Each tick decrements the displayed value with
        // an animation; after the final tick (value reaches 0) we tear down and
        // fire completion.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Advance the countdown by one second, finishing when it runs out.
    private func tick() {
        guard let model else { return }

        let next = model.value - 1
        if next <= 0 {
            finish()
        } else if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Reduce Motion: no bouncy spring — a quick cross-fade (paired with the
            // view's opacity-only transition) so the tick still reads as a beat.
            withAnimation(.easeInOut(duration: 0.2)) {
                model.value = next
            }
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                model.value = next
            }
        }
    }

    /// Final tick: fade the window out, remove it from screen, then — after a
    /// short safety delay so the compositor has flushed the overlay off-screen —
    /// fire completion. The delay guards against the overlay bleeding into the
    /// first recorded frames.
    private func finish() {
        let completion = self.completion
        self.completion = nil

        invalidateTimer()

        guard let window else {
            completion?()
            return
        }
        self.window = nil
        self.model = nil

        // Fire completion on the main thread only after the window is off-screen
        // AND a flush delay has elapsed. Held as a cancellable work item so a new
        // run started during the delay drops this completion cleanly.
        let deliver = DispatchWorkItem { [weak self] in
            self?.pendingCompletion = nil
            completion?()
        }
        self.pendingCompletion = deliver

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + RecordingCountdownOverlay.flushDelay,
                execute: deliver
            )
        })
    }

    /// Tear down any in-flight countdown immediately WITHOUT firing completion.
    private func cancel() {
        invalidateTimer()
        // Drop any completion still waiting on the post-orderOut flush delay. The
        // work item may already be scheduled (or about to be scheduled by an
        // in-flight fade completion); cancelling it prevents it from firing.
        pendingCompletion?.cancel()
        pendingCompletion = nil
        completion = nil
        window?.orderOut(nil)
        window = nil
        model = nil
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }
}
