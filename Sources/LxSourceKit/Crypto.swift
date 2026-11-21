import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Backing implementation for `lx.utils.crypto` as exposed by Q-music's
/// `src/main/modules/userApi/renderer/preload.js` (Node crypto underneath).
enum LxCrypto {

  static func md5Hex(_ input: String) -> String {
    Insecure.MD5.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// Node: `createCipheriv(mode, key, iv)` — PKCS#7 padding is applied by
  /// default, and scripts hand the output straight into signed HTTP bodies, so
  /// the padding behaviour has to match Node's byte for byte.
  static func aesEncrypt(data: Data, mode: String, key: Data, iv: Data?) throws -> Data {
    let parts = mode.lowercased().split(separator: "-")
    guard parts.count == 3, parts[0] == "aes" else { throw LxError.crypto("unsupported aes mode: \(mode)") }
    let cipherMode = String(parts[2])

    let algorithm = CCAlgorithm(kCCAlgorithmAES)
    var options = CCOptions(0)
    switch cipherMode {
    case "ecb": options |= CCOptions(kCCOptionECBMode)
    case "cbc": break
    default: throw LxError.crypto("unsupported aes cipher: \(cipherMode)")
    }

    let padded = pkcs7Pad(data, blockSize: kCCBlockSizeAES128)
    var out = Data(count: padded.count + kCCBlockSizeAES128)
    var moved = 0

    let status = key.withUnsafeBytes { keyPtr -> CCCryptorStatus in
      padded.withUnsafeBytes { dataPtr -> CCCryptorStatus in
        out.withUnsafeMutableBytes { outPtr -> CCCryptorStatus in
          let ivPtr = iv?.withUnsafeBytes { $0.baseAddress } ?? nil
          return CCCrypt(
            CCOperation(kCCEncrypt), algorithm, options,
            keyPtr.baseAddress, key.count,
            ivPtr,
            dataPtr.baseAddress, padded.count,
            outPtr.baseAddress, outPtr.count,
            &moved
          )
        }
      }
    }
    guard status == kCCSuccess else { throw LxError.crypto("aes failed: status \(status)") }
    return out.prefix(moved)
  }

  static func randomBytes(_ count: Int) -> Data {
    var data = Data(count: count)
    _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
    return data
  }

  /// Node: `publicEncrypt({ key, padding: RSA_NO_PADDING }, buf)` after the
  /// caller left-pads to the modulus size.
  static func rsaEncryptRaw(data: Data, pem: String) throws -> Data {
    let der = try pemToDER(pem)
    var key = try? makePublicKey(der)
    if key == nil, let pkcs1 = pkcs1FromSPKI(der) {
      key = try? makePublicKey(pkcs1)
    }
    guard let publicKey = key else { throw LxError.crypto("unsupported RSA public key format") }

    let blockSize = SecKeyGetBlockSize(publicKey)
    guard data.count <= blockSize else { throw LxError.crypto("rsa input too long") }
    let padded = Data(count: blockSize - data.count) + data

    var error: Unmanaged<CFError>?
    guard let cipher = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionRaw, padded as CFData, &error) else {
      throw LxError.crypto("rsa encrypt failed: \(error?.takeRetainedValue().localizedDescription ?? "?")")
    }
    return cipher as Data
  }

  // MARK: - helpers

  private static func pkcs7Pad(_ data: Data, blockSize: Int) -> Data {
    let remainder = data.count % blockSize
    let pad = blockSize - remainder
    return data + Data(repeating: UInt8(pad), count: pad)
  }

  private static func makePublicKey(_ der: Data) throws -> SecKey {
    let attrs: [CFString: Any] = [
      kSecAttrKeyType: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass: kSecAttrKeyClassPublic,
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &error) else {
      throw LxError.crypto("SecKeyCreateWithData failed: \(error?.takeRetainedValue().localizedDescription ?? "?")")
    }
    return key
  }

  private static func pemToDER(_ pem: String) throws -> Data {
    let b64 = pem
      .split(separator: "\n")
      .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .joined()
    guard let der = Data(base64Encoded: b64) else { throw LxError.crypto("invalid PEM body") }
    return der
  }

  /// SubjectPublicKeyInfo -> PKCS#1 RSAPublicKey (strip the BIT STRING wrapper).
  private static func pkcs1FromSPKI(_ der: Data) -> Data? {
    let bytes = [UInt8](der)
    // SEQUENCE { AlgorithmIdentifier, BIT STRING { RSAPublicKey } }
    guard let outer = derLength(bytes, 0), let algorithm = derLength(bytes, outer.content) else { return nil }
    let bitString = algorithm.content
    guard bitString < bytes.count, bytes[bitString] == 0x03,
          let payload = derLength(bytes, bitString + 1) else { return nil }
    // First content byte is the "unused bits" count (always 0 for DER keys).
    let start = payload.content
    let end = start + payload.length
    guard start < end, end <= bytes.count, bytes[start] == 0x00 else { return nil }
    return Data(bytes[(start + 1)..<end])
  }

  /// Returns the content length and the offset where the content starts.
  private static func derLength(_ bytes: [UInt8], _ index: Int) -> (length: Int, content: Int)? {
    guard index + 1 < bytes.count else { return nil }
    var cursor = index + 1
    var length = Int(bytes[cursor])
    if length & 0x80 != 0 {
      let count = length & 0x7F
      guard count <= 4, cursor + count < bytes.count else { return nil }
      cursor += 1
      length = 0
      for _ in 0..<count {
        length = (length << 8) | Int(bytes[cursor])
        cursor += 1
      }
      return (length, cursor)
    }
    return (length, cursor + 1)
  }
}

public enum LxError: LocalizedError {
  case crypto(String)
  case bridge(String)
  case http(String)

  public var errorDescription: String? {
    switch self {
    case .crypto(let m): return "crypto: \(m)"
    case .bridge(let m): return "bridge: \(m)"
    case .http(let m): return "http: \(m)"
    }
  }
}
