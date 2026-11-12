import Foundation
import Testing
@testable import TRClick

@MainActor
struct MessageSecurityTests {
    private struct Payload: Codable, Equatable {
        let action: String
        let target: String
        let skipConfirmation: Bool
    }

    @Test func onlyAuthenticatedBytesBecomeTheExecutedPayload() throws {
        let original = Payload(action: "copy-path", target: "/tmp/original", skipConfirmation: false)
        let signed = try MessageSecurity.sign(original)
        let altered = SignedPayload(
            payload: Payload(action: "delete-direct", target: "/tmp/other", skipConfirmation: true),
            signature: signed.signature, jsonData: signed.jsonData
        )

        let result: Payload? = Messager.shared.decodeSignedData(try JSONEncoder().encode(altered))

        #expect(result == original)
    }

    @Test func alteringAuthenticatedBytesIsRejected() throws {
        let original = Payload(action: "copy-path", target: "/tmp/original", skipConfirmation: false)
        let signed = try MessageSecurity.sign(original)
        let changed = Payload(action: "delete-direct", target: "/tmp/other", skipConfirmation: true)
        let altered = SignedPayload(payload: changed, signature: signed.signature,
            jsonData: try JSONEncoder().encode(changed).base64EncodedString())

        let result: Payload? = Messager.shared.decodeSignedData(try JSONEncoder().encode(altered))

        #expect(result == nil)
    }
}
