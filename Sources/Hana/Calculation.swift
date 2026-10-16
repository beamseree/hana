import Foundation

/// The answer's display and clipboard text belong to the evaluator, not the UI.
struct Answer: Equatable, Sendable {
    enum State: Equatable, Sendable { case value, incomplete, divisionByZero, undefined, tooLarge, invalid }

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
        guard let tokens = tokens(in: text, locale: locale) else { return invalid }
        var parser = Parser(tokens: tokens)
        do {
            let value = try parser.expression().number
            guard parser.index == tokens.count else { return invalid }
            if case .failure(let failure) = value {
                return Answer(state: failure.state, title: "Uh oh", subtitle: failure.subtitle, copyableText: nil)
            }
            guard let title = formatted(value, locale: locale) else { return invalid }
            let copy = title.replacingOccurrences(of: locale.groupingSeparator ?? ",", with: "")
            return Answer(title: title, subtitle: text, copyableText: copy)
        } catch Parser.Failure.incomplete {
            return Answer(state: .incomplete, title: "…", subtitle: "Keep typing", copyableText: nil)
        } catch Parser.Failure.tooLarge {
            return Answer(state: .tooLarge, title: "Uh oh", subtitle: "Too large", copyableText: nil)
        } catch { return invalid }
    }

    private static func formatted(_ value: Number, locale: Locale) -> String? {
        switch value {
        case .decimal(let decimal):
            guard !decimal.isNaN else { return nil }
            return formatted(decimal, locale: locale)
        case .failure: return nil
        case .approximate(let double):
            guard double.isFinite else { return nil }
            let whole = double.rounded() == double
            let rounded = whole ? double : Double(String(format: "%.8g", locale: Locale(identifier: "en_US_POSIX"), double)) ?? double
            let magnitude = abs(rounded)
            let scientific = magnitude >= 1e15 || (magnitude != 0 && magnitude < 1e-8)
            return formatted(NSNumber(value: rounded == 0 ? 0 : rounded),
                             scientific: scientific, fractional: !whole, locale: locale)
        }
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
        return formatted(NSDecimalNumber(decimal: rounded),
                         scientific: scientific, fractional: value != whole, locale: locale)
    }

    private static func formatted(_ value: NSNumber, scientific: Bool, fractional: Bool, locale: Locale) -> String? {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = scientific ? .scientific : .decimal
        formatter.exponentSymbol = "e"
        formatter.usesGroupingSeparator = !scientific
        if scientific || fractional {
            formatter.usesSignificantDigits = true
            formatter.minimumSignificantDigits = 1
            formatter.maximumSignificantDigits = 8
        } else { formatter.maximumFractionDigits = 0 }
        return formatter.string(from: value)
    }

    /// Recognition deliberately does not depend on a successfully parsed value.
    static func recognizes(_ text: String, locale: Locale) -> Bool {
        guard let tokens = tokens(in: text, locale: locale), !tokens.isEmpty else { return false }
        if tokens.contains(where: {
            switch $0 {
            case .operation, .function: true
            case .number(let text): text.contains("e")
            default: false
            }
        }) { return true }
        return zip(tokens, tokens.dropFirst()).contains { left, right in
            left.endsOperand && right.startsOperand
        }
    }

    private enum Function: String {
        case sqrt, sin, cos, tan, log, ln
    }

    private enum Token: Equatable {
        case number(String), constant(String), function(Function), operation(Character), left, right

        var endsOperand: Bool {
            switch self { case .number, .constant, .right: true; default: false }
        }
        var startsOperand: Bool {
            switch self { case .number, .constant, .function, .left: true; default: false }
        }
    }

    private enum NumericFailure {
        case divisionByZero, undefined, tooLarge

        var state: Answer.State {
            switch self {
            case .divisionByZero: .divisionByZero
            case .undefined: .undefined
            case .tooLarge: .tooLarge
            }
        }
        var subtitle: String {
            switch self {
            case .divisionByZero: "Can't divide by zero"
            case .undefined: "Undefined"
            case .tooLarge: "Too large"
            }
        }
    }

    private enum Number {
        case decimal(Decimal), approximate(Double), failure(NumericFailure)

        var double: Double {
            switch self {
            case .decimal(let value): NSDecimalNumber(decimal: value).doubleValue
            case .approximate(let value): value
            case .failure: .nan
            }
        }

        static func checked(_ value: Double) -> Number {
            if value.isNaN { return .failure(.undefined) }
            if !value.isFinite { return .failure(.tooLarge) }
            return .approximate(value)
        }

        func applying(_ operation: Character, to right: Number) -> Number {
            if case .failure = self { return self }
            if case .failure = right { return right }
            if operation == "/", right.double == 0 { return .failure(.divisionByZero) }
            if case .decimal(var left) = self, case .decimal(var right) = right {
                var result = Decimal.zero
                let error: Decimal.CalculationError
                switch operation {
                case "+": error = NSDecimalAdd(&result, &left, &right, .plain)
                case "-": error = NSDecimalSubtract(&result, &left, &right, .plain)
                case "*": error = NSDecimalMultiply(&result, &left, &right, .plain)
                default: error = NSDecimalDivide(&result, &left, &right, .plain)
                }
                switch error {
                case .noError, .lossOfPrecision: return .decimal(result)
                case .divideByZero: return .failure(.divisionByZero)
                default: return .failure(.tooLarge)
                }
            }
            let result: Double
            switch operation {
            case "+": result = double + right.double
            case "-": result = double - right.double
            case "*": result = double * right.double
            default: result = double / right.double
            }
            if result == 0, double != 0, right.double != 0, operation == "*" || operation == "/" {
                return .failure(.tooLarge)
            }
            return .checked(result)
        }

        func raised(to exponent: Number) -> Number {
            if case .failure = self { return self }
            if case .failure = exponent { return exponent }
            if double == 0, exponent.double < 0 { return .failure(.divisionByZero) }
            if case .decimal(let base) = self, case .decimal(var power) = exponent {
                var whole = Decimal.zero
                NSDecimalRound(&whole, &power, 0, .plain)
                if whole == power {
                    // Trivial bases stay representable even with an enormous exponent.
                    if base == 1 { return .decimal(1) }
                    if base == 0 { return .decimal(power == 0 ? 1 : 0) }
                    if base == -1 {
                        return .decimal(Self.isOdd(power) ? -1 : 1)
                    }
                    var remaining = power < 0 ? -power : power
                    var factor = power < 0 ? Number.decimal(1).applying("/", to: self) : self
                    var result = Number.decimal(1)
                    while remaining > 0 {
                        if Self.isOdd(remaining) {
                            result = result.applying("*", to: factor)
                            // Remove the odd unit before halving so a full-
                            // precision integer never rounds away its final .5.
                            remaining -= 1
                        }
                        remaining /= 2
                        if remaining > 0 { factor = factor.applying("*", to: factor) }
                        if case .failure = result { return result }
                        if case .failure = factor { return factor }
                    }
                    return result
                }
            }
            let result = Foundation.pow(double, exponent.double)
            if result == 0, double != 0 { return .failure(.tooLarge) }
            return .checked(result)
        }

        private static func isOdd(_ integer: Decimal) -> Bool {
            let lastDigit = NSDecimalNumber(decimal: integer).stringValue.last
            return integer.exponent <= 0 && lastDigit.map { "13579".contains($0) } == true
        }

        func applyingFunction(_ function: Function) -> Number {
            if case .failure = self { return self }
            let argument = double
            if function == .sqrt, argument < 0 { return .failure(.undefined) }
            if (function == .ln || function == .log), argument <= 0 { return .failure(.undefined) }
            let result: Double
            switch function {
            case .sqrt: result = Foundation.sqrt(argument)
            case .sin: result = Foundation.sin(argument)
            case .cos: result = Foundation.cos(argument)
            case .tan: result = Foundation.tan(argument)
            case .log: result = Foundation.log10(argument)
            case .ln: result = Foundation.log(argument)
            }
            return .checked(result)
        }
    }

    private struct Parser {
        enum Failure: Error { case incomplete, invalid, tooLarge }
        let tokens: [Token]
        var index = 0
        private var nesting = 0

        init(tokens: [Token]) { self.tokens = tokens }

        private mutating func nested(_ parse: (inout Parser) throws -> Operand) throws -> Operand {
            guard nesting < 32 else { throw Failure.tooLarge }
            nesting += 1
            defer { nesting -= 1 }
            return try parse(&self)
        }

        mutating func take(_ token: Token) -> Bool {
            guard index < tokens.count, tokens[index] == token else { return false }
            index += 1
            return true
        }

        struct Operand {
            var number: Number
            var directPercent = false
        }

        mutating func expression() throws -> Operand {
            var value = try product()
            while index < tokens.count {
                if take(.operation("+")) {
                    let right = try product()
                    let amount = right.directPercent ? value.number.applying("*", to: right.number) : right.number
                    value.number = value.number.applying("+", to: amount)
                    value.directPercent = false
                } else if take(.operation("-")) {
                    let right = try product()
                    let amount = right.directPercent ? value.number.applying("*", to: right.number) : right.number
                    value.number = value.number.applying("-", to: amount)
                    value.directPercent = false
                } else { break }
            }
            return value
        }

        mutating func product() throws -> Operand {
            var value = try unary()
            while index < tokens.count {
                if take(.operation("*")) {
                    let right = try unary()
                    value.number = value.number.applying("*", to: right.number)
                    value.directPercent = false
                } else if take(.operation("/")) {
                    let right = try unary()
                    value.number = value.number.applying("/", to: right.number)
                    value.directPercent = false
                } else if tokens[index].startsOperand {
                    // Two bare numeric tokens are malformed, never implicit multiplication.
                    if case .number = tokens[index], case .number = tokens[index - 1] { break }
                    let right = try unary()
                    value.number = value.number.applying("*", to: right.number)
                    value.directPercent = false
                } else { break }
            }
            return value
        }

        mutating func unary() throws -> Operand {
            guard index < tokens.count else { throw Failure.incomplete }
            if take(.operation("-")) {
                var value = try nested { try $0.unary() }
                value.number = .decimal(-1).applying("*", to: value.number)
                return value
            }
            return try power()
        }

        mutating func power() throws -> Operand {
            var value = try postfix()
            if take(.operation("^")) {
                let exponent = try nested { try $0.unary() }
                value.number = value.number.raised(to: exponent.number)
                value.directPercent = false
            }
            return value
        }

        mutating func postfix() throws -> Operand {
            var value = try primary()
            while take(.operation("%")) {
                value.number = value.number.applying("/", to: .decimal(100))
                value.directPercent = true
            }
            return value
        }

        mutating func primary() throws -> Operand {
            guard index < tokens.count else { throw Failure.incomplete }
            if take(.left) {
                let value = try nested { try $0.expression() }
                guard take(.right) else {
                    throw index == tokens.count ? Failure.incomplete : Failure.invalid
                }
                return value
            }
            if case .constant(let name) = tokens[index] {
                index += 1
                return Operand(number: .approximate(name == "pi" ? .pi : Foundation.exp(1)))
            }
            if case .function(let name) = tokens[index] {
                index += 1
                guard take(.left) else { throw index == tokens.count ? Failure.incomplete : Failure.invalid }
                let argument = try nested { try $0.expression() }.number
                guard take(.right) else { throw index == tokens.count ? Failure.incomplete : Failure.invalid }
                return Operand(number: argument.applyingFunction(name))
            }
            guard case .number(let text) = tokens[index], text.contains(where: \.isNumber) else { throw Failure.invalid }
            let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
            index += 1
            return Operand(number: value.map(Number.decimal) ?? .failure(.tooLarge))
        }
    }

    private static func tokens(in text: String, locale: Locale) -> [Token]? {
        let input = Array(text.lowercased())
        let decimal = Character(locale.decimalSeparator ?? ".")
        let grouping = Character(locale.groupingSeparator ?? ",")
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
                if let function = Function(rawValue: name) { result.append(.function(function)) }
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
