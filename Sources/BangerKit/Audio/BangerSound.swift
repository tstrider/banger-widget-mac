//  BangerSound.swift — the celebration sound, played.
//
//  One call from the presenter:
//
//      BangerSound.shared.prepare()             // once, at launch
//      BangerSound.shared.play(config)          // on every completion
//
//  What this file is careful about, in the order it matters:
//
//  1. **It never ducks or interrupts the user's music.** macOS has no
//     AVAudioSession, so an AVAudioEngine wired to the default output mixes
//     with everything else and changes nobody's volume. We deliberately do not
//     touch any system audio state, and we never call into NSSound's alert path.
//  2. **The first fire is not late.** The wavs are decoded and every pitch
//     variant is pre-rendered at `prepare()`. The play path is one
//     `scheduleBuffer` on an already-connected node.
//  3. **It survives the output device changing.** AirPods connecting, a monitor
//     being unplugged, a Thunderbolt dock going away: AVAudioEngine stops itself
//     and posts `.AVAudioEngineConfigurationChange`. We rebuild the graph against
//     the new hardware format and carry on.
//  3b. **It lets go of the device when it is quiet.** Idle is measured from the
//     audio actually finishing (each buffer's rendered callback, with a
//     monotonic deadline as the backstop), never from `isPlaying`: a player node
//     stays "playing" forever after its last buffer drains, so asking it whether
//     it is busy always says yes and the graph would render silence all day.
//  4. **It escalates.** The tier picks the sample (more layers, longer phrase),
//     and progress through today's list picks a pitch variant, so the figure
//     climbs as the list empties instead of being the same noise fifteen times.
//     The variant is chosen deterministically from the config, never randomly.
//
//  Nothing here runs inside the simulation, so it reads no clock the renderer
//  can see and cannot affect frame-for-frame determinism.

import AVFoundation
import Foundation

#if canImport(AppKit)
import AppKit
#endif

public final class BangerSound: @unchecked Sendable {

    public static let shared = BangerSound()

    // MARK: - Knobs

    /// Master switch. Off means silent, not quiet.
    public var isEnabled: Bool {
        get { lock.withLock { _isEnabled } }
        set { lock.withLock { _isEnabled = newValue } }
    }

    /// 0...1, applied on top of the level baked into each wav.
    public var volume: Float {
        get { lock.withLock { _volume } }
        set { lock.withLock { _volume = min(max(newValue, 0), 1) }; applyVolume() }
    }

    /// With Reduce Motion on, the overlay drops to a flash; the sound drops with
    /// it, to the shortest tier at a lower level. Sound is not motion, so it is
    /// not silenced outright — but a user who has asked the machine to calm down
    /// should not get the long, escalating version.
    public var respectsReduceMotion: Bool {
        get { lock.withLock { _respectsReduceMotion } }
        set { lock.withLock { _respectsReduceMotion = newValue } }
    }

    /// Seconds of silence after which the audio graph is released, so a
    /// background agent is not holding the output device open all day.
    /// The decoded buffers stay in memory, so restarting costs a millisecond.
    /// Counted from the moment the last scheduled buffer finished playing, not
    /// from when it started. Zero or less keeps the graph up for good.
    public var idleShutdown: TimeInterval {
        get { lock.withLock { _idleShutdown } }
        set {
            lock.withLock { _idleShutdown = newValue }
            // Takes effect now, against the new interval, rather than after the
            // next sound happens to re-arm it.
            queue.async { [weak self] in self?.scheduleIdleShutdown() }
        }
    }

    // MARK: - State

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.bangerwidget.banger.sound", qos: .userInitiated)

    private var _isEnabled = true
    private var _volume: Float = 1.0
    private var _respectsReduceMotion = true
    private var _idleShutdown: TimeInterval = 90

    private var bank: SoundBank?
    private var engine: AVAudioEngine?
    private var voices: [AVAudioPlayerNode] = []
    private var nextVoice = 0
    private var idleTimer: DispatchWorkItem?
    private var observer: NSObjectProtocol?

