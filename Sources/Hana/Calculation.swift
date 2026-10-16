import Foundation

/// The answer's display and clipboard text belong to the evaluator, not the UI.
struct Answer: Equatable, Sendable {
    let title: String
    let subtitle: String
    let copyableText: String?
}

/// Pure, synchronous arithmetic at the Search text + locale boundary.
enum Calculation {
    static func answer(for text: String, locale: Locale) -> Answer? {
        guard recognizes(text, locale: locale) else { return nil }
        guard let tokens = tokens(in: text, locale: locale), tokens.count <= 512 else { return nil }
        var parser = Parser(tokens: tokens)
        guard let value = parser.expression(), parser.index == tokens.count, !value.isNaN else { return nil }
        guard let title = formatted(value, locale: locale) else { return nil }
        let copy = title.replacingOccurrences(of: locale.groupingSeparator ?? ",", with: "")
        return Answer(title: title, subtitle: text, copyableText: copy)
    }

    private static func formatted(_ value: Decimal, locale: Locale) -> String? {
        let magnitude = value < .zero ? -value : value
        let scientific = magnitude >= Decimal(string: "1000000000000000")!
            || (magnitude != .zero && magnitude < Decimal(string: "0.00000001")!)
        var original = value
        var whole = Decimal.zero
        NSDecimalRound(&whole, &original, 0, .plain)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = scientific ? .scientific : .decimal
        formatter.exponentSymbol = "e"
        formatter.usesGroupingSeparator = !scientific
        if scientific || value != whole {
            formatter.usesSignificantDigits = true
            formatter.minimumSignificantDigits = 1
            formatter.maximumSignificantDigits = 8
        } else {
            formatter.maximumFractionDigits = 0
        }
        return formatter.string(from: NSDecimalNumber(decimal: value))
    }

    /// Recognition deliberately does not depend on a successfully parsed value.
    static func recognizes(_ text: String, locale: Locale) -> Bool {
        guard let tokens = tokens(in: text, locale: locale), !tokens.isEmpty else { return false }
        if tokens.contains(where: {
            switch $0 {
            case .operation, .function: true
            default: false
            }
        }) { return true }
        return zip(tokens, tokens.dropFirst()).contains { left, right in
            left.endsOperand && right.startsOperand
        }
    }

    private enum Token: Equatable {
        case number(String), constant(String), function(String), operation(Character), left, right

        var endsOperand: Bool {
            switch self { case .number, .constant, .right: true; default: false }
        }
        var startsOperand: Bool {
            switch self { case .number, .constant, .left: true; default: false }
        }
    }

    private struct Parser {
        let tokens: [Token]
        var index = 0

        mutating func take(_ token: Token) -> Bool {
            guard index < tokens.count, tokens[index] == token else { return false }
            index += 1
            return true
        }

        mutating func expression() -> Decimal? {
            guard var value = product() else { return nil }
            while index < tokens.count {
                if take(.operation("+")) {
                    guard let right = product() else { return nil }
                    value += right
                } else if take(.operation("-")) {
                    guard let right = product() else { return nil }
                    value -= right
                } else { break }
            }
            return value
        }

        mutating func product() -> Decimal? {
            guard var value = unary() else { return nil }
            while index < tokens.count {
                if take(.operation("*")) {
                    guard let right = unary() else { return nil }
                    value *= right
                } else if take(.operation("/")) {
                    guard let right = unary(), right != .zero else { return nil }
                    value /= right
                } else { break }
            }
            return value
        }

        mutating func unary() -> Decimal? {
            if take(.operation("-")) { return unary().map { -$0 } }
            if take(.left) {
                guard let value = expression(), take(.right) else { return nil }
                return value
            }
            guard index < tokens.count, case .number(let text) = tokens[index] else { return nil }
            index += 1
            return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
        }
    }

    private static func tokens(in text: String, locale: Locale) -> [Token]? {
        let input = Array(text.lowercased())
        let decimal = Character(locale.decimalSeparator ?? ".")
        let grouping = Character(locale.groupingSeparator ?? ",")
        let functions: Set<String> = ["sqrt", "sin", "cos", "tan", "log", "ln"]
        var result: [Token] = []
        var index = 0
        func digit(_ c: Character) -> Bool { c >= "0" && c <= "9" }
        while index < input.count {
            let c = input[index]
            if c.isWhitespace { index += 1; continue }
            if digit(c) || c == decimal {
                var number = ""
                var hasDecimal = false
                while index < input.count {
                    let next = input[index]
                    if digit(next) { number.append(next) }
                    else if next == decimal, !hasDecimal { number.append("."); hasDecimal = true }
                    else if next == grouping, index + 1 < input.count, digit(input[index + 1]) { }
                    else { break }
                    index += 1
                }
                // An exponent belongs to a number only when it has digits.
                if index < input.count, input[index] == "e" {
                    var end = index + 1
                    if end < input.count, input[end] == "+" || input[end] == "-" { end += 1 }
                    let digitsStart = end
                    while end < input.count, digit(input[end]) { end += 1 }
                    if end > digitsStart {
                        number += String(input[index..<end])
                        index = end
                    }
                }
                result.append(.number(number))
                continue
            }
            if c == "x" {
                let before = input[..<index].last { !$0.isWhitespace }
                let after = input[(index + 1)...].first { !$0.isWhitespace }
                guard let before, let after, digit(before), digit(after) else { return nil }
                result.append(.operation("*")); index += 1; continue
            }
            if c.isLetter {
                let start = index
                while index < input.count, input[index].isLetter { index += 1 }
                let name = String(input[start..<index])
                if functions.contains(name) { result.append(.function(name)) }
                else if name == "pi" || name == "e" { result.append(.constant(name)) }
                else { return nil }
                continue
            }
            switch c {
            case "(": result.append(.left)
            case ")": result.append(.right)
            case "+", "-", "*", "/", "^", "%": result.append(.operation(c))
            case "−": result.append(.operation("-"))
            case "×": result.append(.operation("*"))
            case "÷": result.append(.operation("/"))
            default: return nil
            }
            index += 1
        }
        return result
    }

}
