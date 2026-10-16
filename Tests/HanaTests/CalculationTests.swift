import Foundation
import Testing
@testable import Hana

struct CalculationTests {
    @Test(arguments: [
        ("2(3 + 4)", "14"), ("(1 + 2)(3 + 4)", "21"),
        ("2pi", "6.2831853"), ("2e", "5.4365637"),
        ("2sin(pi / 2)", "2"), ("6 / 2(1 + 2)", "9"),
        ("3e5", "300,000"), ("1.2e-3", "0.0012"),
        ("1.2E+3", "1,200"), ("2e3", "2,000")
    ])
    func implicitMultiplicationAndScientificLiteralsHaveUnambiguousAnswers(text: String, expected: String) {
        #expect(Calculation.recognizes(text, locale: locale))
        #expect(Calculation.answer(for: text, locale: locale)?.title == expected)
    }
    @Test(arguments: [
        ("sqrt(16)", "4", "4"), ("SQRT(16)", "4", "4"),
        ("sin(pi / 2)", "1", "1"), ("cos(PI)", "-1", "-1"),
        ("tan(Pi / 4)", "1", "1"), ("log(100)", "2", "2"),
        ("ln(E)", "1", "1"), ("2 * pi", "6.2831853", "6.2831853"),
        ("2 * e", "5.4365637", "5.4365637"), ("e^2", "7.3890561", "7.3890561"),
        ("2^0.5", "1.4142136", "1.4142136"),
        ("10^200.5", "3.1622777e200", "3.1622777e200"),
        ("sqrt(152399025)", "12,345", "12345")
    ])
    func functionsConstantsAndFractionalPowersUseDoublePrecision(text: String, title: String, copy: String) throws {
        let answer = try #require(Calculation.answer(for: text, locale: locale))
        #expect(answer.state == .value && answer.title == title)
        #expect(answer.copyableText == copy && answer.subtitle == text)
    }
    @Test(arguments: [
        ("50%", "0.5"), ("200 + 10%", "220"), ("200 - 10%", "180"),
        ("200 * 10%", "20"), ("200 / 10%", "2,000"),
        ("200 + 0.1", "200.1"), ("200 + 10% + 10%", "242"),
        ("200 + 10% * 2", "200.2"), ("200 + (10%)", "220")
    ])
    func percentagesAreRelativeOnlyForADirectAdditiveOperand(text: String, expected: String) {
        #expect(Calculation.answer(for: text, locale: locale)?.title == expected)
    }
    @Test(arguments: [
        ("2^3^2", "512"), ("-2^2", "-4"), ("(-2)^2", "4"),
        ("2^-3", "0.125"), ("2^-2^2", "0.0625"),
        ("(0.1 + 0.2)^2", "0.09"), ("1.01^2", "1.0201"),
        ("3^30", "205,891,132,094,649"), ("1^1e100", "1"),
        ("1^-9223372036854775808", "1"),
        ("(-1)^9007199254740993", "-1"),
        ("(-1)^99999999999999999999999999999999999999", "-1"),
        ("(-1)^1e100", "1"),
        ("1.000000000000000001^9223372036854775808", "10,131.169")
    ])
    func integerPowersAreExactAndBindBeforeUnaryMinus(text: String, expected: String) {
        #expect(Calculation.answer(for: text, locale: locale)?.title == expected)
    }
    private let locale = Locale(identifier: "en_US")

    @Test func basicArithmeticAppearsAsAnAnswer() throws {
        let answer = try #require(Calculation.answer(for: "12 * 4 + 3", locale: locale))
        #expect(answer.state == .value)
        #expect(answer.title == "51")
        #expect(answer.subtitle == "12 * 4 + 3")
        #expect(answer.copyableText == "51")
    }

