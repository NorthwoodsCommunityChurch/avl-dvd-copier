import Foundation

struct AudioCDTrack: Identifiable, Equatable {
    let id: Int              // track number (1-based)
    let filename: String     // "01 Track 01.aiff"
    let duration: String     // "3:45"
    let durationSeconds: Int
    let sizeBytes: Int64
    let sizeLabel: String    // "42.3 MB"
    let outputName: String   // "01 Track 01.wav"

    static func == (lhs: AudioCDTrack, rhs: AudioCDTrack) -> Bool {
        lhs.id == rhs.id
    }
}
