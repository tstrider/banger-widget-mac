//  CelebrationAPI.swift — the one contract every celebration layer builds against.
//
//  The core rule: the celebration is a PURE, DETERMINISTIC simulation stepped at fixed
//  dt, plus a PURE draw. The live overlay and the offscreen frame renderer call the
//  exact same code, so a rendered video is byte-for-byte what appears on screen.
//
//  Do not read the clock inside the simulation. Do not use Double.random. Seed everything.

import Foundation
import SwiftUI

// MARK: - Escalation input

/// How big a deal this particular completion is. Produced by the escalation engine,
/// consumed by every effect (particles, sound, haptics, flash).
public struct CelebrationConfig: Equatable, Codable, Sendable {
    /// 0...1. The master dial. Everything else scales off this.
    public var intensity: Double
    /// Which named tier we landed in. Effects may switch behaviour, not just scale.
    public var tier: CelebrationTier
    /// Where on screen the checkbox was, in the overlay window's coordinate space
    /// (origin top-left, points). Particles fire from here.
    public var origin: CGPoint
    /// Deterministic seed. Same seed + same config == same frames, forever.
    public var seed: UInt64
    /// Context, for effects that want it.
    public var taskIndex: Int      // 0-based index of the task completed today
    public var taskCount: Int      // total tasks today
    public var remaining: Int      // tasks still open after this one
    public var streakDays: Int     // consecutive days with a full clear, before today
    public var source: String      // which client reported the completion

    public init(intensity: Double = 0.5,
                tier: CelebrationTier = .standard,
                origin: CGPoint = .zero,
                seed: UInt64 = 0x9E3779B97F4A7C15,
                taskIndex: Int = 0,
                taskCount: Int = 1,
                remaining: Int = 0,
                streakDays: Int = 0,
                source: String = "me") {
        self.intensity = intensity
        self.tier = tier
        self.origin = origin
        self.seed = seed
        self.taskIndex = taskIndex
        self.taskCount = taskCount
        self.remaining = remaining
        self.streakDays = streakDays
        self.source = source
    }
}

public enum CelebrationTier: String, Codable, CaseIterable, Sendable {
    case standard      // an ordinary task, mid-list
    case building      // deep into the list, momentum
    case finalTask     // the last open task of the day — the ring closing
    case streak        // final task AND a live streak — the biggest thing we do
}

// MARK: - Simulation

/// A single drawable particle. Kept flat and value-typed so stepping is fast and
/// the whole system is trivially snapshot-able for frame-accurate comparison.
public struct Particle: Equatable, Sendable {
    public var position: CGPoint
    public var velocity: CGVector
    public var rotation: Double          // radians
    public var angularVelocity: Double
    public var size: CGSize
    public var colorIndex: Int           // index into the palette
    public var shape: ParticleShape
    public var age: Double               // seconds since spawn
    public var lifetime: Double          // seconds until dead
    public var drag: Double
    public var mass: Double
    /// 0...1, drives foreshortening on rectangles so confetti reads as thin 3D card.
    public var flip: Double
    public var flipSpeed: Double

    public var isAlive: Bool { age < lifetime }
    /// 0 at spawn, 1 at death.
    public var progress: Double { lifetime > 0 ? min(1, age / lifetime) : 1 }

    public init(position: CGPoint, velocity: CGVector, rotation: Double = 0,
                angularVelocity: Double = 0, size: CGSize = CGSize(width: 8, height: 12),
                colorIndex: Int = 0, shape: ParticleShape = .rectangle, age: Double = 0,
                lifetime: Double = 1.2, drag: Double = 0.98, mass: Double = 1,
                flip: Double = 0, flipSpeed: Double = 0) {
        self.position = position; self.velocity = velocity; self.rotation = rotation
        self.angularVelocity = angularVelocity; self.size = size; self.colorIndex = colorIndex
        self.shape = shape; self.age = age; self.lifetime = lifetime; self.drag = drag
        self.mass = mass; self.flip = flip; self.flipSpeed = flipSpeed
    }
}

public enum ParticleShape: Int, Codable, Sendable {
    case rectangle, circle, ribbon, spark, star
}

/// Anything that can be stepped and drawn. Every visual layer of the celebration
/// (confetti, sparks, shockwave, flash, text) conforms.
public protocol CelebrationLayer {
    /// Advance by a fixed timestep. Never reads the clock.
    mutating func step(dt: Double)
    /// Draw the current state. Never mutates.
    func draw(in context: inout GraphicsContext, size: CGSize)
    /// True once this layer will never draw anything again.
    var isFinished: Bool { get }
}

/// The whole celebration: an ordered stack of layers driven by one clock.
public struct CelebrationScene {
    public private(set) var elapsed: Double = 0
    public var config: CelebrationConfig
    public var layers: [any CelebrationLayer]

    public init(config: CelebrationConfig, layers: [any CelebrationLayer]) {
        self.config = config
        self.layers = layers
    }

    /// Fixed-step advance. Callers that need to hit an arbitrary time should call
    /// this repeatedly with a constant dt rather than passing a variable dt, so the
    /// live overlay and the offscreen renderer produce identical results.
    public mutating func step(dt: Double) {
        elapsed += dt
        for i in layers.indices { layers[i].step(dt: dt) }
    }

    public func draw(in context: inout GraphicsContext, size: CGSize) {
        for layer in layers { layer.draw(in: &context, size: size) }
    }

    public var isFinished: Bool { layers.allSatisfy(\.isFinished) }
}

/// The fixed simulation timestep. 240 Hz: fine enough that a 120 Hz ProMotion
/// display gets two sub-steps per frame, which keeps fast particles smooth.
public let celebrationTimestep: Double = 1.0 / 240.0

// MARK: - Deterministic randomness

/// splitmix64. Fast, good enough, and identical on every run.
public struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { self.state = seed &+ 0x9E3779B97F4A7C15 }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    public mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }
    /// Uniform in lo..<hi.
    public mutating func range(_ lo: Double, _ hi: Double) -> Double {
        lo + unit() * (hi - lo)
    }
    /// Approximately normal, mean 0, sd 1 (sum of 4 uniforms, cheap and stable).
    public mutating func gaussian() -> Double {
        (unit() + unit() + unit() + unit() - 2.0) * 1.7320508
    }
}

// MARK: - Palette

/// The celebration palette. Index into this with `Particle.colorIndex`.
/// Defined once here; every layer reads it, none redefine it.
public enum BangerPalette {
    public static let confetti: [Color] = [
        Color(red: 0.05, green: 0.85, blue: 0.75),   // accent teal
        Color(red: 1.00, green: 0.78, blue: 0.12),
        Color(red: 1.00, green: 0.30, blue: 0.42),
        Color(red: 0.45, green: 0.55, blue: 1.00),
        Color(red: 0.70, green: 1.00, blue: 0.35),
        Color(red: 1.00, green: 1.00, blue: 1.00),
    ]
    public static let accent = Color(red: 0.05, green: 0.85, blue: 0.75)
}
