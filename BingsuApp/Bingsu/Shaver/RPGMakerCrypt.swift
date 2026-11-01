import Foundation

/// RPG Maker MV·MZ 암호화 리소스(`.rpgmvp`·`.png_` 등) 풀기 — 게임칩 표지용으로만 쓴다(게임 실행 중에는 게임이 스스로 푼다).
/// 형식: 머리 16바이트(`RPGMV` + 0 … , 엔진 Decrypter 의 SIGNATURE·VER·REMAIN) 다음 16바이트가 `System.json` 의
/// `encryptionKey`(16진수 32글자)로 XOR 돼 있고, 나머지는 원본 그대로.
enum RPGMakerCrypt {
    static let headerLength = 16

    static func decrypt(_ data: Data, keyHex: String) -> Data? {
        guard data.count > headerLength * 2, data.prefix(5) == Data("RPGMV".utf8), let key = keyBytes(keyHex) else { return nil }
        var body = Data(data.dropFirst(headerLength))
        for i in 0..<headerLength { body[body.startIndex + i] ^= key[i] }
        return body
    }

    static func keyBytes(_ hex: String) -> [UInt8]? {
        let chars = Array(hex)
        guard chars.count == 32 else { return nil }
        var out: [UInt8] = []
        for i in stride(from: 0, to: 32, by: 2) {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            out.append(b)
        }
        return out
    }
}