    @Test(arguments: [
        ("12 *", Answer.State.incomplete, "…", "Keep typing"),
        ("(3 + 4", .incomplete, "…", "Keep typing"),
        ("12 * -", .incomplete, "…", "Keep typing"),
        ("(3 + 4 +", .incomplete, "…", "Keep typing"),
        ("sqrt", .incomplete, "…", "Keep typing"),
        ("5 / 0 +", .incomplete, "…", "Keep typing"),
        ("5 / 0", .divisionByZero, "Uh oh", "Can't divide by zero"),
        ("5 / (3 - 3)", .divisionByZero, "Uh oh", "Can't divide by zero"),
        ("sqrt(-1)", .undefined, "Uh oh", "Undefined"),
        ("ln(0)", .undefined, "Uh oh", "Undefined"),
        ("log(-1)", .undefined, "Uh oh", "Undefined"),
        ("(-2)^0.5", .undefined, "Uh oh", "Undefined"),
        ("9^9^9", .tooLarge, "Uh oh", "Too large"),
        ("10^1000.5", .tooLarge, "Uh oh", "Too large"),
        ("1e9999", .tooLarge, "Uh oh", "Too large"),
        ("1e127 * 10", .tooLarge, "Uh oh", "Too large"),
        ("1e-128 / 10", .tooLarge, "Uh oh", "Too large"),
        ("2^9223372036854775808", .tooLarge, "Uh oh", "Too large"),
        ("2^-9223372036854775808", .tooLarge, "Uh oh", "Too large"),
        ("sqrt(-1) +", .incomplete, "…", "Keep typing"),
        ("9^9^9 +", .incomplete, "…", "Keep typing"),
        ("sqrt(-1) + * 2", .invalid, "Not a valid calculation", "sqrt(-1) + * 2"),
        ("9^9^9 + * 2", .invalid, "Not a valid calculation", "9^9^9 + * 2"),
        ("sqrt(", .incomplete, "…", "Keep typing"),
        ("sin(1", .incomplete, "…", "Keep typing"),
        ("2^", .incomplete, "…", "Keep typing"),
        ("sqrt 16", .invalid, "Not a valid calculation", "sqrt 16"),
        ("2^^3", .invalid, "Not a valid calculation", "2^^3"),
        ("3 + * 4", .invalid, "Not a valid calculation", "3 + * 4"),
        ("3 + *", .invalid, "Not a valid calculation", "3 + *"),
        ("1..2", .invalid, "Not a valid calculation", "1..2"),
        ("1 2 + 3", .invalid, "Not a valid calculation", "1 2 + 3"),
        ("3 + 4)", .invalid, "Not a valid calculation", "3 + 4)"),
        ("(3 + * 4", .invalid, "Not a valid calculation", "(3 + * 4"),
        ("3 + ()", .invalid, "Not a valid calculation", "3 + ()"),
        ("12 * )", .invalid, "Not a valid calculation", "12 * )"),
        ("5 / 0 + * 2", .invalid, "Not a valid calculation", "5 / 0 + * 2"),
        (" 3 + * 4 ", .invalid, "Not a valid calculation", " 3 + * 4 ")
    ])
    func calculationsWithoutAValueCarryTheirStateAndExactWording(
        text: String, state: Answer.State, title: String, subtitle: String
    ) throws {
        let answer = try #require(Calculation.answer(for: text, locale: locale))
        #expect(answer.state == state)
        #expect(answer.title == title)
        #expect(answer.subtitle == subtitle)
        #expect(answer.copyableText == nil)
    }
    @Test(arguments: [
        ("", false), ("2024", false), ("pi", false), ("e", false),
        ("rent 1200 / 3", false), ("tax 3x4", false), ("3 x pi", false),
        ("extra", false), ("sqrtish(4)", false), ("https://3/4", false),
        ("pix2", false), ("pie", false), ("x3", false), ("3x", false),
        ("2024-10-16", true), ("12 *", true), ("5 / 0", true),
        ("3 + * 4", true), ("1..2", true), ("sqrt", true),
        ("SIN(pi)", true), ("2pi", true), ("2(3 + 4)", true),
        ("3x4", true), (".3 x .4", true), ("3 x 4", true), ("3×4", true),
        ("2^10", true), ("50%", true), ("1e-3 + 2", true)
    ])
    func recognizesOnlyTheCalculationLanguage(text: String, expected: Bool) {
        #expect(Calculation.recognizes(text, locale: locale) == expected)
        if !expected { #expect(Calculation.answer(for: text, locale: locale) == nil) }
    }
    @Test(arguments: [
        ("2 + 3 * 4", "14"), ("(2 + 3) * 4", "20"),
        ("10 / (2 + 3)", "2"), ("-5 + 3", "-2"),
        ("2 * -3", "-6"), ("-(2 + 3)", "-5"),
        ("2024-10-16", "1,998"), ("0.1 + 0.2", "0.3"),
        ("10 / 4", "2.5"), ("3×4", "12"), ("3x4", "12"),
        ("3 x 4", "12"), (".3 x .4", "0.12"), ("12 ÷ 4", "3"),
        ("5 − 3", "2"), ("0x10", "0")
    ])
    func evaluatesArithmeticWithExactDecimals(text: String, expected: String) {
        #expect(Calculation.answer(for: text, locale: locale)?.title == expected)
    }

    @Test(arguments: [
        ("123456789012345 + 0", "123,456,789,012,345", "123456789012345"),
        ("999999999999999.9 + 0", "1e15", "1e15"),
        ("1234567890123456 + 0", "1.2345679e15", "1.2345679e15"),
        ("1 / 3", "0.33333333", "0.33333333"),
        ("123456789 / 100", "1,234,567.9", "1234567.9"),
        ("1 / 100000000", "0.00000001", "0.00000001"),
        ("1 / 1000000000", "1e-9", "1e-9"),
        ("123456789012345678901 + 0", "1.2345679e20", "1.2345679e20"),
        ("-1234.5 + 0", "-1,234.5", "-1234.5"),
        ("0.0000000001 - 0.0000000001", "0", "0"),
        ("10 / 4", "2.5", "2.5")
    ])
    func formatsAnswersAndCopyableText(text: String, title: String, copy: String) throws {
        let answer = try #require(Calculation.answer(for: text, locale: locale))
        #expect(answer.title == title)
        #expect(answer.copyableText == copy)
    }

    @Test func typingAndDisplayFollowTheExplicitLocale() throws {
        let answer = try #require(Calculation.answer(for: "1.234,5 + 0,1", locale: Locale(identifier: "de_DE")))
        #expect(answer.title == "1.234,6")
        #expect(answer.copyableText == "1234,6")
        let scientific = try #require(Calculation.answer(for: "1,2e-3", locale: Locale(identifier: "de_DE")))
        #expect(scientific.title == "0,0012" && scientific.copyableText == "0,0012")
        let percent = try #require(Calculation.answer(for: "200 + 10,5%", locale: Locale(identifier: "de_DE")))
        #expect(percent.title == "221" && percent.copyableText == "221")
    }

}
