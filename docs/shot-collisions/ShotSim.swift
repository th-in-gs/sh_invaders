#!/usr/bin/env swift
// What happens when the player's shot meets an invader shot in the arcade
// Space Invaders? Simulated pixel by pixel with the ROM's sprites and
// drawing routines, from the computerarcheology.com disassembly. See
// README.md alongside for the reasoning and results.
//
// Run: ./ShotSim.swift
//
// Screen: video memory as the arcade lays it out (one 32-byte line per x,
// pixel y at bit y&7 of byte y>>3, so bit 0 is at the bottom), drawn through
// an emulated hardware shift register by the arcade's three routines:
//   1400 DrawShiftedSprite  OR onto the screen
//   1452 EraseShifted       AND with the inverted sprite
//   1491 DrawSprCollision   OR, setting 2061 if any bit lands on a lit one
// (Lines are 64 bytes here so shots can't run off the top.)
//
// Player shot (object 1, once a frame, before the invader shots):
//   starts at y 0x28 (1B29) and moves +4 (1B2C) a frame: erase, move, draw
//   with collision (040A). A collision makes the main loop (0822 -> 190A ->
//   14D8) set status 3; the next run (03D7-03F7) erases the shot and draws
//   the explosion 1C91 at x-3, y-2; the timer (from 0x10) ends it 15 runs
//   later, erasing it (0436).
// Invader shot (one move every third frame, 05C1):
//   erase, next picture, move by 207E (FC = -4; FB = -5 with 8 or fewer
//   invaders: 08D8), draw with collision; a collision starts it blowing up.
//   Blowing up (0644), also one run every third frame: the blow-up count
//   (4) drops to 3 on the next run, which erases the shot and draws the
//   explosion 1CDC at x-2, y-2; at 0, three runs later, it is erased.
//
// Alignment. The player shot is always at 0x28 + 4k. An invader shot
// starts 10 px below its invader (05B1), whose y is a multiple of 8 (rack
// start heights 78 60 50 48 48 48 40 40 40, rows 16 apart, drops of 8), so
// it starts at 2 mod 4, and is first drawn one step later with picture 1
// (pictures advance one per step). So:
//   normal speed: invader y - player y is always 2 mod 4;
//   fast speed:   picture + (invader y - player y) is always 2 mod 4.

let squiggly: [[UInt8]] = [[0x44, 0xAA, 0x10], [0x88, 0x54, 0x22], [0x10, 0xAA, 0x44], [0x22, 0x54, 0x88]] // 1CD0
let plunger: [[UInt8]] = [[0x04, 0xFC, 0x04], [0x10, 0xFC, 0x10], [0x20, 0xFC, 0x20], [0x80, 0xFC, 0x80]]  // 1CE2
let rolling: [[UInt8]] = [[0x00, 0xFE, 0x00], [0x24, 0xFE, 0x12], [0x00, 0xFE, 0x00], [0x48, 0xFE, 0x90]]  // 1CEE
let shotTypes = [("squiggly", squiggly), ("plunger", plunger), ("rolling", rolling)]
let playerShot: [UInt8] = [0x0F]                                              // 1C90
let playerExplosion: [UInt8] = [0x99, 0x3C, 0x7E, 0x3D, 0xBC, 0x3E, 0x7C, 0x99] // 1C91
let invaderExplosion: [UInt8] = [0x4A, 0x15, 0xBE, 0x3F, 0x5E, 0x25]           // 1CDC

struct Screen {
    static let stride = 64
    var mem = [UInt8](repeating: 0, count: 224 * Screen.stride)
    var shiftData: UInt16 = 0
    var shiftAmount = 0

    mutating func shift(_ byte: UInt8) -> UInt8 {
        shiftData = shiftData >> 8 | UInt16(byte) << 8
        return UInt8(truncatingIfNeeded: shiftData >> (8 - shiftAmount))
    }

    // Each sprite byte covers two screen bytes on its line.
    mutating func blit(_ sprite: [UInt8], _ x: Int, _ y: Int, _ op: (inout UInt8, UInt8) -> Void) {
        shiftAmount = y & 7
        for (i, byte) in sprite.enumerated() {
            let a = (x + i) * Screen.stride + y >> 3
            op(&mem[a], shift(byte))
            op(&mem[a + 1], shift(0))
        }
    }

    mutating func draw(_ s: [UInt8], _ x: Int, _ y: Int) { blit(s, x, y) { $0 |= $1 } }
    mutating func erase(_ s: [UInt8], _ x: Int, _ y: Int) { blit(s, x, y) { $0 &= ~$1 } }
    mutating func drawCollision(_ s: [UInt8], _ x: Int, _ y: Int) -> Bool {
        var hit = false
        blit(s, x, y) { if $0 & $1 != 0 { hit = true }; $0 |= $1 }
        return hit
    }
}

enum State { case moving, hit, exploding, gone }

struct Outcome: Hashable { let playerLives: Bool; let invaderLives: Bool }

