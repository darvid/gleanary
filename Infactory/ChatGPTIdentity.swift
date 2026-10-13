import CryptoKit
import Foundation
import Security

struct VerifiedChatGPTIdentity: Sendable {
    let subject: String
    let email: String?
}

protocol ChatGPTIdentityVerifying: Sendable {
    func verify(_ token: String, clientID: String, nonce: String?) async throws
        -> VerifiedChatGPTIdentity
}

struct OpenAIIdentityVerifier: ChatGPTIdentityVerifying {
    let transport: any ChatGPTTransporting

    func verify(
        _ token: String,
        clientID: String,
        nonce: String?
    ) async throws -> VerifiedChatGPTIdentity {
        let (data, response) = try await transport
            .data(
                for: URLRequest(url: URL(string: "https://auth.openai.com/.well-known/jwks.json")!)
            )
        guard response.statusCode == 200 else { throw ChatGPTError.invalidIdentity }
        return try Self.validate(token, clientID: clientID, nonce: nonce, jwks: data)
    }

    static func validate(
        _ token: String,
        clientID: String,
        nonce: String?,
        jwks: Data,
        now: Date = Date()
    ) throws -> VerifiedChatGPTIdentity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, token.utf8.count <= 32000,
              let headerData = OAuthEncoding.decode(String(parts[0])),
              let claimsData = OAuthEncoding.decode(String(parts[1])),
              let signature = OAuthEncoding.decode(String(parts[2])),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String,
              let keySet = try JSONSerialization.jsonObject(with: jwks) as? [String: Any],
              let keys = keySet["keys"] as? [[String: Any]],
              let jwk = keys
              .first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }),
              jwk["use"] == nil || jwk["use"] as? String == "sig",
              jwk["alg"] == nil || jwk["alg"] as? String == "RS256",
              let n = jwk["n"] as? String, let e = jwk["e"] as? String,
              let modulus = OAuthEncoding.decode(n), (128 ... 1024).contains(modulus.count),
              let exponent = OAuthEncoding.decode(e), (1 ... 8).contains(exponent.count),
              let key = SecKeyCreateWithData(
                  RSAPublicKeyDER.encode(modulus: modulus, exponent: exponent) as CFData,
                  [
                      kSecAttrKeyType: kSecAttrKeyTypeRSA,
                      kSecAttrKeyClass: kSecAttrKeyClassPublic,
                  ] as CFDictionary,
                  nil
              ),
              SecKeyVerifySignature(
                  key,
                  .rsaSignatureMessagePKCS1v15SHA256,
                  Data("\(parts[0]).\(parts[1])".utf8) as CFData,
                  signature as CFData,
                  nil
              ),
              let claims = try JSONSerialization.jsonObject(with: claimsData) as? [String: Any],
              claims["iss"] as? String == "https://auth.openai.com",
              let subject = claims["sub"] as? String, !subject.isEmpty,
              let expiry = claims["exp"] as? Double, expiry.isFinite,
              expiry > now.timeIntervalSince1970,
              nonce == nil || claims["nonce"] as? String == nonce
        else { throw ChatGPTError.invalidIdentity }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String)
            .map { [$0] } ?? []
        guard audiences.contains(clientID),
              audiences.count == 1 || claims["azp"] as? String == clientID,
              (claims["nbf"] as? Double ?? 0) <= now.timeIntervalSince1970 + 60,
              (claims["iat"] as? Double ?? 0) <= now.timeIntervalSince1970 + 60
        else { throw ChatGPTError.invalidIdentity }
        return VerifiedChatGPTIdentity(subject: subject, email: claims["email"] as? String)
    }
}

enum OAuthEncoding {
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        else { throw ChatGPTError.invalidIdentity }
        return encode(Data(bytes))
    }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        guard text.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
        else { return nil }
        let base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
            of: "_",
            with: "/"
        )
        return Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }

    static func form(_ values: [String: String]) -> Data {
        let allowed =
            CharacterSet(
                charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
            )
        return Data(values.keys.sorted().map { key in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")=\(values[key]?.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").utf8)
    }

    static func challenge(_ verifier: String)
        -> String
    {
        encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

enum RSAPublicKeyDER {
    static func encode(modulus: Data, exponent: Data) -> Data {
        let payload = integer(modulus) + integer(exponent)
        return Data([0x30]) + length(payload.count) + payload
    }

    private static func integer(_ bytes: Data) -> Data {
        let unsigned = bytes.drop(while: { $0 == 0 })
        let body = (unsigned.first ?? 0) & 0x80 == 0 ? Data(unsigned) : Data([0]) + unsigned
        return Data([0x02]) + length(body.count) + body
    }

    private static func length(_ count: Int) -> Data {
        if count < 128 {
            return Data([UInt8(count)])
        }
        if count <= 255 {
            return Data([0x81, UInt8(count)])
        }
        return Data([0x82, UInt8(count >> 8), UInt8(count & 255)])
    }
}
