import Foundation

/// Die GNOME-Extension als Nutzlast des Binaries (CM-43).
///
/// Die Bytes kommen aus `Linux/Extension/` über `.embedInCode` (`Package.swift`,
/// Ziel `GnomeExtension`). `PackageResources` ist `internal` (Spec §7 M2) —
/// deshalb diese öffentliche Hülle.
public enum GnomeExtensionPayload {

    /// Eine Datei der Extension, relativ zum Ordner der Extension.
    public struct File: Sendable {
        public let relativePath: String
        public let bytes: [UInt8]
    }

    /// Die 7 Dateien, in dieser Reihenfolge.
    public static let files: [File] = [
        File(relativePath: "extension.js", bytes: PackageResources.extension_js),
        File(relativePath: "metadata.json", bytes: PackageResources.metadata_json),
        File(relativePath: "popoverState.js", bytes: PackageResources.popoverState_js),
        File(relativePath: "stylesheet.css", bytes: PackageResources.stylesheet_css),
        File(relativePath: "stylesheet-dark.css", bytes: PackageResources.stylesheet_dark_css),
        File(relativePath: "stylesheet-light.css", bytes: PackageResources.stylesheet_light_css),
        File(
            relativePath: schemaRelativePath,
            bytes: PackageResources.org_gnome_shell_extensions_claudemonitor_gschema_xml
        )
    ]

    /// `schemas/org.gnome.shell.extensions.claudemonitor.gschema.xml`
    public static let schemaRelativePath = "schemas/org.gnome.shell.extensions.claudemonitor.gschema.xml"
    /// Das Schema-Verzeichnis im Ordner der Extension.
    public static let schemasDirectory = "schemas"
    /// Wird nicht mitgeliefert, sondern beim Einrichten mit `glib-compile-schemas` erzeugt.
    public static let compiledSchemaPath = "schemas/gschemas.compiled"

    /// Die UUID — einzige Quelle ist der Schlüssel `uuid` im eingebetteten
    /// `metadata.json`. Es gibt kein zweites Literal.
    public static var uuid: String {
        (metadata["uuid"] as? String) ?? ""
    }

    /// Die Shell-Fassungen aus `shell-version`, etwa `["50"]`.
    public static var shellVersions: [String] {
        (metadata["shell-version"] as? [String]) ?? []
    }

    private static var metadata: [String: Any] {
        let data = Data(PackageResources.metadata_json)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
