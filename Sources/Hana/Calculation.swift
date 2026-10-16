import Foundation

/// The answer's display and clipboard text belong to the evaluator, not the UI.
struct Answer: Equatable, Sendable {
    enum State: Equatable, Sendable { case value, incomplete, divisionByZero, invalid }

    let state: State
    let title: String
    let subtitle: String
    let copyableText: String?

    init(state: State = .value, title: String, subtitle: String, copyableText: String?) {
        self.state = state
        self.title = title
        self.subtitle = subtitle
        self.copyableText = copyableText
    }
}

/// Pure, synchronous arithmetic at the Search text + locale boundary.
enum Calculation {
    static func answer(for text: String, locale: Locale) -> Answer? {
        guard recognizes(text, locale: locale) else { return nil }
        let invalid = Answer(state: .invalid, title: "Not a valid calculation", subtitle: text, copyableText: nil)
        guard let tokens = tokens(in: text, locale: locale), tokens.count <= 512 else { return invalid }
        var parser = Parser(tokens: tokens)
        do {
            let value = try parser.expression()
            guard parser.index == tokens.count else { return invalid }
            if parser.divisionByZero {
                return Answer(state: .divisionByZero, title: "Uh oh", subtitle: "Can't divide by zero", copyableText: nil)
            }
            guard !value.isNaN,
                  let title = formatted(value, locale: locale) else { return invalid }
            let copy = title.replacingOccurrences(of: locale.groupingSeparator ?? ",", with: "")
            return Answer(title: title, subtitle: text, copyableText: copy)
        } catch Parser.Failure.incomplete {
            return Answer(state: .incomplete, title: "…", subtitle: "Keep typing", copyableText: nil)
        } catch { return invalid }
    }

    private static func formatted(_ value: Decimal, locale: Locale) -> String? {
        var original = value
        var whole = Decimal.zero
        NSDecimalRound(&whole, &original, 0, .plain)
        var rounded = value
        if value != whole {
            let magnitude = value < .zero ? -value : value
            let digits = NSDecimalNumber(decimal: magnitude.significand).stringValue.count
            NSDecimalRound(&rounded, &original, 8 - magnitude.exponent - digits, .plain)
        }
        // Rounding can carry a fractional answer into a 16-digit whole number.
        let magnitude = rounded < .zero ? -rounded : rounded
        let scientific = magnitude >= Decimal(string: "1000000000000000")!
            || (magnitude != .zero && magnitude < Decimal(string: "0.00000001")!)
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
        return formatter.string(from: NSDecimalNumber(decimal: rounded))
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
        enum Failure: Error { case incomplete, invalid }
        let tokens: [Token]
        var index = 0
        var divisionByZero = false

        mutating func take(_ token: Token) -> Bool {
            guard index < tokens.count, tokens[index] == token else { return false }
            index += 1
            return true
        }

        mutating func expression() throws -> Decimal {
            var value = try product()
            while index < tokens.count {
                if take(.operation("+")) {
                    let right = try product()
                    value += right
                } else if take(.operation("-")) {
                    let right = try product()
                    value -= right
                } else { break }
            }
            return value
        }

        mutating func product() throws -> Decimal {
            var value = try unary()
            while index < tokens.count {
                if take(.operation("*")) {
                    let right = try unary()
                    value *= right
                } else if take(.operation("/")) {
                    let right = try unary()
                    if right == .zero {
                        // Finish parsing so malformed or unfinished text still
                        // reports its syntax before any arithmetic failure.
                        divisionByZero = true
                        value = .zero
                    } else { value /= right }
                } else { break }
            }
            return value
        }

        mutating func unary() throws -> Decimal {
            guard index < tokens.count else { throw Failure.incomplete }
            if take(.operation("-")) { return try -unary() }
            if take(.left) {
                let value = try expression()
                guard take(.right) else {
                    throw index == tokens.count ? Failure.incomplete : Failure.invalid
                }
                return value
            }
            if case .function = tokens[index], index + 1 == tokens.count { throw Failure.incomplete }
            guard case .number(let text) = tokens[index],
                  let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { throw Failure.invalid }
            index += 1
            return value
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
                guard case .number = result.last else { return nil }
                var next = index + 1
                while next < input.count, input[next].isWhitespace { next += 1 }
                guard next < input.count else { return nil }
                let startsNumber = digit(input[next])
                    || (input[next] == decimal && next + 1 < input.count && digit(input[next + 1]))
                guard startsNumber else { return nil }
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
