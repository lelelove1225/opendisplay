import Foundation

enum ReceiverEndpoint {
    // A suspended App Store app can retain port 9000. Both halves of a local
    // build must agree on 9100, including a plain launch without arguments.
    #if DEBUG
    static let port: UInt16 = 9100
    #else
    static let port: UInt16 = 9000
    #endif
}
