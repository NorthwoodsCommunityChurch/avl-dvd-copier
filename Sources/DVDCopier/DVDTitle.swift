import Foundation

struct DVDTitle: Identifiable, Equatable {
    let id: Int           // makemkvcon title index (0-based)
    let duration: String  // "1:18:58"
    let durationSeconds: Int
    let chapters: Int
    let sizeBytes: Int64
    let sizeLabel: String // "4.1 GB"
    let outputName: String // suggested filename from makemkvcon
    let description: String // "19 chapter(s) , 4.1 GB (B1)"

    static func == (lhs: DVDTitle, rhs: DVDTitle) -> Bool {
        lhs.id == rhs.id
    }
}
