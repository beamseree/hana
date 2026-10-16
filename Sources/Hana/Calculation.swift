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

        static func literal(_ text: String) -> Number {
            let parts = text.split(separator: "e", maxSplits: 1, omittingEmptySubsequences: false)
            let exponent: Int
            if parts.count == 2 {
                guard let parsed = Int(parts[1]), literalMagnitudeFits(parts[0], exponent: parsed)
                else { return .failure(.tooLarge) }
                exponent = parsed
            } else { exponent = 0 }
            guard let coefficient = Decimal(string: String(parts[0]), locale: Locale(identifier: "en_US_POSIX"))
            else { return .failure(.tooLarge) }
            guard parts.count == 2 else { return .decimal(coefficient) }
            return scaled(coefficient, by: exponent)
        }

        private static func literalMagnitudeFits(_ coefficient: Substring, exponent: Int) -> Bool {
            let digits = coefficient.filter(\.isNumber).drop(while: { $0 == "0" })
            if digits.isEmpty { return true }
            let fractionalDigits = coefficient.firstIndex(of: ".").map {
                coefficient.distance(from: $0, to: coefficient.endIndex) - 1
            } ?? 0
            let scale = exponent.subtractingReportingOverflow(fractionalDigits)
            guard !scale.overflow else { return false }
            let integerDigits = digits.count.addingReportingOverflow(scale.partialValue)
            // A nonzero Decimal spans 1e-128 through (2^128 - 1) * 1e127.
            guard !integerDigits.overflow, (-127...166).contains(integerDigits.partialValue) else { return false }
            guard integerDigits.partialValue == 166 else { return true }
            // Check the unrounded spelling: Foundation may truncate max + 1 to max - 5.
            let maximum = String(UInt128.max)
            let leading = String(digits.prefix(maximum.count))
                + String(repeating: "0", count: max(0, maximum.count - digits.count))
            return leading < maximum
                || (leading == maximum && digits.dropFirst(maximum.count).allSatisfy { $0 == "0" })
        }

        func applying(_ operation: Character, to right: Number) -> Number {
            if case .failure = self { return self }
            if case .failure = right { return right }
            if operation == "/", right.double == 0 { return .failure(.divisionByZero) }
            if case .decimal(var left) = self, case .decimal(var right) = right {
                if operation == "+" || operation == "-", Self.sumExceedsUpperBound(left, right, operation: operation) {
                    return .failure(.tooLarge)
                }
                var result = Decimal.zero
                let error: Decimal.CalculationError
                switch operation {
                case "+": error = NSDecimalAdd(&result, &left, &right, .plain)
                case "-": error = NSDecimalSubtract(&result, &left, &right, .plain)
                default: return Self.productOrQuotient(left, right, operation: operation)
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

        private static func sumExceedsUpperBound(_ left: Decimal, _ right: Decimal, operation: Character) -> Bool {
            let addingMagnitudes = operation == "+" ? left.sign == right.sign : left.sign != right.sign
            guard addingMagnitudes else { return false }
            let upper = left.exponent == 127 ? left : right
            let other = left.exponent == 127 ? right : left
            // Two operands below exponent 127 cannot sum beyond Decimal's maximum.
            guard upper.exponent == 127 else { return false }
            guard let a = UInt128(NSDecimalNumber(decimal: upper.significand).stringValue),
                  let b = UInt128(NSDecimalNumber(decimal: other.significand).stringValue)
            else { return true }
            let remaining = UInt128.max - a
            if remaining == 0 { return b != 0 }
            let shift = 127 - other.exponent
            guard shift <= 38 else { return false }
            let power = (0..<shift).reduce(UInt128(1)) { value, _ in value * 10 }
            let gap = remaining.multipliedFullWidth(by: power)
            return gap.high == 0 && b > gap.low
        }

        private static func productOrQuotient(_ left: Decimal, _ right: Decimal, operation: Character) -> Number {
            guard !outsideRange(left, right, operation: operation) else { return .failure(.tooLarge) }
            // Foundation can wrap product exponents and underflow valid quotients.
            // Operate on significands, then apply their decimal scales separately.
            var leftSignificand = left.sign == .minus ? -left.significand : left.significand
            var rightSignificand = right.sign == .minus ? -right.significand : right.significand
            var result = Decimal.zero
            var exponent = operation == "*" ? left.exponent + right.exponent : left.exponent - right.exponent
            let error: Decimal.CalculationError
            if operation == "*" {
                error = NSDecimalMultiply(&result, &leftSignificand, &rightSignificand, .plain)
            } else {
                let leftDigits = NSDecimalNumber(decimal: left.significand).stringValue.count
                let rightDigits = NSDecimalNumber(decimal: right.significand).stringValue.count
                var normalizedLeft = Decimal.zero
                var normalizedRight = Decimal.zero
                guard NSDecimalMultiplyByPowerOf10(&normalizedLeft, &leftSignificand, Int16(1 - leftDigits), .plain) == .noError,
                      NSDecimalMultiplyByPowerOf10(&normalizedRight, &rightSignificand, Int16(1 - rightDigits), .plain) == .noError
                else { return .failure(.tooLarge) }
                // Similar magnitudes prevent a valid quotient truncating to zero.
                exponent += leftDigits - rightDigits
                error = NSDecimalDivide(&result, &normalizedLeft, &normalizedRight, .plain)
            }
            guard error == .noError || error == .lossOfPrecision else { return .failure(.tooLarge) }
            return scaled(result, by: exponent)
        }

        private static func outsideRange(_ left: Decimal, _ right: Decimal, operation: Character) -> Bool {
            let scale = operation == "*" ? left.exponent + right.exponent : left.exponent - right.exponent
            guard let a = UInt128(NSDecimalNumber(decimal: left.significand).stringValue),
                  let b = UInt128(NSDecimalNumber(decimal: right.significand).stringValue)
            else { return true }
            if a == 0 || b == 0 { return false }
            let magnitude: (high: UInt128, low: UInt128)
            let maximum: (high: UInt128, low: UInt128)
            if operation == "*" {
                magnitude = a.multipliedFullWidth(by: b)
                if scale < -128 {
                    let reduced = dividingByPowerOfTen(magnitude, exponent: -128 - scale)
                    return reduced.high == 0 && reduced.low == 0
                }
                if 127 - scale > 38 { return false }
                if scale >= 127 {
                    maximum = dividingByPowerOfTen((0, UInt128.max), exponent: scale - 127)
                } else {
                    let power = (0..<(127 - scale)).reduce(UInt128(1)) { value, _ in value * 10 }
                    maximum = UInt128.max.multipliedFullWidth(by: power)
                }
            } else {
                let shift = scale + 128
                if shift <= 38 {
                    if shift < -38 { return true }
                    let power = (0..<abs(shift)).reduce(UInt128(1)) { value, _ in value * 10 }
                    let numerator: (high: UInt128, low: UInt128) = shift < 0 ? (0, a) : a.multipliedFullWidth(by: power)
                    let denominator: (high: UInt128, low: UInt128) = shift < 0 ? b.multipliedFullWidth(by: power) : (0, b)
                    return numerator.high < denominator.high || (numerator.high == denominator.high && numerator.low < denominator.low)
                }
                if scale <= 127 { return false }
                magnitude = (0, a)
                maximum = dividingByPowerOfTen(UInt128.max.multipliedFullWidth(by: b), exponent: scale - 127)
            }
            // Compare before Foundation truncates any significant digits into range.
            return magnitude.high > maximum.high || (magnitude.high == maximum.high && magnitude.low > maximum.low)
        }

        private static func dividingByPowerOfTen(
            _ coefficient: (high: UInt128, low: UInt128), exponent: Int
        ) -> (high: UInt128, low: UInt128) {
            var value = coefficient
            for _ in 0..<exponent {
                let remainder = value.high % 10
                value.high /= 10
                // The high limb is below the divisor, so the low quotient fits.
                value.low = UInt128(10).dividingFullWidth((high: remainder, low: value.low)).quotient
                if value.high == 0 && value.low == 0 { break }
            }
            return value
        }

        private static func scaled(_ value: Decimal, by power: Int) -> Number {
            if value == .zero { return .decimal(.zero) }
            var significand = value.sign == .minus ? -value.significand : value.significand
            let combined = value.exponent.addingReportingOverflow(power)
            guard !combined.overflow else { return .failure(.tooLarge) }
            var exponent = combined.partialValue
            if exponent < -128 {
                let discardedDigits = -128 - exponent
                let digits = NSDecimalNumber(decimal: value.significand).stringValue.count
                guard digits > discardedDigits else { return .failure(.tooLarge) }
                // Decimal can retain fewer significant digits near its lower bound.
                var rounded = Decimal.zero
                NSDecimalRound(&rounded, &significand, -discardedDigits, .plain)
                exponent += rounded.exponent
                significand = rounded.sign == .minus ? -rounded.significand : rounded.significand
            }
            if exponent >= 127 {
                // The 128-bit coefficient can absorb up to 38 extra powers of ten.
                guard exponent - 127 <= 38,
                      var coefficient = UInt128(NSDecimalNumber(decimal: significand.significand).stringValue)
                else { return .failure(.tooLarge) }
                for _ in 127..<exponent {
                    let expanded = coefficient.multipliedReportingOverflow(by: 10)
                    guard !expanded.overflow else { return .failure(.tooLarge) }
                    coefficient = expanded.partialValue
                }
                return atUpperExponent(coefficient, negative: significand.sign == .minus)
            }
            guard exponent >= -128 else { return .failure(.tooLarge) }
            var result = Decimal.zero
            let error = NSDecimalMultiplyByPowerOf10(&result, &significand, Int16(exponent), .plain)
            guard error == .noError || error == .lossOfPrecision else { return .failure(.tooLarge) }
            return .decimal(result)
        }

        private static func atUpperExponent(_ coefficient: UInt128, negative: Bool) -> Number {
            var high = NSDecimalNumber(mantissa: UInt64(coefficient >> 64), exponent: 127, isNegative: false).decimalValue
            var low = NSDecimalNumber(mantissa: UInt64(truncatingIfNeeded: coefficient), exponent: 127, isNegative: false).decimalValue
            // Split into public UInt64 constructors without normalizing exponent 127 away.
            var radix = Decimal(string: "18446744073709551616")! // 2^64, exactly representable.
            var product = Decimal.zero
            guard NSDecimalMultiply(&product, &high, &radix, .plain) == .noError else { return .failure(.tooLarge) }
            var result = Decimal.zero
            guard NSDecimalAdd(&result, &product, &low, .plain) == .noError else { return .failure(.tooLarge) }
            return .decimal(negative ? -result : result)
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
            index += 1
            return Operand(number: Number.literal(text))
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