// One meeting: the player's shot on line dx of the invader shot (0-2 are its
// lines), gap px below it, the invader shot showing picture pic and moving
// after tick more frames. Followed until neither shot can affect the other.
func meet(_ pics: [[UInt8]], dx: Int, gap: Int, pic startPic: Int, tick startTick: Int, step: Int) -> Outcome {
    var screen = Screen()
    var px = 100 + dx, py = 100
    var ax = 100, ay = 120 + gap
    var pic = startPic, tick = startTick
    var player = State.moving, playerTimer = 0x10
    var invader = State.moving, blowCount = 4
    screen.draw(playerShot, px, py)
    screen.draw(pics[pic], ax, ay)

    for _ in 0..<200 {
        switch player {
        case .moving:
            screen.erase(playerShot, px, py)
            py += 4
            if screen.drawCollision(playerShot, px, py) { player = .hit }
        case .hit:
            playerTimer -= 1
            screen.erase(playerShot, px, py)
            px -= 3; py -= 2
            screen.draw(playerExplosion, px, py)
            player = .exploding
        case .exploding:
            playerTimer -= 1
            if playerTimer == 0 { screen.erase(playerExplosion, px, py); player = .gone }
        case .gone:
            break
        }

        if tick > 0 {
            tick -= 1
        } else {
            tick = 2
            switch invader {
            case .moving:
                screen.erase(pics[pic], ax, ay)
                pic = (pic + 1) % 4
                ay -= step
                if screen.drawCollision(pics[pic], ax, ay) { invader = .hit }
            case .hit, .exploding:
                blowCount -= 1
                if blowCount == 3 {
                    screen.erase(pics[pic], ax, ay)
                    ax -= 2; ay -= 2
                    screen.draw(invaderExplosion, ax, ay)
                    invader = .exploding
                } else if blowCount == 0 {
                    screen.erase(invaderExplosion, ax, ay)
                    invader = .gone
                }
            case .gone:
                break
            }
        }

        let playerSettled = player == .gone || (player == .moving && py > ay + 16)
        let invaderSettled = invader == .gone || invader == .moving
        if playerSettled && invaderSettled {
            return Outcome(playerLives: player == .moving, invaderLives: invader == .moving)
        }
    }
    fatalError("meeting never settled")
}

// Alignments, as (gap, picture) pairs; every one is run at each tick phase.
// The shots close by 12 + step px every 3 frames, and at fast speed the
// picture comes round every 4 steps, so these cover whole periods.
func alignments(step: Int, arcade: Bool) -> [(Int, Int)] {
    var result: [(Int, Int)] = []
    for gap in 0..<(4 * (12 + step)) {
        for pic in 0..<4 {
            let residue = (120 + gap - 100) % 4
            if arcade && step == 4 && residue != 2 { continue }
            if arcade && step == 5 && (pic + residue) % 4 != 2 { continue }
            result.append((gap, pic))
        }
    }
    return result
}

// Outcome percentages; lineWeights gives the weight of each player-shot line
// (0-2) and of shots that are horizontally clear of each other (nil).
func run(_ pics: [[UInt8]], step: Int, arcade: Bool, lineWeights: [(Int?, Double)]) -> [Outcome: Double] {
    var totals: [Outcome: Double] = [:]
    let aligns = alignments(step: step, arcade: arcade)
    for (dx, weight) in lineWeights {
        let share = weight / Double(aligns.count * 3)
        for (gap, pic) in aligns {
            for tick in 0..<3 {
                let o = dx.map { meet(pics, dx: $0, gap: gap, pic: pic, tick: tick, step: step) }
                    ?? Outcome(playerLives: true, invaderLives: true)
                totals[o, default: 0] += share
            }
        }
    }
    let sum = totals.values.reduce(0, +)
    return totals.mapValues { 100 * $0 / sum }
}

let columns: [(String, Outcome)] = [
    ("both carry on", Outcome(playerLives: true, invaderLives: true)),
    ("invader survives", Outcome(playerLives: false, invaderLives: true)),
    ("player survives", Outcome(playerLives: true, invaderLives: false)),
    ("both destroyed", Outcome(playerLives: false, invaderLives: false)),
]

func pad(_ s: String, _ n: Int) -> String { String(repeating: " ", count: max(0, n - s.count)) + s }
func pct(_ v: Double) -> String { let t = (v * 10).rounded() / 10; return "\(t)%" }

func report(_ title: String, arcade: Bool, lineWeights: [(Int?, Double)]) {
    print("--- \(title)")
    print(pad("", 15) + columns.map { pad($0.0, 18) }.joined())
    for step in [4, 5] {
        for (name, pics) in shotTypes {
            let r = run(pics, step: step, arcade: arcade, lineWeights: lineWeights)
            print(pad("\(step)px \(name)", 15) + columns.map { pad(pct(r[$0.1] ?? 0), 18) }.joined())
        }
    }
}

let contact: [(Int?, Double)] = [(0, 1), (1, 1), (2, 1)]
// In the game both shots are only known to be in the same 4-px column. In
// the arcade, for a player shot anywhere along a stretch of w px, it is on
// one of the invader shot's 3 lines with chance 3/w, and in the same 4-px
// column with chance 4/w. So per same-column meeting: each line 1/4, and
// 1/4 clear.
let sameColumn: [(Int?, Double)] = [(0, 1), (1, 1), (2, 1), (nil, 1)]

report("player shot on one of the invader shot's lines; any alignment (as before)", arcade: false, lineWeights: contact)
report("player shot on one of the invader shot's lines; arcade alignments only", arcade: true, lineWeights: contact)
report("same 4-px column; arcade alignments only (rates for the game)", arcade: true, lineWeights: sameColumn)

// How much the conclusions depend on the alignment: invader-shot survival,
// out of meetings where the shots touched, for each vertical residue.
print("--- invader shot survives a touch, by (invader y - player y) mod 4; normal speed")
for (name, pics) in shotTypes {
    var line = pad(name, 15)
    for residue in 0..<4 {
        var survived = 0, touched = 0
        for dx in 0..<3 {
            for gap in stride(from: residue, to: 64, by: 4) {
                for pic in 0..<4 {
                    for tick in 0..<3 {
                        let o = meet(pics, dx: dx, gap: gap, pic: pic, tick: tick, step: 4)
                        if o.playerLives && o.invaderLives { continue }
                        touched += 1
                        if o.invaderLives { survived += 1 }
                    }
                }
            }
        }
        line += pad("\(residue): \(pct(100 * Double(survived) / Double(touched)))", 18)
    }
    print(line)
}
