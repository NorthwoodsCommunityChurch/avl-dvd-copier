import Foundation

enum DiscType: Equatable {
    case none
    case dvd
    case dvdFallback  // MakeMKV failed, using ffmpeg to rip VOBs
    case audioCD
    case dataCD
}
