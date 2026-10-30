import XCTest
@testable import ClickAssistCore

/// Replays ring episodes captured from the real log. Each fixture is a pointer +
/// the frame that was indicated, so the invariants are the user's own rules:
///   * direct-hit  -> the pointer must be inside the frame (margin 8, Chromium
///                    frames are offset 1-2 pt), i.e. the ring is on what was hit;
///   * redirect    -> the pointer must be within the assist tolerance of the frame;
///   * every fixture must parse — a malformed episode is a corpus regression.
final class ClickAssistFixtureReplayTests: XCTestCase {

    private struct Fixture { let frame: CGRect; let pointer: CGPoint; let mode: String; let weak: String }

    private func fixtures() throws -> [Fixture] {
        let here = URL(fileURLWithPath: #filePath)
        let path = here.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ring_episodes.jsonl")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            throw XCTSkip("fixtures not generated: \(path.path)")
        }
        return text.split(separator: "\n").compactMap { line -> Fixture? in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let frameStr = obj["frame"] as? String,
                  let pointerStr = obj["pointer"] as? String,
                  let frame = parseRect(frameStr), let pointer = parsePoint(pointerStr)
            else { return nil }
            return Fixture(frame: frame, pointer: pointer,
                           mode: obj["mode"] as? String ?? "-",
                           weak: obj["weak"] as? String ?? "-")
        }
    }

    private func parseRect(_ s: String) -> CGRect? {
        let nums = s.trimmingCharacters(in: CharacterSet(charactersIn: "()")).split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard nums.count == 4 else { return nil }
        return CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
    }

    private func parsePoint(_ s: String) -> CGPoint? {
        let nums = s.trimmingCharacters(in: CharacterSet(charactersIn: "()")).split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard nums.count == 2 else { return nil }
        return CGPoint(x: nums[0], y: nums[1])
    }

    func testCapturedEpisodesRespectTheirInvariant() throws {
        let all = try fixtures()
        XCTAssertGreaterThan(all.count, 50, "corpus too small to mean anything")
        var directHits = 0, redirects = 0
        for f in all where f.mode == "direct-hit" {
            directHits += 1
            XCTAssertTrue(f.frame.insetBy(dx: -8, dy: -8).contains(f.pointer),
                          "direct-hit ring off its frame: \(f.frame) pointer \(f.pointer)")
        }
        for f in all where f.mode != "direct-hit" {
            redirects += 1
            XCTAssertLessThanOrEqual(DecisionCore.boundaryDistance(f.pointer, f.frame), 16.5,
                                     "redirect ring beyond tolerance: \(f.frame) pointer \(f.pointer)")
        }
        XCTAssertGreaterThan(directHits, 0)
        print("replayed \(all.count) episodes: direct-hit \(directHits), redirect \(redirects)")
    }
}
