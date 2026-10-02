import Foundation

/// Ein geprüftes Update-Angebot — nur aus ``UpdateManifest/validate(_:)``.
public struct UpdateOffer: Equatable, Sendable {
    /// Marketing-Version, etwa `1.0.3` — Anzeige und Mitgliedspfad.
    public let version: String
    /// Ganzzahlige Build-Nummer — die einzige Vergleichsgröße (FE 2).
    public let buildVersion: Int
    /// Download-Adresse, zeichengleich ``UpdateDecision/expectedURL(version:)``.
    public let url: String
    /// Erwartete Prüfsumme des Tarballs, 64 Hex-Zeichen.
    public let sha256: String
    /// Erwartete Größe des Tarballs in Byte.
    public let size: Int
    /// Kompatibilitätsboden glibc, etwa `2.38`.
    public let minimumGlibc: String

    public init(version: String, buildVersion: Int, url: String, sha256: String, size: Int, minimumGlibc: String) {
        self.version = version
        self.buildVersion = buildVersion
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.minimumGlibc = minimumGlibc
    }
}

/// Das Manifest `linux-latest.json` (Erzeuger: `scripts/release-linux.sh`,
/// Schritt 7/7) und seine Prüfung (FE 4–6).
///
/// Unbekannte Felder werden ignoriert — auch `measured`, `projectUrl` und
/// `signature`.
public enum UpdateManifest {

    /// Die einzige Schemafassung, die dieser Client liest (FE 4).
    ///
    /// Eigene Regel, NICHT die Schemafassung von `usage.json` (Leitplanke L4).
    public static let supportedSchemaVersion = 1

    /// Warum ein Manifest abgelehnt wurde. Jede Ablehnung endet mit 13.
    public enum Rejection: Error, Equatable, Sendable {
        /// Kein JSON-Objekt.
        case notJSON
        /// `schemaVersion` ist nicht 1 — das Format hat sich geändert.
        case formatChanged(found: String)
        /// Ein Pflichtfeld fehlt oder hat den falschen Typ.
        case missingField(String)
        /// `product` oder `platform` passt nicht zu diesem Binary.
        case wrongProduct(field: String, value: String)
        /// `version` ist keine reine Punkt-Zahl.
        case invalidVersion(String)
        /// `url` ist nicht zeichengleich die erwartete Adresse.
        case unexpectedURL(String)
        /// `sha256` sind keine 64 Hex-Zeichen.
        case invalidChecksum
        /// `size` ist nicht positiv.
        case invalidSize
        /// `minimum.glibc` ist keine reine Punkt-Zahl.
        case invalidFloor(String)
    }

    /// Prüft die Rohdaten. Reihenfolge: Schema zuerst — ein anderes Format
    /// wird als solches benannt, nicht als „Feld fehlt".
    public static func validate(_ data: Data) -> Result<UpdateOffer, Rejection> {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return .failure(.notJSON) }

        guard let schema = wire.schemaVersion else {
            return .failure(wire.hasSchemaVersionKey ? .formatChanged(found: "not an integer") : .missingField("schemaVersion"))
        }
        guard schema == supportedSchemaVersion else { return .failure(.formatChanged(found: String(schema))) }

        guard let product = wire.product else { return .failure(.missingField("product")) }
        guard let platform = wire.platform else { return .failure(.missingField("platform")) }
        guard let version = wire.version else { return .failure(.missingField("version")) }
        guard let buildVersion = wire.buildVersion else { return .failure(.missingField("buildVersion")) }
        guard let url = wire.url else { return .failure(.missingField("url")) }
        guard let sha256 = wire.sha256 else { return .failure(.missingField("sha256")) }
        guard let size = wire.size else { return .failure(.missingField("size")) }
        guard let glibc = wire.minimumGlibc else { return .failure(.missingField("minimum.glibc")) }

        guard product == UpdateEndpoints.product else { return .failure(.wrongProduct(field: "product", value: product)) }
        guard platform == UpdateEndpoints.platform else {
            return .failure(.wrongProduct(field: "platform", value: platform))
        }
        guard UpdateDecision.isPlainVersion(version) else { return .failure(.invalidVersion(version)) }
        guard url == UpdateDecision.expectedURL(version: version) else { return .failure(.unexpectedURL(url)) }
        guard UpdateDecision.isSha256(sha256) else { return .failure(.invalidChecksum) }
        guard size > 0 else { return .failure(.invalidSize) }
        guard UpdateDecision.isPlainVersion(glibc) else { return .failure(.invalidFloor(glibc)) }

        return .success(UpdateOffer(
            version: version,
            buildVersion: buildVersion,
            url: url,
            sha256: sha256,
            size: size,
            minimumGlibc: glibc
        ))
    }

    /// Die Felder, wie sie im JSON stehen — jedes einzeln: fehlt eines oder
    /// hat es den falschen Typ, ist es `nil`, und die Prüfung benennt genau
    /// dieses Feld. `JSONDecoder` liest `true` und `1.5` nicht als `Int`.
    struct Wire: Decodable {
        let hasSchemaVersionKey: Bool
        let schemaVersion: Int?
        let product: String?
        let platform: String?
        let version: String?
        let buildVersion: Int?
        let url: String?
        let sha256: String?
        let size: Int?
        let minimumGlibc: String?

        enum Keys: String, CodingKey {
            case schemaVersion, product, platform, version, buildVersion, url, sha256, size, minimum
        }

        enum MinimumKeys: String, CodingKey {
            case glibc
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            hasSchemaVersionKey = container.contains(.schemaVersion)
            schemaVersion = try? container.decode(Int.self, forKey: .schemaVersion)
            product = try? container.decode(String.self, forKey: .product)
            platform = try? container.decode(String.self, forKey: .platform)
            version = try? container.decode(String.self, forKey: .version)
            buildVersion = try? container.decode(Int.self, forKey: .buildVersion)
            url = try? container.decode(String.self, forKey: .url)
            sha256 = try? container.decode(String.self, forKey: .sha256)
            size = try? container.decode(Int.self, forKey: .size)
            let minimum = try? container.nestedContainer(keyedBy: MinimumKeys.self, forKey: .minimum)
            minimumGlibc = try? minimum?.decode(String.self, forKey: .glibc)
        }
    }
}
