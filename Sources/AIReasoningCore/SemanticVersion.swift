// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

package struct SemanticVersion: Comparable, Sendable, Equatable, CustomStringConvertible {
    package let components: [Int]
    package let description: String

    package init?(_ source: String) {
        guard let match = source.firstMatch(of: /\d+(?:\.\d+){1,3}/) else {
            return nil
        }
        let value = String(match.output)
        let parsed = value.split(separator: ".").compactMap { Int($0) }
        guard parsed.count >= 2 else { return nil }
        self.components = parsed
        self.description = value
    }

    package static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