    /// Buffers scheduled on the live graph whose rendered callback has not
    /// come back yet. Empty means the graph is rendering nothing but silence.
    /// Tokens are never reused, so a late callback from a graph that has since
    /// been torn down cannot retire a buffer on the new one.
    private var outstanding: Set<UInt64> = []
    private var lastToken: UInt64 = 0
    /// Monotonic instant by which everything scheduled so far has played out.
    /// The backstop for a callback that never arrives (a stalled or vanished
    /// device): past this, plus `completionGrace`, the audio is over regardless.
    private var playbackDeadline = DispatchTime(uptimeNanoseconds: 0)
    private let completionGrace: TimeInterval = 2

    /// How many voices can overlap. Four completions inside one decay is already
    /// a pathological case; more than that and the extra one steals the oldest.
    private let voiceCount = 4

    /// Where the graph and the sounds come from. Always the real output device
    /// and the bundled wavs in the app; a test harness passes an engine in
    /// offline manual-rendering mode so nothing ever reaches the speakers.
    private let makeEngine: () -> AVAudioEngine
    private let makeBank: () -> SoundBank?

    init(makeEngine: @escaping () -> AVAudioEngine = { AVAudioEngine() },
         makeBank: @escaping () -> SoundBank? = { SoundBank() }) {
        self.makeEngine = makeEngine
        self.makeBank = makeBank
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Lifecycle

    /// Decode the wavs and build the graph. Safe to call more than once.
    /// Call it at launch: everything expensive happens here so that `play`
    /// is never the thing that makes the celebration late.
    public func prepare() {
        queue.async { [weak self] in
            guard let self else { return }
            _ = self.loadBankIfNeeded()
            self.startEngineIfNeeded()
            self.warmUp()
            self.scheduleIdleShutdown()
        }
    }

    /// Push a few milliseconds of silence through every voice.
    ///
    /// Starting the engine is not the same as having rendered through it. The
    /// first `scheduleBuffer` on a fresh player node is where CoreAudio
    /// instantiates the format converter and touches the render buffers, and on
    /// a cold graph that shows up as a few milliseconds of slop on the first
    /// play — which is exactly the play we cannot afford to be late, because it
    /// is the one that has to land on the click. Silence costs nothing, is
    /// inaudible by construction, and takes that cost at launch instead.
    private func warmUp(skipping: AVAudioPlayerNode? = nil) {
        guard let engine, engine.isRunning, let bank else { return }
        let frames = AVAudioFrameCount(bank.format.sampleRate * 0.005)
        guard frames > 0,
              let silence = AVAudioPCMBuffer(pcmFormat: bank.format, frameCapacity: frames)
        else { return }
        silence.frameLength = frames          // zero-filled on allocation
        for voice in voices where voice !== skipping {
            schedule(silence, on: voice, options: [])
            voice.play()
        }
    }

    /// True when the wavs are decoded and the audio graph is live. Useful for a
    /// smoke test; the play path does not need it.
    public var isReady: Bool {
        queue.sync { bank != nil && (engine?.isRunning ?? false) }
    }

    /// Cut the sound dead. The celebration is always skippable;
    /// a sound still ringing after the picture has gone is the celebration
    /// refusing to be skipped.
    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            for voice in self.voices where voice.isPlaying { voice.stop() }
        }
    }

    // MARK: - Playing

    /// Fire the sound for this completion. Returns immediately; the work happens
    /// on a private queue.
    public func play(_ config: CelebrationConfig) {
        guard isEnabled else { return }
        let reduce = Self.reduceMotionIsOn && respectsReduceMotion
        let tier = reduce ? .standard : config.tier
        let variant = Self.variantIndex(for: config, reduced: reduce)
        let gain = reduce ? 0.7 : 1.0 as Float

        queue.async { [weak self] in
            guard let self else { return }
            self.fire(tier: tier, variant: variant, gain: gain)
        }
    }

    /// Exposed so a tuning harness can hear one tier without building a config.
    public func play(tier: CelebrationTier, variant: Int = 0) {
        guard isEnabled else { return }
        queue.async { [weak self] in self?.fire(tier: tier, variant: variant, gain: 1.0) }
    }

    private func fire(tier: CelebrationTier, variant: Int, gain: Float) {
        guard let bank = loadBankIfNeeded(),
              let buffer = bank.buffer(tier: tier, variant: variant) else { return }
        let wasLive = engine?.isRunning ?? false
        guard startEngineIfNeeded(), !voices.isEmpty else { return }

        let voice = voices[nextVoice % voices.count]
        nextVoice = (nextVoice + 1) % voices.count
        if voice.isPlaying { voice.stop() }
        voice.volume = gain
        schedule(buffer, on: voice, options: [.interrupts])
        voice.play()
        // Coming back from an idle shutdown the graph is new and cold. This play
        // goes first; the other voices are warmed straight after it, so a second
        // completion inside the same few seconds lands as cleanly as it would
        // have before the shutdown.
        if !wasLive { warmUp(skipping: voice) }
        scheduleIdleShutdown()
    }

    /// Every buffer goes through here, so every one is counted in and counted out.
    ///
    /// The callback runs on an AVFoundation thread, or synchronously inside a
    /// `stop()` on this queue. Either way it only hops back onto the queue: the
    /// bookkeeping is serialised with everything else, and nothing ever stops a
    /// node from inside that node's own completion handler.
    private func schedule(_ buffer: AVAudioPCMBuffer, on voice: AVAudioPlayerNode,
                          options: AVAudioPlayerNodeBufferOptions) {
        lastToken &+= 1
        let token = lastToken
        outstanding.insert(token)
        let seconds = Double(buffer.frameLength) / max(buffer.format.sampleRate, 1)
        let ends = DispatchTime.now() + seconds
        if ends > playbackDeadline { playbackDeadline = ends }
        // `.dataRendered`, not `.dataPlayedBack`: the difference is the device's
        // output latency, a few milliseconds against an interval of minutes, and
        // played-back is tied to a hardware timeline — it never fires on a graph
        // rendered offline, which is how this lifecycle is tested without a speaker.
        // It fires on `stop()` and on an `.interrupts` steal as well.
        voice.scheduleBuffer(buffer, at: nil, options: options,
                             completionCallbackType: .dataRendered) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.playbackFinished(token) }
        }
    }

    private func playbackFinished(_ token: UInt64) {
        // Not ours any more: the graph it played on was torn down, which already
        // forgot it. Nothing to re-arm.
        guard outstanding.remove(token) != nil else { return }
        // The silence starts now, so the idle clock does too.
        if outstanding.isEmpty { scheduleIdleShutdown() }
    }

    // MARK: - Escalation

    /// Deterministic, and deliberately so: the same completion always sounds the
    /// same, which is what makes the offscreen render trustworthy and what stops
    /// the sound feeling arbitrary.
    ///
    /// The figure climbs through the day. Task 1 of 8 is the phrase as written;
    /// by task 7 it sits most of a whole tone higher, so momentum is *audible*
    /// before the tier ever changes. A few cents of seeded jitter on top keeps
    /// two identical-looking completions from being literally the same waveform.
    public static func variantIndex(for config: CelebrationConfig, reduced: Bool = false) -> Int {
        let n = SoundBank.variantCents.count
        if reduced { return 0 }

        let progress: Double
        if config.taskCount > 1 {
            progress = min(max(Double(config.taskIndex) / Double(config.taskCount - 1), 0), 1)
        } else {
            progress = 0
        }

        // The top two tiers are the arrival, not the climb: they sit low in the
        // range so the held note stays where it was written and reads as the
        // resolution of everything before it.
        let ceiling: Double
        switch config.tier {
        case .standard:  ceiling = Double(n - 1)
        case .building:  ceiling = Double(n - 1)
        case .finalTask: ceiling = 2
        case .streak:    ceiling = 1
        }

        var rng = SeededRandom(seed: config.seed ^ (UInt64(bitPattern: Int64(config.taskIndex)) &* 0x9E37_79B9_7F4A_7C15))
        let jitter = rng.range(-0.35, 0.35)
        let raw = progress * ceiling + jitter
        return min(max(Int(raw.rounded()), 0), n - 1)
    }

    // MARK: - Engine

    private func loadBankIfNeeded() -> SoundBank? {
        if let bank { return bank }
        bank = makeBank()
        return bank
    }

    @discardableResult
    private func startEngineIfNeeded() -> Bool {
        if let engine, engine.isRunning { return true }
        if engine == nil { buildEngine() }
        guard let engine else { return false }
        if engine.isRunning { return true }
        do {
            engine.prepare()
            try engine.start()
            applyVolume()
            return true
        } catch {
            // The device is busy or gone. Drop the graph so the next fire builds
            // a fresh one against whatever hardware is there by then.
            teardownEngine()
            return false
        }
    }

    private func buildEngine() {
        guard let bank else { return }
        let engine = makeEngine()
        var nodes: [AVAudioPlayerNode] = []
        for _ in 0..<voiceCount {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            // Connect with the buffers' own format and let the engine's mixer
            // handle the conversion to whatever the hardware wants. That is what
            // lets a device change be survivable rather than fatal.
            engine.connect(node, to: engine.mainMixerNode, format: bank.format)
            nodes.append(node)
        }
        self.engine = engine
        self.voices = nodes

        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: nil, queue: nil
            ) { [weak self] note in
                guard let self else { return }
                // The poster is the engine whose device changed. Only its identity
                // crosses to the queue; the notification itself is not Sendable.
                let poster = (note.object as? AVAudioEngine).map(ObjectIdentifier.init)
                self.queue.async { self.configurationChanged(poster: poster) }
            }
        }
    }

    /// Headphones in, dock out, sample rate changed underneath us. The engine has
    /// already stopped itself; rebuild against the new device, warm it, and put
    /// the idle clock back — tearing down cancels it, and a rebuilt graph that
    /// nothing ever releases is the all-day graph this class exists to avoid.
    private func configurationChanged(poster: ObjectIdentifier?) {
        // Already released for idleness: there is nothing to rebuild, and the next
        // play builds a fresh graph against whatever hardware is there by then.
        // Restarting here would hold the new device open for no sound at all.
        guard let engine else { return }
        // Some other engine in the process, or one of ours we have already dropped.
        if let poster, poster != ObjectIdentifier(engine) { return }
        teardownEngine()
        if startEngineIfNeeded() { warmUp() }
        scheduleIdleShutdown()
    }

    /// Releases the graph and the output device. The decoded bank is kept, so the
    /// next play rebuilds in a millisecond instead of re-reading the wavs.
    private func teardownEngine() {
        idleTimer?.cancel()
        idleTimer = nil
        if let engine {
            for voice in voices where voice.isPlaying { voice.stop() }
            engine.stop()
            for voice in voices { engine.detach(voice) }
        }
        voices.removeAll()
        engine = nil
        // Whatever was still in flight died with the graph. Stopping the voices
        // above fires their callbacks, but those land after this and find nothing.
        outstanding.removeAll()
    }

    private func applyVolume() {
        queue.async { [weak self] in
            guard let self, let engine = self.engine else { return }
            engine.mainMixerNode.outputVolume = self.lock.withLock { self._volume }
        }
    }

    /// (Re)starts the idle clock. Queue only. `delay` is for the backstop re-check;
    /// everything else waits the full interval.
    private func scheduleIdleShutdown(after delay: TimeInterval? = nil) {
        idleTimer?.cancel()
        idleTimer = nil
        let interval = lock.withLock { _idleShutdown }
        guard interval > 0, engine != nil else { return }
        let item = DispatchWorkItem { [weak self] in self?.idleTimerFired() }
        idleTimer = item
        queue.asyncAfter(deadline: .now() + (delay ?? interval), execute: item)
    }

    private func idleTimerFired() {
        idleTimer = nil
        guard engine != nil else { return }
        if !outstanding.isEmpty {
            // Still sounding (an interval shorter than the sound). The last
            // callback re-arms the full interval when it lands; this re-check is
            // only for the case where it never does.
            let giveUp = playbackDeadline + completionGrace
            let now = DispatchTime.now()
            if now < giveUp {
                let wait = Double(giveUp.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000
                scheduleIdleShutdown(after: wait)
                return
            }
            // Past the deadline with callbacks missing: the audio is over, the
            // notification of it just never came.
        }
        teardownEngine()
    }

    // MARK: - Test hooks

    /// The live graph, or nil once it has been released. For the offline harness,
    /// which renders it by hand; nothing in the app reads this.
    var engineForTesting: AVAudioEngine? { queue.sync { engine } }

    /// Buffers still waiting for their rendered callback.
    var outstandingPlaybackForTesting: Int { queue.sync { outstanding.count } }

    // MARK: - Accessibility

    private static var reduceMotionIsOn: Bool {
        #if canImport(AppKit)
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        return false
        #endif
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
