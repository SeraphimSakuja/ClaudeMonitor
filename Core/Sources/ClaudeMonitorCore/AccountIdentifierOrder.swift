import Foundation

/// Eine **einzige** Ordnung für Account-Kennungen — bewusst locale-frei.
///
/// Der Store liefert Slot-Schlüssel als Strings (`"1"`, `"2"`, … `"10"`).
/// `localizedStandardCompare` wäre naheliegend, hängt aber an der Locale des
/// laufenden Systems; ein rein lexikografisches `<` sortiert `"10"` vor `"2"`.
/// Beides zusammen an verschiedenen Stellen ergäbe ab zehn Accounts zwei
/// widersprüchliche Reihenfolgen. Deshalb: natürlich-numerischer Vergleich,
/// deterministisch und ohne Locale-Einfluss, benutzt von Reader **und** Ranking.
enum AccountIdentifierOrder {

    /// `true`, wenn `lhs` vor `rhs` einzusortieren ist.
    /// Strikte schwache Ordnung: irreflexiv, asymmetrisch, transitiv.
    static func isOrderedBefore(_ lhs: String, _ rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    /// Natürlich-numerischer Vergleich: Ziffernblöcke werden als Zahl
    /// verglichen, alles andere zeichenweise über Unicode-Skalare.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        var left = lhs[...]
        var right = rhs[...]
        // Unterschiedliche führende Nullen entscheiden erst ganz am Ende,
        // damit `"01"` und `"1"` zahlenmäßig gleich bleiben, die Ordnung aber
        // trotzdem total (und damit reproduzierbar) ist.
        var leadingZeroTiebreak: ComparisonResult = .orderedSame

        while let leftFirst = left.first, let rightFirst = right.first {
            let leftIsDigit = isASCIIDigit(leftFirst)
            let rightIsDigit = isASCIIDigit(rightFirst)

            if leftIsDigit != rightIsDigit {
                // Zahlen vor Text — feste, locale-freie Konvention.
                return leftIsDigit ? .orderedAscending : .orderedDescending
            }

            if leftIsDigit {
                let leftDigits = takeDigits(&left)
                let rightDigits = takeDigits(&right)
                let leftValue = leftDigits.drop { $0 == "0" }
                let rightValue = rightDigits.drop { $0 == "0" }
                if leftValue.count != rightValue.count {
                    return leftValue.count < rightValue.count ? .orderedAscending : .orderedDescending
                }
                if leftValue != rightValue {
                    return leftValue.lexicographicallyPrecedes(rightValue)
                        ? .orderedAscending : .orderedDescending
                }
                if leadingZeroTiebreak == .orderedSame, leftDigits.count != rightDigits.count {
                    leadingZeroTiebreak = leftDigits.count < rightDigits.count
                        ? .orderedAscending : .orderedDescending
                }
                continue
            }

            if leftFirst != rightFirst {
                return leftFirst.unicodeScalars.lexicographicallyPrecedes(rightFirst.unicodeScalars)
                    ? .orderedAscending : .orderedDescending
            }
            left.removeFirst()
            right.removeFirst()
        }

        if left.isEmpty != right.isEmpty {
            return left.isEmpty ? .orderedAscending : .orderedDescending
        }
        return leadingZeroTiebreak
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9"
    }

    /// Nimmt den führenden Ziffernblock ab und entfernt ihn aus `text`.
    private static func takeDigits(_ text: inout Substring) -> Substring {
        let digits = text.prefix(while: isASCIIDigit)
        text = text.dropFirst(digits.count)
        return digits
    }
}
