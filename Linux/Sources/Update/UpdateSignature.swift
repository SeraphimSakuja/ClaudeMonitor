import Foundation
import Crypto

/// Die Ed25519-Signatur des Manifests `linux-latest.json` (CM-36 · FE-1, FE-2)
/// — reiner Werttyp, kein Dateizugriff, kein Netz.
///
/// **Signiert sind Bytes, nicht JSON-Werte.** Die ausgelieferte Datei ist
/// `F = P + T`: `P` ist das Dokument ohne sein Ende `"\n}\n"`, `T` der Trailer
///
///     ,\n  "signature": "<88 Zeichen Standard-Base64 von 64 Byte>"\n}\n
///
/// mit fester Länge ``trailerLength``, **vom Dateiende** abgemessen und nie
/// gesucht. Signiert und danach ausgewertet ist `D = P + "\n}\n"` — genau die
/// Datei, die `scripts/release-linux.sh` unsigniert schreibt. Ein zweiter
/// Schlüssel `signature` irgendwo in `P` ist deshalb bedeutungslos.
///
/// ⚠️ **Eingefrorener Client-Vertrag** ab der ersten Auslieferung, wie das
/// Schema: `scripts/sign-linux-manifest.sh` erzeugt den Trailer in genau dieser
/// Form, und jeder installierte Client misst ihn so. Eine andere Form hieße:
/// Alle installierten Clients lehnen jedes Update mit 13 ab.
public enum UpdateSignature {

    /// Der Anfang des Trailers bis zum ersten Zeichen der Signatur.
    static let trailerPrefix = Array(",\n  \"signature\": \"".utf8)
    /// Das Ende des Trailers — schließt Signatur, Objekt und Datei.
    static let trailerSuffix = Array("\"\n}\n".utf8)
    /// Das Ende des signierten Dokuments `D`.
    static let documentEnd = Array("\n}\n".utf8)
    /// Länge der Base64-Signatur: 64 Byte ergeben 88 Zeichen mit `==`.
    static let encodedSignatureLength = 88
    /// Feste Länge des Trailers in Byte (110).
    public static let trailerLength = trailerPrefix.count + encodedSignatureLength + trailerSuffix.count

    /// Der Trailer zu einer Signatur — die EINE Quelle des Formats auf der
    /// Client-Seite.
    public static func trailer(signature: Data) -> Data {
        Data(trailerPrefix) + Data(signature.base64EncodedString().utf8) + Data(trailerSuffix)
    }

    /// Prüft die Signatur der Datei `file` gegen `trustedKey` (Base64 des
    /// 32-Byte-Public-Keys) und liefert bei Erfolg das **signierte Dokument**
    /// `D` — nur das wird danach als JSON gelesen.
    ///
    /// * kürzer als der Trailer oder Trailer formfremd (auch
    ///   `"signature": null`) ⇒ ``UpdateManifest/Rejection/signatureMissing``;
    /// * Form stimmt, Prüfung scheitert (auch: Base64 ergibt nicht 64 Byte,
    ///   Schlüssel unlesbar) ⇒ ``UpdateManifest/Rejection/signatureInvalid``.
    public static func signedDocument(of file: Data, trustedKey: String) -> Result<Data, UpdateManifest.Rejection> {
        let bytes = [UInt8](file)
        guard bytes.count >= trailerLength else { return .failure(.signatureMissing) }

        let trailerStart = bytes.count - trailerLength
        let signatureStart = trailerStart + trailerPrefix.count
        let signatureEnd = signatureStart + encodedSignatureLength
        guard Array(bytes[trailerStart..<signatureStart]) == trailerPrefix,
              Array(bytes[signatureEnd...]) == trailerSuffix else {
            return .failure(.signatureMissing)
        }
        let encoded = bytes[signatureStart..<signatureEnd]
        guard encoded.allSatisfy(isBase64Character) else { return .failure(.signatureMissing) }

        guard let signature = Data(base64Encoded: Data(encoded)), signature.count == 64,
              let keyBytes = Data(base64Encoded: trustedKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else {
            return .failure(.signatureInvalid)
        }
        let document = Data(bytes[..<trailerStart] + documentEnd)
        guard key.isValidSignature(signature, for: document) else { return .failure(.signatureInvalid) }
        return .success(document)
    }

    /// Standard-Base64 (RFC 4648 §4) samt Füllzeichen.
    private static func isBase64Character(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "/"), UInt8(ascii: "="):
            return true
        default:
            return false
        }
    }
}
